#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
DEFAULT_INSTALL_TREE="$REPO_ROOT/install"
VERIFY_EXTRACTED_DIR="$REPO_ROOT/install/verify-extracted"

GLIB_SONAMES=(
  "libglib-2.0.so.0"
  "libgobject-2.0.so.0"
  "libgio-2.0.so.0"
)

REQUIRED_ENCODERS=(
  "h264_nvenc"
  "hevc_nvenc"
  "h264_qsv"
  "h264_vaapi"
  "h264_amf"
)

log() {
  printf '[verify-bundle] %s\n' "$*" >&2
}

fail() {
  printf '[verify-bundle] error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

is_elf() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  file -Lb -- "$path" | grep -q 'ELF'
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

soname_of() {
  local path="$1"
  readelf -d -- "$path" 2>/dev/null \
    | awk '/\(SONAME\)/ { gsub(/^.*\[/, ""); gsub(/\].*$/, ""); print; exit }'
}

needed_list() {
  local path="$1"
  readelf -d -- "$path" 2>/dev/null \
    | awk '/\(NEEDED\)/ { gsub(/^.*\[/, ""); gsub(/\].*$/, ""); print }' \
    | sort -u
}

resolve_bundle_path() {
  local path="$1"
  realpath -m -- "$path"
}

ensure_tree_shape() {
  local tree="$1"
  local required

  for required in bin lib include META.txt; do
    [[ -e "$tree/$required" ]] || fail "install tree is missing top-level $required: $tree/$required"
  done
  [[ -d "$tree/bin" ]] || fail "top-level bin is not a directory: $tree/bin"
  [[ -d "$tree/lib" ]] || fail "top-level lib is not a directory: $tree/lib"
  [[ -d "$tree/include" ]] || fail "top-level include is not a directory: $tree/include"
  [[ -f "$tree/META.txt" ]] || fail "top-level META.txt is not a file: $tree/META.txt"
}

extract_bundle() {
  local bundle="$1"

  [[ -f "$bundle" ]] || fail "bundle does not exist: $bundle"
  require_cmd tar
  require_cmd zstd

  rm -rf -- "$VERIFY_EXTRACTED_DIR"
  mkdir -p -- "$VERIFY_EXTRACTED_DIR"
  tar --zstd -xf "$bundle" -C "$VERIFY_EXTRACTED_DIR"
  printf '%s\n' "$VERIFY_EXTRACTED_DIR"
}

record_soname_provider() {
  local soname="$1"
  local path="$2"
  local provider_realpath="$3"
  local existing_realpath="${soname_to_realpath[$soname]:-}"

  if [[ -n "$existing_realpath" && "$existing_realpath" != "$provider_realpath" ]]; then
    soname_to_duplicate_count["$soname"]="$(( ${soname_to_duplicate_count[$soname]:-1} + 1 ))"
    soname_to_paths["$soname"]+=$'\n'"$path -> $provider_realpath"
    return 0
  fi

  soname_to_realpath["$soname"]="$provider_realpath"
  soname_to_paths["$soname"]="${soname_to_paths[$soname]:-$path -> $provider_realpath}"
}

scan_soname_providers() {
  local tree="$1"
  local path soname provider_realpath

  declare -gA soname_to_realpath=()
  declare -gA soname_to_paths=()
  declare -gA soname_to_duplicate_count=()

  while IFS= read -r -d '' path; do
    is_elf "$path" || continue
    soname="$(soname_of "$path")"
    [[ -n "$soname" ]] || continue
    provider_realpath="$(realpath -e -- "$path")"
    record_soname_provider "$soname" "$path" "$provider_realpath"
  done < <(find "$tree/lib" \( -type f -o -type l \) -print0)
}

verify_glib_soname_providers() {
  local tree="$1"
  local soname duplicate_count provider

  scan_soname_providers "$tree"

  for soname in "${GLIB_SONAMES[@]}"; do
    provider="${soname_to_realpath[$soname]:-}"
    [[ -n "$provider" ]] || fail "SONAME $soname has zero providers under $tree/lib"

    duplicate_count="${soname_to_duplicate_count[$soname]:-1}"
    if (( duplicate_count != 1 )); then
      printf '[verify-bundle] SONAME %s has multiple real providers:\n%s\n' \
        "$soname" "${soname_to_paths[$soname]}" >&2
      fail "SONAME $soname must have exactly one provider"
    fi

    printf '[verify-bundle] SONAME %s provider: %s\n' "$soname" "$provider" >&2
  done
}

print_needed_mismatch() {
  local base_soname="$1"
  local base_file="$2"
  local other_soname="$3"
  local other_file="$4"

  printf '[verify-bundle] NEEDED mismatch between %s and %s\n' "$base_soname" "$other_soname" >&2
  printf -- '--- %s (%s)\n' "$base_soname" "$base_file" >&2
  printf -- '+++ %s (%s)\n' "$other_soname" "$other_file" >&2
  comm -3 <(needed_list "$base_file") <(needed_list "$other_file") \
    | awk '{ if ($0 ~ /^\t/) { sub(/^\t/, "+ "); print } else { print "- " $0 } }' >&2
}

verify_glib_needed_lists_match() {
  local base_soname="${GLIB_SONAMES[0]}"
  local base_file="${soname_to_realpath[$base_soname]}"
  local base_needed other_soname other_file other_needed

  base_needed="$(needed_list "$base_file")"
  for other_soname in "${GLIB_SONAMES[@]:1}"; do
    other_file="${soname_to_realpath[$other_soname]}"
    other_needed="$(needed_list "$other_file")"
    if [[ "$base_needed" != "$other_needed" ]]; then
      print_needed_mismatch "$base_soname" "$base_file" "$other_soname" "$other_file"
      fail "GLib trio provider NEEDED lists differ"
    fi
  done
}

verify_ldd_path() {
  local tree="$1"
  local bin="$2"
  local tree_real="$3"
  local line dep dep_name dep_real

  while IFS= read -r line; do
    if [[ "$line" == *'not found'* ]]; then
      fail "missing runtime dependency for $bin: $line"
    fi

    if [[ "$line" =~ \=\>[[:space:]](/[^[:space:]]+) ]]; then
      dep="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[[:space:]]*(/[^[:space:]]+) ]]; then
      dep="${BASH_REMATCH[1]}"
    else
      continue
    fi

    dep_name="$(basename -- "$dep")"
    if is_base_loader_lib "$dep_name"; then
      continue
    fi

    dep_real="$(realpath -m -- "$dep")"
    if [[ "$dep_real" == "$tree_real"/* ]]; then
      continue
    fi
    if [[ "$dep" == /usr/lib/* || "$dep_real" == /usr/lib/* ]]; then
      fail "$bin resolves dependency outside bundle under /usr/lib: $line"
    fi
  done < <(LD_LIBRARY_PATH="$tree/lib:${LD_LIBRARY_PATH:-}" ldd "$bin")
}

verify_bin_ldd() {
  local tree="$1"
  local tree_real path

  tree_real="$(resolve_bundle_path "$tree")"
  while IFS= read -r -d '' path; do
    is_elf "$path" || continue
    verify_ldd_path "$tree" "$path" "$tree_real"
  done < <(find "$tree/bin" -maxdepth 1 \( -type f -o -type l \) -print0)
}

verify_ffmpeg_encoders() {
  local tree="$1"
  local ffmpeg="$tree/bin/ffmpeg"
  local output encoder

  [[ -x "$ffmpeg" ]] || fail "ffmpeg is missing or not executable: $ffmpeg"
  output="$(LD_LIBRARY_PATH="$tree/lib:${LD_LIBRARY_PATH:-}" "$ffmpeg" --list-encoders)"

  for encoder in "${REQUIRED_ENCODERS[@]}"; do
    if ! grep -Fq -- "$encoder" <<<"$output"; then
      fail "ffmpeg --list-encoders is missing required encoder: $encoder"
    fi
  done
}

verify_vips_version() {
  local tree="$1"
  local vips="$tree/bin/vips"

  [[ -x "$vips" ]] || fail "vips is missing or not executable: $vips"
  LD_LIBRARY_PATH="$tree/lib:${LD_LIBRARY_PATH:-}" "$vips" --version >/dev/null
}

main() {
  if (( $# > 1 )); then
    printf '[verify-bundle] error: expected at most one argument\n' >&2
    printf 'usage: scripts/verify-bundle.sh [INSTALL_TREE_OR_BUNDLE.tar.zst]\n' >&2
    return 1
  fi

  local input="${1:-$DEFAULT_INSTALL_TREE}"
  local tree

  require_cmd file
  require_cmd grep
  require_cmd readelf
  require_cmd realpath
  require_cmd find
  require_cmd sort
  require_cmd comm
  require_cmd awk
  require_cmd ldd

  if [[ "$input" == *.tar.zst ]]; then
    tree="$(extract_bundle "$input")"
  else
    tree="$(resolve_bundle_path "$input")"
  fi

  ensure_tree_shape "$tree"
  verify_glib_soname_providers "$tree"
  verify_bin_ldd "$tree"
  verify_ffmpeg_encoders "$tree"
  verify_vips_version "$tree"

  printf '\033[32m✓ Bundle verification passed: %s\033[0m\n' "$tree"
}

main "$@"
