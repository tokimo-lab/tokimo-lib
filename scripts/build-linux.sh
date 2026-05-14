#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREFIX="${PREFIX:-/opt/tokimo-lib}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT}"
BUILD_ROOT="${BUILD_ROOT:-$WORK_DIR/build}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

SRC_DIR="$BUILD_ROOT/ffmpeg-src"
FFMPEG_BUILD_DIR="$BUILD_ROOT/ffmpeg-build"
THIRD_PARTY_DIR="$BUILD_ROOT/third-party"
TP_PREFIX="$THIRD_PARTY_DIR/prefix"
CONFIGURE_LOG="$BUILD_ROOT/ffmpeg-configure.log"
MAKE_LOG="$BUILD_ROOT/ffmpeg-make.log"
COMPONENTS_FILE="$REPO_ROOT/components.toml"
LIBVIPS_DEFAULT_VERSION="8.18.2"
LIBVIPS_VERSION="${LIBVIPS_VERSION:-}"
LIBVIPS_SRC_DIR="$BUILD_ROOT/vips-$LIBVIPS_VERSION"
LIBVIPS_TARBALL="$BUILD_ROOT/vips-$LIBVIPS_VERSION.tar.xz"
LIBVIPS_BUILD_DIR="$BUILD_ROOT/vips-$LIBVIPS_VERSION-build"
LIBVIPS_BUILD_LOG="$BUILD_ROOT/libvips-build.log"

mkdir -p "$PREFIX" "$BUILD_ROOT"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"

log() { printf '[build-linux] %s\n' "$*"; }
die() { printf '[build-linux] ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf '[build-linux] WARN: %s\n' "$*" >&2; }

if command -v gpatch >/dev/null 2>&1; then
  PATCH_CMD="gpatch"
else
  PATCH_CMD="patch"
fi

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

pkg_exists() {
  command -v pkg-config >/dev/null 2>&1 && pkg-config --exists "$1"
}

pkg_version_at_least() {
  local pkg="$1"
  local min_version="$2"

  command -v pkg-config >/dev/null 2>&1 && pkg-config --atleast-version="$min_version" "$pkg"
}

append_if_pkg() {
  local -n append_flags_ref="$1"
  local flag="$2"
  local pkg="$3"

  if pkg_exists "$pkg"; then
    append_flags_ref+=("$flag")
  fi
}

append_if_any_pkg() {
  local -n append_flags_ref="$1"
  local flag="$2"
  shift 2

  local pkg
  for pkg in "$@"; do
    if pkg_exists "$pkg"; then
      append_flags_ref+=("$flag")
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
      ((skipped++)) || true
      continue
    fi

    if (cd "$SRC_DIR" && "$PATCH_CMD" --forward -p1 -s < "$patch_file" >/dev/null 2>&1); then
      ((applied++)) || true
    else
      warn "Patch conflict: $patch_name"
      ((failed++)) || true
    fi
  done < "$series_file"

  log "Patches: $applied applied, $skipped already applied, $failed failed"
}

setup_third_party_headers() {
  mkdir -p "$THIRD_PARTY_DIR" "$TP_PREFIX"

  local nv_dir="$THIRD_PARTY_DIR/nv-codec-headers"
  if [[ -d "$nv_dir/.git" ]]; then
    git -C "$nv_dir" fetch --tags --prune origin
    git -C "$nv_dir" pull --rebase origin master || true
  elif [[ -e "$nv_dir" ]]; then
    die "$nv_dir exists but is not a git repository"
  else
    git clone https://github.com/FFmpeg/nv-codec-headers.git "$nv_dir"
  fi
  make -C "$nv_dir" PREFIX="$TP_PREFIX" install

  export PKG_CONFIG_PATH="$TP_PREFIX/lib/pkgconfig:$TP_PREFIX/share/pkgconfig:$PKG_CONFIG_PATH"
  export CPATH="$TP_PREFIX/include:${CPATH:-}"

  local vk_dir="$THIRD_PARTY_DIR/Vulkan-Headers"
  if [[ -d "$vk_dir/.git" ]]; then
    git -C "$vk_dir" pull --rebase origin main || true
  elif [[ -e "$vk_dir" ]]; then
    die "$vk_dir exists but is not a git repository"
  else
    git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers.git "$vk_dir"
  fi
  cmake -S "$vk_dir" -B "$vk_dir/build" -DCMAKE_INSTALL_PREFIX="$TP_PREFIX" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>&1
  cmake --install "$vk_dir/build" >/dev/null 2>&1

  local amf_dir="$THIRD_PARTY_DIR/AMF"
  local amf_include="$THIRD_PARTY_DIR/include/AMF"
  if [[ -d "$amf_dir/.git" ]]; then
    git -C "$amf_dir" pull --rebase origin master || true
  elif [[ -e "$amf_dir" ]]; then
    die "$amf_dir exists but is not a git repository"
  else
    git clone https://github.com/GPUOpen-LibrariesAndSDKs/AMF.git "$amf_dir"
  fi
  rm -rf "$amf_include"
  mkdir -p "$amf_include"
  cp -R "$amf_dir/amf/public/include/." "$amf_include/"
  export CPATH="$THIRD_PARTY_DIR/include:$CPATH"
}

detect_arch() {
  local host_arch
  host_arch="$(uname -m)"
  case "$host_arch" in
    x86_64|amd64) printf 'x86_64\n' ;;
    arm64|aarch64) printf 'aarch64\n' ;;
    *) printf '%s\n' "$host_arch" ;;
  esac
}

configure_flags() {
  local host_arch="$1"
  local -n flags_ref="$2"

  flags_ref=(
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
    "--arch=$host_arch"
    "--enable-lto=auto"
    "--extra-version=Jellyfin"
    "--extra-cflags=-I$PREFIX/include -I$TP_PREFIX/include -I$THIRD_PARTY_DIR/include"
    "--extra-ldflags=-L$PREFIX/lib -L$TP_PREFIX/lib -Wl,-rpath,$PREFIX/lib"
  )

  append_if_pkg flags_ref "--enable-libx264" x264
  append_if_pkg flags_ref "--enable-libx265" x265
  append_if_pkg flags_ref "--enable-libdav1d" dav1d
  append_if_any_pkg flags_ref "--enable-libsvtav1" SvtAv1Enc svtav1
  append_if_pkg flags_ref "--enable-libvpx" vpx
  append_if_pkg flags_ref "--enable-libaom" aom

  append_if_pkg flags_ref "--enable-libopus" opus
  append_if_any_pkg flags_ref "--enable-libvorbis" vorbis vorbisenc
  append_if_any_pkg flags_ref "--enable-libmp3lame" mp3lame lame
  append_if_pkg flags_ref "--enable-libfdk-aac" fdk-aac
  append_if_pkg flags_ref "--enable-libtheora" theoraenc
  append_if_pkg flags_ref "--enable-libopenmpt" libopenmpt
  append_if_pkg flags_ref "--enable-libsoxr" soxr

  append_if_pkg flags_ref "--enable-libdrm" libdrm
  append_if_pkg flags_ref "--enable-libass" libass
  append_if_pkg flags_ref "--enable-libfontconfig" fontconfig
  append_if_pkg flags_ref "--enable-libfreetype" freetype2
  append_if_pkg flags_ref "--enable-libfribidi" fribidi
  append_if_pkg flags_ref "--enable-libharfbuzz" harfbuzz

  append_if_pkg flags_ref "--enable-libbluray" libbluray
  append_if_pkg flags_ref "--enable-libwebp" libwebp
  append_if_pkg flags_ref "--enable-libzimg" zimg
  append_if_any_pkg flags_ref "--enable-chromaprint" libchromaprint chromaprint
  append_if_pkg flags_ref "--enable-libsrt" srt
  append_if_pkg flags_ref "--enable-libzvbi" zvbi-0.2
  append_if_pkg flags_ref "--enable-libopenjpeg" libopenjp2
  append_if_pkg flags_ref "--enable-libjxl" libjxl

  append_if_pkg flags_ref "--enable-libjack" jack
  append_if_pkg flags_ref "--enable-libpulse" libpulse

  append_if_pkg flags_ref "--enable-vulkan" vulkan
  append_if_pkg flags_ref "--enable-libplacebo" libplacebo
  append_if_any_pkg flags_ref "--enable-libshaderc" shaderc shaderc_combined
  append_if_pkg flags_ref "--enable-opencl" OpenCL
  append_if_pkg flags_ref "--enable-vaapi" libva

  if pkg_exists ffnvcodec; then
    flags_ref+=(
      "--enable-ffnvcodec"
      "--enable-cuda"
      "--enable-cuda-llvm"
      "--enable-cuvid"
      "--enable-nvdec"
      "--enable-nvenc"
    )
  fi

  flags_ref+=("--enable-amf")

  if pkg_version_at_least vpl 2.6; then
    flags_ref+=("--enable-libvpl")
  elif pkg_exists libmfx; then
    flags_ref+=("--enable-libmfx")
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

build_ffmpeg() {
  local host_arch
  local flags=()

  host_arch="$(detect_arch)"
  mkdir -p "$FFMPEG_BUILD_DIR"
  configure_flags "$host_arch" flags

  log "Configuring FFmpeg (${#flags[@]} flags)"
  if ! (cd "$FFMPEG_BUILD_DIR" && "$SRC_DIR/configure" "${flags[@]}") > "$CONFIGURE_LOG" 2>&1; then
    tail -40 "$CONFIGURE_LOG" >&2 || true
    die "configure failed; see $CONFIGURE_LOG"
  fi

  log "Building FFmpeg (jobs=$JOBS)"
  if ! make -C "$FFMPEG_BUILD_DIR" -j"$JOBS" > "$MAKE_LOG" 2>&1; then
    tail -40 "$MAKE_LOG" >&2 || true
    die "make failed; see $MAKE_LOG"
  fi

  log "Installing FFmpeg to $PREFIX"
  make -C "$FFMPEG_BUILD_DIR" install

  if [[ ! -x "$PREFIX/bin/ffmpeg" ]]; then
    die "ffmpeg binary not found at $PREFIX/bin/ffmpeg"
  fi
}

main() {
  resolve_ffmpeg_source
  resolve_libvips_source
  log "Using FFmpeg source $FFMPEG_GIT_URL ($FFMPEG_REF)"
  sync_git_repo "$FFMPEG_GIT_URL" "$FFMPEG_REF" "$SRC_DIR"
  apply_debian_patches
  setup_third_party_headers
  build_ffmpeg
  log "Using libvips $LIBVIPS_VERSION"
  build_libvips
  log "FFmpeg and libvips build complete: $PREFIX/bin/ffmpeg, $PREFIX/bin/vips"
}

main "$@"
