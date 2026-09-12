#!/usr/bin/env bash
# Deterministic ELF normalization: remove host-specific sections that
# vary between build machines (GCC version strings, GNU build-id notes,
# CET property notes) so the same source+toolchain produces byte-identical
# output regardless of the host toolchain.
set -euo pipefail

normalize_elf() {
  local src="$1" dst="$2" tmp mode
  tmp=$(mktemp)
  mode=$(stat -c %a "$src")
  cp -p "$src" "$tmp"
  for sec in .comment .note.gnu.build-id .note.gnu.property; do
    objcopy --remove-section="$sec" "$tmp" 2>/dev/null || true
  done
  chmod "$mode" "$tmp"
  cp -p "$tmp" "$dst"
  rm -f "$tmp"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -ge 2 ]] || { echo "usage: normalize-elf.sh <input> <output>" >&2; exit 1; }
  normalize_elf "$1" "$2"
fi
