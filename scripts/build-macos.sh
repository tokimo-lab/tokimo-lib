#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

if [[ -z "${PREFIX:-}" ]]; then
  # GitHub macOS runners cannot write /opt; use their writable temp prefix in CI.
  if [[ -n "${CI:-}" && -n "${RUNNER_TEMP:-}" ]]; then
    PREFIX="$RUNNER_TEMP/tokimo-lib"
  else
    PREFIX="/opt/tokimo-lib"
  fi
fi
WORK_DIR="${WORK_DIR:-$REPO_ROOT}"
BUILD_ROOT="${BUILD_ROOT:-$WORK_DIR/build}"
INSTALL_DIR="$REPO_ROOT/install"
TARBALL="$INSTALL_DIR/install-macos-arm64.tar.zst"
COMPONENTS_FILE="$REPO_ROOT/components.toml"
LIBVIPS_DEFAULT_VERSION="8.18.2"

SRC_DIR="$BUILD_ROOT/ffmpeg-src"
FFMPEG_BUILD_DIR="$BUILD_ROOT/ffmpeg-build"
THIRD_PARTY_DIR="$BUILD_ROOT/third-party"
TP_PREFIX="$THIRD_PARTY_DIR/prefix"
CONFIGURE_LOG="$BUILD_ROOT/ffmpeg-configure.log"
MAKE_LOG="$BUILD_ROOT/ffmpeg-make.log"
LIBVIPS_VERSION="${LIBVIPS_VERSION:-}"
LIBVIPS_SRC_DIR=""
LIBVIPS_TARBALL=""
LIBVIPS_BUILD_DIR=""
LIBVIPS_BUILD_LOG="$BUILD_ROOT/libvips-build.log"
HOMEBREW_PREFIX=""
FFMPEG_GIT_URL=""
FFMPEG_REF=""
PATCH_CMD="patch"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || printf '4')}"

FFMPEG_FLAGS=()
COPIED_KEYS=()
COPIED_PROVIDERS=()
COPIED_BASENAMES=()
QUEUE=()
SEEN_QUEUE=()

log() { printf '[build-macos] %s\n' "$*"; }
warn() { printf '[build-macos] WARN: %s\n' "$*" >&2; }
die() { printf '[build-macos] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

canonical_path() {
  local path="$1"
  local dir base
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ -d "$dir" ]]; then
    printf '%s/%s\n' "$(cd -- "$dir" && pwd -P)" "$base"
  else
    return 1
  fi
}

check_macos_arm64() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"
  [[ "$os" == "Darwin" ]] || die "macOS build requires Darwin; got $os"
  case "$arch" in
    arm64|aarch64) ;;
    *) die "macOS build requires Apple Silicon arm64/aarch64; got $arch" ;;
  esac
}

toml_value() {
  local section="$1"
  local key="$2"
  local file="$3"

  [[ -f "$file" ]] || return 1
  awk -v section="$section" -v key="$key" '
    $0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$" { in_section = 1; next }
    $0 ~ "^[[:space:]]*\\[" { in_section = 0 }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[^=]*=[[:space:]]*", "")
      sub(/[[:space:]]*(#.*)?$/, "")
      gsub(/^\"|\"$/, "")
      print
      exit
    }
  ' "$file"
}

resolve_ffmpeg_source() {
  local default_url="https://github.com/jellyfin/jellyfin-ffmpeg.git"
  local default_ref="jellyfin"
  local configured_url=""
  local configured_ref=""

  configured_url="$(toml_value ffmpeg upstream "$COMPONENTS_FILE" || true)"
  configured_ref="$(toml_value ffmpeg ref "$COMPONENTS_FILE" || true)"
  if [[ -z "$configured_ref" ]]; then
    configured_ref="$(toml_value ffmpeg tag "$COMPONENTS_FILE" || true)"
  fi
  if [[ -z "$configured_ref" ]]; then
    configured_ref="$(toml_value ffmpeg branch "$COMPONENTS_FILE" || true)"
  fi

  FFMPEG_GIT_URL="${FFMPEG_GIT_URL:-${configured_url:-$default_url}}"
  FFMPEG_REF="${FFMPEG_REF:-${configured_ref:-$default_ref}}"
}

set_libvips_paths() {
  LIBVIPS_SRC_DIR="$BUILD_ROOT/vips-$LIBVIPS_VERSION"
  LIBVIPS_TARBALL="$BUILD_ROOT/vips-$LIBVIPS_VERSION.tar.xz"
  LIBVIPS_BUILD_DIR="$BUILD_ROOT/vips-$LIBVIPS_VERSION-build"
  LIBVIPS_BUILD_LOG="$BUILD_ROOT/libvips-build.log"
}

resolve_libvips_source() {
  local configured_tag=""

  configured_tag="$(toml_value libvips tag "$COMPONENTS_FILE" || true)"
  configured_tag="${configured_tag#v}"
  LIBVIPS_VERSION="${LIBVIPS_VERSION:-${configured_tag:-$LIBVIPS_DEFAULT_VERSION}}"
  LIBVIPS_VERSION="${LIBVIPS_VERSION#v}"
  set_libvips_paths
}

install_brew_deps() {
  command -v brew >/dev/null 2>&1 || die "Homebrew is required on macOS"
  HOMEBREW_PREFIX="$(brew --prefix)"

  local packages=(
    pkg-config nasm yasm meson ninja cmake gpatch x264 x265 dav1d svt-av1
    libvpx aom opus libvorbis lame fdk-aac theora libsoxr libopenmpt libass
    freetype fribidi harfbuzz fontconfig libbluray webp zimg chromaprint srt
    openjpeg jpeg-xl zvbi vulkan-headers vulkan-loader molten-vk libplacebo
    shaderc glslang
  )

  log "Installing Homebrew dependencies"
  brew install "${packages[@]}"
}

require_standard_commands() {
  local cmd
  for cmd in git curl tar zstd file otool install_name_tool codesign pkg-config meson ninja cmake make; do
    require_cmd "$cmd"
  done
}

pkg_exists() {
  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "$1"
}

append_flag() {
  FFMPEG_FLAGS+=("$1")
}

append_if_pkg() {
  local flag="$1"
  local pkg="$2"
  if pkg_exists "$pkg"; then
    append_flag "$flag"
  fi
}

append_if_any_pkg() {
  local flag="$1"
  shift
  local pkg
  for pkg in "$@"; do
    if pkg_exists "$pkg"; then
      append_flag "$flag"
      return 0
    fi
  done
}

sync_git_repo() {
  local url="$1"
  local ref="$2"
  local dir="$3"

  if [[ -d "$dir/.git" ]]; then
    git -C "$dir" fetch --tags --prune origin
  elif [[ -e "$dir" ]]; then
    die "$dir exists but is not a git repository"
  else
    git clone "$url" "$dir"
  fi

  if git -C "$dir" rev-parse --verify "refs/tags/$ref" >/dev/null 2>&1; then
    git -C "$dir" checkout --force "refs/tags/$ref"
  elif git -C "$dir" rev-parse --verify "refs/remotes/origin/$ref" >/dev/null 2>&1; then
    git -C "$dir" checkout --force -B "$ref" "origin/$ref"
  else
    git -C "$dir" checkout --force "$ref"
  fi
}

apply_debian_patches() {
  local series_file="$SRC_DIR/debian/patches/series"
  local applied=0
  local skipped=0
  local failed=0
  local line patch_name patch_file

  if [[ ! -f "$series_file" ]]; then
    warn "No debian patch series found at $series_file"
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* ]] && continue
    patch_name="${line%%[[:space:]]*}"
    patch_file="$SRC_DIR/debian/patches/$patch_name"
    [[ -f "$patch_file" ]] || continue

    if (cd "$SRC_DIR" && "$PATCH_CMD" --dry-run --reverse -p1 -s < "$patch_file" >/dev/null 2>&1); then
      skipped=$((skipped + 1))
      continue
    fi

    if (cd "$SRC_DIR" && "$PATCH_CMD" --forward -p1 -s < "$patch_file" >/dev/null 2>&1); then
      applied=$((applied + 1))
    else
      warn "Patch conflict: $patch_name"
      failed=$((failed + 1))
    fi
  done < "$series_file"

  log "Patches: $applied applied, $skipped already applied, $failed failed"
}

configure_flags() {
  local extra_cflags="-I$PREFIX/include -I$TP_PREFIX/include -I$HOMEBREW_PREFIX/include"
  local extra_ldflags="-L$PREFIX/lib -L$TP_PREFIX/lib -L$HOMEBREW_PREFIX/lib -Wl,-rpath,$PREFIX/lib -Wl,-rpath,$HOMEBREW_PREFIX/lib -Wl,-rpath,@loader_path/../lib"

  FFMPEG_FLAGS=(
    "--prefix=$PREFIX"
    "--enable-gpl"
    "--enable-version3"
    "--enable-nonfree"
    "--enable-rpath"
    "--enable-shared"
    "--disable-static"
    "--enable-pic"
    "--disable-doc"
    "--disable-debug"
    "--disable-ffplay"
    "--disable-libxcb"
    "--disable-xlib"
    "--arch=aarch64"
    "--enable-lto=auto"
    "--extra-version=Jellyfin"
    "--extra-cflags=$extra_cflags"
    "--extra-ldflags=$extra_ldflags"
    "--disable-ffnvcodec"
    "--disable-amf"
    "--enable-videotoolbox"
  )

  append_if_pkg "--enable-libx264" x264
  append_if_pkg "--enable-libx265" x265
  append_if_pkg "--enable-libdav1d" dav1d
  append_if_any_pkg "--enable-libsvtav1" SvtAv1Enc svtav1
  append_if_pkg "--enable-libvpx" vpx
  append_if_pkg "--enable-libaom" aom

  append_if_pkg "--enable-libopus" opus
  append_if_any_pkg "--enable-libvorbis" vorbis vorbisenc
  append_if_any_pkg "--enable-libmp3lame" mp3lame lame
  append_if_pkg "--enable-libfdk-aac" fdk-aac
  append_if_pkg "--enable-libtheora" theoraenc
  append_if_pkg "--enable-libopenmpt" libopenmpt
  append_if_pkg "--enable-libsoxr" soxr

  append_if_pkg "--enable-libass" libass
  append_if_pkg "--enable-libfontconfig" fontconfig
  append_if_pkg "--enable-libfreetype" freetype2
  append_if_pkg "--enable-libfribidi" fribidi
  append_if_pkg "--enable-libharfbuzz" harfbuzz

  append_if_pkg "--enable-libbluray" libbluray
  append_if_pkg "--enable-libwebp" libwebp
  append_if_pkg "--enable-libzimg" zimg
  append_if_any_pkg "--enable-chromaprint" libchromaprint chromaprint
  append_if_pkg "--enable-libsrt" srt
  append_if_pkg "--enable-libzvbi" zvbi-0.2
  append_if_pkg "--enable-libopenjpeg" libopenjp2
  append_if_pkg "--enable-libjxl" libjxl

  append_if_pkg "--enable-vulkan" vulkan
  append_if_pkg "--enable-libplacebo" libplacebo
  append_if_any_pkg "--enable-libshaderc" shaderc shaderc_combined
  if pkg_exists OpenCL || [[ -d /System/Library/Frameworks/OpenCL.framework ]]; then
    append_flag "--enable-opencl"
  fi
}

build_ffmpeg() {
  mkdir -p "$FFMPEG_BUILD_DIR" "$THIRD_PARTY_DIR" "$TP_PREFIX"
  configure_flags

  log "Configuring FFmpeg (${#FFMPEG_FLAGS[@]} flags)"
  if ! (cd "$FFMPEG_BUILD_DIR" && "$SRC_DIR/configure" "${FFMPEG_FLAGS[@]}") > "$CONFIGURE_LOG" 2>&1; then
    tail -40 "$CONFIGURE_LOG" >&2 || true
    die "configure failed; see $CONFIGURE_LOG"
  fi

  log "Building FFmpeg (jobs=$JOBS)"
  if ! make -C "$FFMPEG_BUILD_DIR" -j"$JOBS" > "$MAKE_LOG" 2>&1; then
    tail -40 "$MAKE_LOG" >&2 || true
    die "make failed; see $MAKE_LOG"
  fi

  log "Installing FFmpeg to $PREFIX"
  make -C "$FFMPEG_BUILD_DIR" install >> "$MAKE_LOG" 2>&1

  if [[ ! -x "$PREFIX/bin/ffmpeg" ]]; then
    die "ffmpeg binary not found at $PREFIX/bin/ffmpeg"
  fi
}

download_libvips_source() {
  local url="https://github.com/libvips/libvips/releases/download/v${LIBVIPS_VERSION}/vips-${LIBVIPS_VERSION}.tar.xz"

  if [[ ! -f "$LIBVIPS_TARBALL" ]]; then
    log "Downloading libvips $LIBVIPS_VERSION"
    curl -fL "$url" -o "$LIBVIPS_TARBALL"
  fi

  if [[ ! -d "$LIBVIPS_SRC_DIR" ]]; then
    log "Extracting libvips to $LIBVIPS_SRC_DIR"
    tar -C "$BUILD_ROOT" -xf "$LIBVIPS_TARBALL" "vips-${LIBVIPS_VERSION}"
  fi

  if [[ ! -f "$LIBVIPS_SRC_DIR/meson.build" ]]; then
    die "libvips source directory not found at $LIBVIPS_SRC_DIR"
  fi
}

build_libvips() {
  local meson_flags=(
    "--prefix=$PREFIX"
    "--libdir=lib"
    "--buildtype=release"
    "-Dintrospection=disabled"
    "-Dexamples=false"
    "-Ddeprecated=false"
    "-Dmodules=disabled"
  )

  download_libvips_source
  log "Configuring libvips $LIBVIPS_VERSION"
  if [[ -f "$LIBVIPS_BUILD_DIR/build.ninja" ]]; then
    if ! meson setup "$LIBVIPS_BUILD_DIR" "$LIBVIPS_SRC_DIR" --reconfigure "${meson_flags[@]}" > "$LIBVIPS_BUILD_LOG" 2>&1; then
      tail -40 "$LIBVIPS_BUILD_LOG" >&2 || true
      die "libvips configure failed; see $LIBVIPS_BUILD_LOG"
    fi
  elif ! meson setup "$LIBVIPS_BUILD_DIR" "$LIBVIPS_SRC_DIR" "${meson_flags[@]}" > "$LIBVIPS_BUILD_LOG" 2>&1; then
    tail -40 "$LIBVIPS_BUILD_LOG" >&2 || true
    die "libvips configure failed; see $LIBVIPS_BUILD_LOG"
  fi

  log "Building libvips (jobs=$JOBS)"
  if ! ninja -C "$LIBVIPS_BUILD_DIR" -j"$JOBS" >> "$LIBVIPS_BUILD_LOG" 2>&1; then
    tail -40 "$LIBVIPS_BUILD_LOG" >&2 || true
    die "libvips build failed; see $LIBVIPS_BUILD_LOG"
  fi

  log "Installing libvips to $PREFIX"
  if ! ninja -C "$LIBVIPS_BUILD_DIR" install >> "$LIBVIPS_BUILD_LOG" 2>&1; then
    tail -40 "$LIBVIPS_BUILD_LOG" >&2 || true
    die "libvips install failed; see $LIBVIPS_BUILD_LOG"
  fi

  if [[ ! -x "$PREFIX/bin/vips" ]]; then
    die "vips binary not found at $PREFIX/bin/vips"
  fi
}

copy_tree_if_present() {
  local name="$1"
  local src="$PREFIX/$name"
  local dst="$INSTALL_DIR/$name"

  rm -rf -- "$dst"
  mkdir -p -- "$dst"
  if [[ -d "$src" ]]; then
    cp -R -p "$src/." "$dst/"
  fi
}

is_macho() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  file -b "$path" | grep -Eq 'Mach-O.*(executable|dynamically linked shared library|bundle)'
}

is_dylib() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  file -b "$path" | grep -Eq 'Mach-O.*dynamically linked shared library'
}

dylib_id() {
  local path="$1"
  otool -D "$path" 2>/dev/null | sed -n '2p'
}

extract_otool_deps() {
  local path="$1"
  otool -L "$path" 2>/dev/null | sed '1d; s/^[[:space:]]*//; s/[[:space:]].*$//'
}

is_system_dep() {
  case "$1" in
    /usr/lib/*|/System/Library/*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_dep_path() {
  local dep="$1"
  local owner="$2"
  local base owner_dir candidate

  is_system_dep "$dep" && return 1

  base="$(basename -- "$dep")"
  if [[ -e "$INSTALL_DIR/lib/$base" ]]; then
    printf '%s\n' "$INSTALL_DIR/lib/$base"
    return 0
  fi

  if [[ "$dep" == /* && -e "$dep" ]]; then
    printf '%s\n' "$dep"
    return 0
  fi

  owner_dir="$(dirname -- "$owner")"

  case "$dep" in
    @loader_path/*)
      candidate="$owner_dir/${dep#@loader_path/}"
      [[ -e "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
      ;;
    @executable_path/*)
      candidate="$INSTALL_DIR/bin/${dep#@executable_path/}"
      [[ -e "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
      ;;
  esac

  for candidate in "$INSTALL_DIR/lib/$base" "$PREFIX/lib/$base" "$HOMEBREW_PREFIX/lib/$base"; do
    if [[ -e "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

queue_add() {
  local path="$1"
  if ((${#QUEUE[@]} > 0)) && array_contains "$path" "${QUEUE[@]}"; then
    return 0
  fi
  if ((${#SEEN_QUEUE[@]} > 0)) && array_contains "$path" "${SEEN_QUEUE[@]}"; then
    return 0
  fi
  QUEUE+=("$path")
}

copied_key_index() {
  local key="$1"
  local i=0
  while [[ $i -lt ${#COPIED_KEYS[@]} ]]; do
    if [[ "${COPIED_KEYS[$i]}" == "$key" ]]; then
      printf '%s\n' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

remember_copied_provider() {
  local key="$1"
  local src_real="$2"
  local base="$3"
  local idx=""

  idx="$(copied_key_index "$key" || true)"
  if [[ -n "$idx" ]]; then
    if [[ "${COPIED_PROVIDERS[$idx]}" != "$src_real" ]]; then
      die "duplicate runtime provider for $key: ${COPIED_BASENAMES[$idx]} and $base"
    fi
    return 0
  fi

  COPIED_KEYS+=("$key")
  COPIED_PROVIDERS+=("$src_real")
  COPIED_BASENAMES+=("$base")
}

copy_dep_to_lib() {
  local src="$1"
  local src_real base id key dst

  is_macho "$src" || return 0
  src_real="$(canonical_path "$src")"
  base="$(basename -- "$src")"
  id="$(dylib_id "$src" || true)"
  key="$(basename -- "${id:-$base}")"
  dst="$INSTALL_DIR/lib/$base"

  remember_copied_provider "$key" "$src_real" "$base"

  if [[ ! -e "$dst" ]]; then
    cp -pL "$src" "$dst"
    chmod u+w "$dst" || true
    log "copied dependency $base"
  fi

  queue_add "$dst"
}

seed_existing_runtime_providers() {
  local path src_real base id key
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    is_macho "$path" || continue
    src_real="$(canonical_path "$path")"
    base="$(basename -- "$path")"
    id="$(dylib_id "$path" || true)"
    key="$(basename -- "${id:-$base}")"
    remember_copied_provider "$key" "$src_real" "$base"
    queue_add "$path"
  done < <(find "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" -type f -print 2>/dev/null)
}

bundle_runtime_deps() {
  local item item_real dep dep_path

  seed_existing_runtime_providers

  while [[ ${#QUEUE[@]} -gt 0 ]]; do
    item="${QUEUE[0]}"
    if ((${#QUEUE[@]} > 1)); then
      QUEUE=("${QUEUE[@]:1}")
    else
      QUEUE=()
    fi
    [[ -f "$item" ]] || continue
    item_real="$(canonical_path "$item")"
    if ((${#SEEN_QUEUE[@]} > 0)) && array_contains "$item_real" "${SEEN_QUEUE[@]}"; then
      continue
    fi
    SEEN_QUEUE+=("$item_real")

    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      is_system_dep "$dep" && continue
      dep_path="$(resolve_dep_path "$dep" "$item" || true)"
      [[ -n "$dep_path" ]] || die "unresolved runtime dependency for $item: $dep"
      copy_dep_to_lib "$dep_path"
    done < <(extract_otool_deps "$item")
  done
}

assert_unique_glib_family() {
  local family path real seen count
  for family in libglib-2.0 libgobject-2.0 libgio-2.0; do
    seen=""
    count=0
    while IFS= read -r path; do
      [[ -e "$path" ]] || continue
      real="$(canonical_path "$path")"
      case "$seen" in
        *"|$real|"*) continue ;;
      esac
      seen="$seen|$real|"
      count=$((count + 1))
    done < <(find "$INSTALL_DIR/lib" -name "$family*.dylib" -print 2>/dev/null)
    if [[ $count -gt 1 ]]; then
      die "duplicate GLib-family providers for $family in install/lib"
    fi
  done
}

has_rpath() {
  local path="$1"
  local rpath="$2"
  otool -l "$path" 2>/dev/null | awk -v want="$rpath" '
    $1 == "path" && $2 == want { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

add_rpath_if_missing() {
  local path="$1"
  local rpath="$2"
  if ! has_rpath "$path" "$rpath"; then
    install_name_tool -add_rpath "$rpath" "$path" 2>/dev/null || true
  fi
}

patch_macho_file() {
  local path="$1"
  local dep base replacement rpath

  is_macho "$path" || return 0
  chmod u+w "$path" || true

  if is_dylib "$path"; then
    install_name_tool -id "@rpath/$(basename -- "$path")" "$path" 2>/dev/null || true
    rpath='@loader_path'
  else
    rpath='@loader_path/../lib'
  fi
  add_rpath_if_missing "$path" "$rpath"

  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    is_system_dep "$dep" && continue
    base="$(basename -- "$dep")"
    [[ -e "$INSTALL_DIR/lib/$base" ]] || continue
    replacement="@rpath/$base"
    [[ "$dep" == "$replacement" ]] && continue
    install_name_tool -change "$dep" "$replacement" "$path" 2>/dev/null || true
  done < <(extract_otool_deps "$path")
}

patch_runtime_links() {
  local path
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    patch_macho_file "$path"
  done < <(find "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" -type f -print 2>/dev/null)
}

codesign_bundle() {
  local path
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    is_macho "$path" || continue
    codesign --force --sign - "$path" >/dev/null 2>&1 || die "codesign failed for $path"
  done < <(find "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" -type f -print 2>/dev/null)
}

write_meta() {
  local version ffmpeg_ref ffmpeg_tag libvips_tag glib_version glib_source commit built_at

  [[ -f "$REPO_ROOT/VERSION" ]] || die "VERSION file not found"
  version="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
  ffmpeg_ref="$FFMPEG_REF"
  ffmpeg_tag="$(toml_value ffmpeg tag "$COMPONENTS_FILE" || true)"
  libvips_tag="$(toml_value libvips tag "$COMPONENTS_FILE" || true)"
  glib_version="$(toml_value glib version "$COMPONENTS_FILE" || true)"
  glib_source="$(toml_value glib source "$COMPONENTS_FILE" || true)"
  commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  built_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  cat > "$INSTALL_DIR/META.txt" <<EOF_META
package=tokimo-lib
version=$version
ffmpeg_ref=$ffmpeg_ref
ffmpeg_tag=$ffmpeg_tag
libvips_tag=$libvips_tag
glib_version=$glib_version
glib_source=$glib_source
commit=$commit
built_at=$built_at
EOF_META
}

create_tarball() {
  tar -cf - -C "$INSTALL_DIR" bin lib include META.txt | zstd -19 -T0 -o "$TARBALL" -f
}

bundle_install_tree() {
  rm -rf -- "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/include" "$INSTALL_DIR/META.txt" "$TARBALL"
  mkdir -p -- "$INSTALL_DIR" "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" "$INSTALL_DIR/include"
  copy_tree_if_present bin
  copy_tree_if_present lib
  copy_tree_if_present include
  bundle_runtime_deps
  assert_unique_glib_family
  patch_runtime_links
  codesign_bundle
  write_meta
  create_tarball
  log "created $TARBALL"
}

main() {
  check_macos_arm64
  mkdir -p "$PREFIX" "$BUILD_ROOT" "$THIRD_PARTY_DIR" "$TP_PREFIX"
  install_brew_deps
  require_standard_commands

  if command -v gpatch >/dev/null 2>&1; then
    PATCH_CMD="gpatch"
  fi

  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$TP_PREFIX/lib/pkgconfig:$TP_PREFIX/share/pkgconfig:$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
  export CPATH="$PREFIX/include:$TP_PREFIX/include:$HOMEBREW_PREFIX/include:${CPATH:-}"
  export LIBRARY_PATH="$PREFIX/lib:$TP_PREFIX/lib:$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"

  resolve_ffmpeg_source
  resolve_libvips_source

  log "Using FFmpeg source $FFMPEG_GIT_URL ($FFMPEG_REF)"
  sync_git_repo "$FFMPEG_GIT_URL" "$FFMPEG_REF" "$SRC_DIR"
  apply_debian_patches
  build_ffmpeg

  log "Using libvips $LIBVIPS_VERSION"
  build_libvips

  bundle_install_tree
  log "macOS Apple Silicon bundle complete"
}

main "$@"
