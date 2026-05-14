#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

# Variables:
#   PREFIX      Conventional install prefix. Defaults to /opt/tokimo-lib.
#               When explicitly set, Windows artifacts are collected there.
#   WORK_DIR    Parent for build scratch state. Defaults to the repository root.
#   BUILD_ROOT  Build/download/log directory. Defaults to $WORK_DIR/build.
#   BTBN_IMAGE  BtbN Windows cross-build image for FFmpeg.
#   FDK_AAC_REF Pinned mstorsjo/fdk-aac commit built inside the container.
PREFIX_WAS_SET=0
if [[ ${PREFIX+x} ]]; then
  PREFIX_WAS_SET=1
fi
PREFIX="${PREFIX:-/opt/tokimo-lib}"
WORK_DIR="${WORK_DIR:-$REPO_ROOT}"
BUILD_ROOT="${BUILD_ROOT:-$WORK_DIR/build}"
COMPONENTS_FILE="$REPO_ROOT/components.toml"
INSTALL_DIR="$REPO_ROOT/install"
TARBALL="$INSTALL_DIR/install-windows.tar.zst"
WINDOWS_PREFIX="$BUILD_ROOT/windows-prefix"
if [[ $PREFIX_WAS_SET -eq 1 ]]; then
  WINDOWS_PREFIX="$PREFIX"
fi

SRC_DIR="$BUILD_ROOT/ffmpeg-src"
FFMPEG_BUILD_DIR="$BUILD_ROOT/ffmpeg-build-windows"
LIBVIPS_WINDOWS_DIR="$BUILD_ROOT/libvips-windows"
LIBVIPS_ZIP="$BUILD_ROOT/libvips-windows.zip"
LIBVIPS_DEFAULT_VERSION="8.18.2"
LIBVIPS_VERSION="${LIBVIPS_VERSION:-}"
FFMPEG_GIT_URL=""
FFMPEG_REF=""
PATCH_CMD="patch"
IMAGE="${BTBN_IMAGE:-ghcr.io/btbn/ffmpeg-builds/win64-gpl-shared:latest}"
FDK_AAC_REF="${FDK_AAC_REF:-d8e6b1a3aa606c450241632b64b703f21ea31ce3}"

log() { printf '[build-windows] %s\n' "$*"; }
warn() { printf '[build-windows] WARN: %s\n' "$*" >&2; }
die() { printf '[build-windows] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_standard_commands() {
  local cmd
  for cmd in git curl tar zstd unzip docker; do
    require_cmd "$cmd"
  done
  if command -v gpatch >/dev/null 2>&1; then
    PATCH_CMD="gpatch"
  else
    require_cmd patch
    PATCH_CMD="patch"
  fi
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

resolve_libvips_source() {
  local configured_tag=""

  configured_tag="$(toml_value libvips tag "$COMPONENTS_FILE" || true)"
  configured_tag="${configured_tag#v}"
  LIBVIPS_VERSION="${LIBVIPS_VERSION:-${configured_tag:-$LIBVIPS_DEFAULT_VERSION}}"
  LIBVIPS_VERSION="${LIBVIPS_VERSION#v}"
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
  if [[ $failed -gt 0 ]]; then
    warn "$failed Debian patch(es) failed to apply on Windows mingw build; continuing"
  fi
}

build_ffmpeg_windows() {
  local uidargs=()

  mkdir -p "$FFMPEG_BUILD_DIR" "$WINDOWS_PREFIX"
  log "Pulling $IMAGE"
  docker pull "$IMAGE"

  if ! docker info -f '{{println .SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    uidargs=( -u "$(id -u):$(id -g)" )
  fi

  log "Cross-building FFmpeg for Windows"
  docker run --rm "${uidargs[@]}" \
    -v "$SRC_DIR":/work/ffmpeg-src \
    -v "$FFMPEG_BUILD_DIR":/work/build \
    -v "$WINDOWS_PREFIX":/work/prefix \
    -e FDK_AAC_REF="$FDK_AAC_REF" \
    -e FDK_PREFIX=/work/build/fdk-aac-prefix \
    -w /work \
    "$IMAGE" \
    bash -eo pipefail -c '
      set -euo pipefail
      : "${FFBUILD_PREFIX:?image must define FFBUILD_PREFIX}"
      : "${FFBUILD_TOOLCHAIN:?image must define FFBUILD_TOOLCHAIN}"
      : "${FFBUILD_TARGET_FLAGS:?image must define FFBUILD_TARGET_FLAGS}"
      : "${CC:?image must define CC}"
      : "${CXX:?image must define CXX}"
      : "${AR:?image must define AR}"
      : "${RANLIB:?image must define RANLIB}"
      : "${NM:?image must define NM}"
      : "${FDK_PREFIX:?must be set}"

      nproc_count="$(nproc)"
      mkdir -p /work/build/logs

      if [[ ! -f "$FDK_PREFIX/lib/libfdk-aac.a" ]]; then
        mkdir -p /work/build/fdk-aac
        if [[ ! -d /work/build/fdk-aac/src/.git ]]; then
          git clone --filter=blob:none https://github.com/mstorsjo/fdk-aac.git /work/build/fdk-aac/src \
            > /work/build/logs/fdk-aac-clone.log 2>&1
        fi
        cd /work/build/fdk-aac/src
        git fetch --tags origin > /work/build/logs/fdk-aac-fetch.log 2>&1
        git checkout "$FDK_AAC_REF" > /work/build/logs/fdk-aac-checkout.log 2>&1
        ./autogen.sh > /work/build/logs/fdk-aac-autogen.log 2>&1
        ./configure \
          --prefix="$FDK_PREFIX" \
          --host="$FFBUILD_TOOLCHAIN" \
          --disable-shared \
          --enable-static \
          --with-pic \
          --disable-example \
          > /work/build/logs/fdk-aac-configure.log 2>&1
        make -j"$nproc_count" > /work/build/logs/fdk-aac-make.log 2>&1
        make install >> /work/build/logs/fdk-aac-make.log 2>&1
      fi

      export PKG_CONFIG_PATH="$FDK_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
      rm -rf /work/build/ffmpeg
      mkdir -p /work/build/ffmpeg
      cd /work/build/ffmpeg

      configure_flags=(
        --prefix=/work/prefix
        --pkg-config-flags=--static
        --extra-cflags="-I$FFBUILD_PREFIX/include -I$FDK_PREFIX/include"
        --extra-cxxflags="-I$FFBUILD_PREFIX/include -I$FDK_PREFIX/include"
        --extra-ldflags="-L$FFBUILD_PREFIX/lib -L$FDK_PREFIX/lib -pthread"
        --extra-libs="-lgomp"
        --cc="$CC" --cxx="$CXX" --ar="$AR" --ranlib="$RANLIB" --nm="$NM"
        --enable-gpl
        --enable-version3
        --enable-nonfree
        --enable-shared
        --disable-static
        --enable-pic
        --disable-doc
        --disable-debug
        --disable-ffplay
        --disable-w32threads
        --enable-pthreads
        --enable-iconv
        --enable-zlib
        --extra-version=Jellyfin
        --enable-libx264 --enable-libx265 --enable-libdav1d --enable-libsvtav1
        --enable-libvpx --enable-libaom
        --enable-libopus --enable-libvorbis --enable-libmp3lame
        --enable-libfdk-aac
        --enable-libtheora --enable-libopenmpt --enable-libsoxr
        --enable-libass --enable-libfontconfig --enable-libfreetype
        --enable-libfribidi --enable-libharfbuzz
        --enable-libbluray --enable-libwebp --enable-libzimg
        --enable-chromaprint --enable-libsrt --enable-libopenjpeg --enable-libjxl
        --enable-libzvbi
        --enable-vulkan --enable-libplacebo --enable-libshaderc
        --enable-ffnvcodec --enable-cuda --enable-cuda-llvm
        --enable-cuvid --enable-nvdec --enable-nvenc
        --enable-amf
        --enable-libvpl
        --enable-d3d11va --enable-dxva2 --enable-mediafoundation
      )

      # shellcheck disable=SC2206  # FFBUILD_TARGET_FLAGS is intentionally word-split.
      target_flags=( $FFBUILD_TARGET_FLAGS )

      if ! /work/ffmpeg-src/configure "${target_flags[@]}" "${configure_flags[@]}" \
          > /work/build/logs/ffmpeg-configure.log 2>&1; then
        tail -80 /work/build/logs/ffmpeg-configure.log >&2 || true
        tail -120 ffbuild/config.log >&2 2>/dev/null || true
        exit 1
      fi
      make -j"$nproc_count" > /work/build/logs/ffmpeg-make.log 2>&1
      make install >> /work/build/logs/ffmpeg-make.log 2>&1
    '

  [[ -d "$WINDOWS_PREFIX/bin" ]] || die "FFmpeg did not create $WINDOWS_PREFIX/bin"
}

download_libvips_windows() {
  local primary_url="https://github.com/libvips/build-win64-mxe/releases/download/v${LIBVIPS_VERSION}/vips-dev-w64-web-${LIBVIPS_VERSION}.zip"
  local fallback_url="https://github.com/libvips/build-win64-mxe/releases/download/v${LIBVIPS_VERSION}/vips-dev-x64-web-${LIBVIPS_VERSION}.zip"

  rm -rf -- "$LIBVIPS_WINDOWS_DIR"
  mkdir -p -- "$LIBVIPS_WINDOWS_DIR"

  if ! curl -fL "$primary_url" -o "$LIBVIPS_ZIP"; then
    warn "primary libvips artifact unavailable, trying fallback"
    curl -fL "$fallback_url" -o "$LIBVIPS_ZIP"
  fi

  unzip -q "$LIBVIPS_ZIP" -d "$LIBVIPS_WINDOWS_DIR"
}

find_libvips_root() {
  local candidate

  for candidate in "$LIBVIPS_WINDOWS_DIR" "$LIBVIPS_WINDOWS_DIR"/*; do
    if [[ -d "$candidate/bin" && -d "$candidate/lib" && -d "$candidate/include" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  find "$LIBVIPS_WINDOWS_DIR" -mindepth 1 -maxdepth 3 -type d \
    -exec sh -c 'test -d "$1/bin" && test -d "$1/lib" && test -d "$1/include"' sh '{}' \; \
    -print -quit
}

copy_file_dedup() {
  local src="$1"
  local dst="$2"

  mkdir -p -- "$(dirname -- "$dst")"
  if [[ -e "$dst" ]]; then
    if cmp -s "$src" "$dst"; then
      return 0
    fi
    die "destination exists with different content: $dst"
  fi
  cp -p "$src" "$dst"
}

copy_tree_dedup_by_basename() {
  local src_dir="$1"
  local dst_dir="$2"
  local file base dst

  [[ -d "$src_dir" ]] || return 0
  mkdir -p -- "$dst_dir"
  while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    base="$(basename -- "$file")"
    dst="$dst_dir/$base"
    copy_file_dedup "$file" "$dst"
  done < <(find "$src_dir" -type f -print)
}

copy_tree_preserve_relative() {
  local src_dir="$1"
  local dst_dir="$2"
  local rel src dst

  [[ -d "$src_dir" ]] || return 0
  mkdir -p -- "$dst_dir"
  while IFS= read -r rel; do
    src="$src_dir/$rel"
    dst="$dst_dir/$rel"
    copy_file_dedup "$src" "$dst"
  done < <(cd "$src_dir" && find . -type f -print | sed 's#^\./##')
}

add_libvips_windows() {
  local root

  log "Downloading libvips Windows artifact $LIBVIPS_VERSION"
  download_libvips_windows
  root="$(find_libvips_root || true)"
  [[ -n "$root" ]] || die "could not locate libvips Windows artifact root"

  log "Adding libvips from $root"
  copy_tree_dedup_by_basename "$root/bin" "$WINDOWS_PREFIX/bin"
  copy_tree_preserve_relative "$root/lib" "$WINDOWS_PREFIX/lib"
  copy_tree_preserve_relative "$root/include" "$WINDOWS_PREFIX/include"
}

copy_prefix_dir_to_install() {
  local name="$1"
  local src="$WINDOWS_PREFIX/$name"
  local dst="$INSTALL_DIR/$name"

  rm -rf -- "$dst"
  mkdir -p -- "$dst"
  [[ -d "$src" ]] || return 0
  cp -R -p "$src/." "$dst/"
}

assert_unique_basenames() {
  local seen_file="$BUILD_ROOT/windows-basenames.seen"
  local path base existing

  : > "$seen_file"
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    base="$(basename -- "$path")"
    existing="$(awk -F '\t' -v base="$base" '$1 == base { print $2; exit }' "$seen_file")"
    if [[ -n "$existing" ]]; then
      if ! cmp -s "$existing" "$path"; then
        die "duplicate basename with different content in final install: $base"
      fi
      continue
    fi
    printf '%s\t%s\n' "$base" "$path" >> "$seen_file"
  done < <(find "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" -type f -print 2>/dev/null)
}

assert_unique_glib_family() {
  local family path count

  for family in libglib-2.0-0.dll libgobject-2.0-0.dll libgio-2.0-0.dll; do
    count=0
    while IFS= read -r path; do
      [[ -f "$path" ]] || continue
      count=$((count + 1))
    done < <(find "$INSTALL_DIR/bin" "$INSTALL_DIR/lib" -type f -iname "$family" -print 2>/dev/null)
    [[ $count -eq 1 ]] || die "expected exactly one $family provider in install/bin or install/lib; found $count"
  done
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
  copy_prefix_dir_to_install bin
  copy_prefix_dir_to_install lib
  copy_prefix_dir_to_install include
  assert_unique_basenames
  assert_unique_glib_family
  write_meta
  create_tarball
  log "created $TARBALL"
}

main() {
  mkdir -p "$BUILD_ROOT"
  require_standard_commands
  resolve_ffmpeg_source
  resolve_libvips_source

  log "Using FFmpeg source $FFMPEG_GIT_URL ($FFMPEG_REF)"
  sync_git_repo "$FFMPEG_GIT_URL" "$FFMPEG_REF" "$SRC_DIR"
  apply_debian_patches
  build_ffmpeg_windows

  log "Using libvips $LIBVIPS_VERSION"
  add_libvips_windows

  bundle_install_tree
  log "Windows bundle complete"
}

main "$@"
