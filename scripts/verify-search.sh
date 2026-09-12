#!/usr/bin/env bash
# CI provenance gate: rebuild bin/omniscope-search from clean source with the
# pinned toolchain and prove the committed digest matches BOTH the shipped
# executable and the freshly built one. Fails when the shipped binary diverges
# from the source so an unreviewed executable can never slip through.
set -euo pipefail
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$plugin_dir/scripts/normalize-elf.sh"

cd "$plugin_dir"
test -x bin/omniscope-search
test -s bin/omniscope-search.sha256
(cd bin && sha256sum -c omniscope-search.sha256)

build_dir=$(mktemp -d)/omniscope-target
trap 'rm -rf "$build_dir"' EXIT
cargo build --release --locked --target-dir "$build_dir"

built=$(mktemp)
trap 'rm -f "$built"; rm -rf "$build_dir"' EXIT
normalize_elf "$build_dir/release/omniscope-search" "$built"

shipped_hash=$(cut -d' ' -f1 bin/omniscope-search.sha256)
built_hash=$(sha256sum "$built" | cut -d' ' -f1)
echo "shipped: $shipped_hash"
echo "built  : $built_hash"

if [[ "$shipped_hash" != "$built_hash" ]]; then
  echo "ERROR: shipped bin/omniscope-search does not match a clean build of src/." >&2
  echo "Rebuild and re-ship: bash scripts/build-search.sh && commit bin/omniscope-search*. " >&2
  exit 1
fi

echo "OK: shipped binary matches the pinned clean build of src/."