#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PREFIX="${PREFIX:-/opt/tokimo-lib}"
INSTALL_DIR="${INSTALL_DIR:-$REPO_ROOT/install}"
INSTALL_DIR="$(realpath -m -- "$INSTALL_DIR")"
TARBALL="$INSTALL_DIR/tokimo-lib-linux-x86_64.tar.zst"

INSTALL_BIN="$INSTALL_DIR/bin"
INSTALL_LIB="$INSTALL_DIR/lib"
INSTALL_INCLUDE="$INSTALL_DIR/include"

log() {
  printf '[bundle-runtime-deps] %s\n' "$*" >&2
}

die() {
  printf '[bundle-runtime-deps] error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

is_elf() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  file -Lb -- "$path" | grep -q 'ELF'
}

is_dynamic_elf() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  file -Lb -- "$path" | grep -q 'ELF.*dynamically linked'
}

soname_of() {
  local path="$1"
  readelf -d -- "$path" 2>/dev/null \
    | awk '/\(SONAME\)/ { gsub(/^.*\[/, ""); gsub(/\].*$/, ""); print; exit }'
}

base_name_for_skip() {
  local path="$1"
  local soname
  soname="$(soname_of "$path")"
  if [[ -n "$soname" ]]; then
    printf '%s\n' "$soname"
  else
    basename -- "$path"
  fi
}

is_base_loader_lib() {
  local name="$1"
  case "$name" in
    linux-vdso*|ld-linux*|libc.so*|libdl.so*|libm.so*|libpthread.so*|librt.so*|\
    libgcc_s.so*|libstdc++.so*|libresolv.so*|libutil.so*|libnsl.so*|libcrypt.so*|libanl.so*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

copy_tree_if_present() {
  local name="$1"
  local src="$PREFIX/$name"
  local dst="$INSTALL_DIR/$name"

  rm -rf -- "$dst"
  mkdir -p -- "$dst"
  if [[ -d "$src" ]]; then
    cp -a -- "$src/." "$dst/"
  fi
}

parse_toml_value() {
  local section="$1"
  local key="$2"
  awk -v section="$section" -v key="$key" '
    $0 ~ "^[[:space:]]*\\[" section "\\][[:space:]]*$" { in_section = 1; next }
    $0 ~ "^[[:space:]]*\\[" { in_section = 0 }
    in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
      sub("^[^=]*=[[:space:]]*", "")
      sub(/[[:space:]]*(#.*)?$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$REPO_ROOT/components.toml"
}

resolve_ffmpeg_ref_for_meta() {
  local ffmpeg_ref
  ffmpeg_ref="$(parse_toml_value ffmpeg commit)"
  if [[ -z "$ffmpeg_ref" ]]; then
    ffmpeg_ref="$(parse_toml_value ffmpeg ref)"
  fi
  if [[ -z "$ffmpeg_ref" ]]; then
    ffmpeg_ref="$(parse_toml_value ffmpeg tag)"
  fi
  if [[ -z "$ffmpeg_ref" ]]; then
    ffmpeg_ref="$(parse_toml_value ffmpeg branch)"
  fi
  printf '%s\n' "$ffmpeg_ref"
}

write_meta() {
  local version ffmpeg_ref ffmpeg_tag libvips_tag glib_version glib_source commit built_at
  version="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
  ffmpeg_ref="$(resolve_ffmpeg_ref_for_meta)"
  ffmpeg_tag="$(parse_toml_value ffmpeg tag)"
  libvips_tag="$(parse_toml_value libvips tag)"
  glib_version="$(parse_toml_value glib version)"
  glib_source="$(parse_toml_value glib source)"
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

extract_ldd_deps() {
  local elf="$1"
  local line dep

  while IFS= read -r line; do
    if [[ "$line" == *'not found'* ]]; then
      die "missing runtime dependency for $elf: $line"
    fi

    if [[ "$line" =~ \=\>[[:space:]](/[^[:space:]]+) ]]; then
      dep="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+) ]]; then
      dep="${BASH_REMATCH[1]}"
    else
      continue
    fi

    printf '%s\n' "$dep"
  done < <(ldd -- "$elf")
}

remember_existing_sonames() {
  local path soname basename provider_realpath existing_realpath
  shopt -s nullglob
  for path in "$INSTALL_LIB"/*; do
    [[ -e "$path" ]] || continue
    is_elf "$path" || continue
    soname="$(soname_of "$path")"
    [[ -n "$soname" ]] || continue
    basename="$(basename -- "$path")"
    provider_realpath="$(realpath -e -- "$path")"
    existing_realpath="${copied_soname_to_provider_realpath[$soname]:-}"
    if [[ -n "$existing_realpath" && "$existing_realpath" != "$provider_realpath" ]]; then
      die "SONAME $soname is provided by both ${copied_soname_to_basename[$soname]} and $basename"
    fi
    copied_soname_to_provider_realpath["$soname"]="$provider_realpath"
    copied_soname_to_basename["$soname"]="${copied_soname_to_basename[$soname]:-$basename}"
  done
}

copy_dep_to_lib() {
  local src="$1"
  local soname basename existing_basename existing_realpath provider_realpath dst dst_soname dst_key dst_realpath

  copied_dep_queue_path=""
  is_elf "$src" || return 0
  soname="$(soname_of "$src")"
  basename="$(basename -- "$src")"
  if [[ -z "$soname" ]]; then
    soname="$basename"
  fi

  dst="$INSTALL_LIB/$basename"
  existing_basename="${copied_soname_to_basename[$soname]:-}"
  existing_realpath="${copied_soname_to_provider_realpath[$soname]:-}"
  if [[ -n "$existing_realpath" ]]; then
    if [[ -e "$dst" ]]; then
      dst_soname="$(soname_of "$dst")"
      dst_key="${dst_soname:-$basename}"
      if [[ "$dst_key" == "$soname" ]]; then
        copied_dep_queue_path="$dst"
        return 0
      fi
    fi

    provider_realpath="$(realpath -e -- "$src")"
    if [[ "$existing_realpath" == "$provider_realpath" ]]; then
      copied_dep_queue_path="$INSTALL_LIB/$existing_basename"
      return 0
    fi
    die "SONAME $soname would be provided by both $existing_basename and $basename"
  fi

  if [[ ! -e "$dst" ]]; then
    cp -aL -- "$src" "$dst"
    log "copied dependency $basename"
  fi
  is_elf "$dst" || return 0
  dst_realpath="$(realpath -e -- "$dst")"
  copied_soname_to_provider_realpath["$soname"]="$dst_realpath"
  copied_soname_to_basename["$soname"]="$basename"
  copied_dep_queue_path="$dst"
}

bundle_runtime_deps() {
  local queue=()
  local item dep dep_real skip_name
  declare -g copied_dep_queue_path=""
  declare -gA copied_soname_to_basename=()
  declare -gA copied_soname_to_provider_realpath=()
  declare -A seen=()

  remember_existing_sonames

  shopt -s nullglob
  for item in "$INSTALL_BIN"/* "$INSTALL_LIB"/*.so*; do
    [[ -f "$item" ]] || continue
    is_dynamic_elf "$item" || continue
    queue+=("$item")
  done

  while ((${#queue[@]} > 0)); do
    item="${queue[0]}"
    queue=("${queue[@]:1}")
    item="$(realpath -e -- "$item")"
    [[ -z "${seen[$item]:-}" ]] || continue
    seen["$item"]=1

    while IFS= read -r dep; do
      [[ -e "$dep" ]] || die "ldd reported missing path $dep for $item"
      dep_real="$(realpath -e -- "$dep")"
      is_elf "$dep_real" || continue
      skip_name="$(base_name_for_skip "$dep_real")"
      if is_base_loader_lib "$skip_name"; then
        continue
      fi

      copy_dep_to_lib "$dep"
      if [[ -n "$copied_dep_queue_path" ]]; then
        queue+=("$copied_dep_queue_path")
      fi
    done < <(extract_ldd_deps "$item")
  done
}

assert_unique_sonames() {
  local path soname basename provider_realpath existing existing_basename
  declare -A seen_sonames=()
  declare -A seen_soname_basenames=()
  declare -A required_counts=()

  shopt -s nullglob
  for path in "$INSTALL_LIB"/*; do
    [[ -e "$path" ]] || continue
    is_elf "$path" || continue
    soname="$(soname_of "$path")"
    [[ -n "$soname" ]] || continue
    basename="$(basename -- "$path")"
    provider_realpath="$(realpath -e -- "$path")"

    existing="${seen_sonames[$soname]:-}"
    if [[ -n "$existing" ]]; then
      if [[ "$existing" == "$provider_realpath" ]]; then
        continue
      fi
      existing_basename="${seen_soname_basenames[$soname]}"
      die "duplicate SONAME in install/lib: $soname ($existing_basename and $basename)"
    fi
    seen_sonames["$soname"]="$provider_realpath"
    seen_soname_basenames["$soname"]="$basename"

    case "$soname" in
      libglib-2.0.so.0|libgobject-2.0.so.0|libgio-2.0.so.0)
        required_counts["$soname"]="$(( ${required_counts[$soname]:-0} + 1 ))"
        ;;
    esac
  done

  for soname in libglib-2.0.so.0 libgobject-2.0.so.0 libgio-2.0.so.0; do
    if (( ${required_counts[$soname]:-0} > 1 )); then
      die "duplicate required GLib-family SONAME: $soname"
    fi
  done
}

patch_rpaths() {
  local path

  shopt -s nullglob
  for path in "$INSTALL_LIB"/*; do
    [[ -n "$path" && -f "$path" ]] || continue
    is_dynamic_elf "$path" || continue
    if ! patchelf --set-rpath '$ORIGIN' "$path"; then
      die "patchelf failed on lib: '$path' (file output: $(file -b -- "$path" 2>&1 || true))"
    fi
  done

  for path in "$INSTALL_BIN"/*; do
    [[ -n "$path" && -f "$path" ]] || continue
    is_dynamic_elf "$path" || continue
    if ! patchelf --set-rpath '$ORIGIN/../lib' "$path"; then
      die "patchelf failed on bin: '$path' (file output: $(file -b -- "$path" 2>&1 || true))"
    fi
  done
}

create_tarball() {
  tar -cf - -C "$INSTALL_DIR" bin lib include META.txt | zstd -19 -T0 -o "$TARBALL" -f
}

main() {
  require_cmd file
  require_cmd readelf
  require_cmd ldd
  require_cmd realpath
  require_cmd patchelf
  require_cmd zstd
  require_cmd git
  require_cmd tar

  case "$INSTALL_DIR/" in
    "$REPO_ROOT/install"|"$REPO_ROOT/install/"|"$REPO_ROOT/install/"*) ;;
    *) die "INSTALL_DIR must be inside $REPO_ROOT/install" ;;
  esac

  mkdir -p -- "$INSTALL_DIR"
  copy_tree_if_present bin
  copy_tree_if_present lib
  copy_tree_if_present include

  bundle_runtime_deps
  assert_unique_sonames
  patch_rpaths
  write_meta
  create_tarball
  log "created $TARBALL"
}

main "$@"
