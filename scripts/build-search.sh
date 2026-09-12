#!/usr/bin/env bash
# Rebuild the bundled search helper from source with the pinned toolchain,
# normalize it for reproducible output, and commit-worthy artifacts:
#   bin/omniscope-search            the shipped executable
#   bin/omniscope-search.sha256     its SHA-256 digest
# Commit both files together after changing anything under src/.
set -euo pipefail
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$plugin_dir/scripts/normalize-elf.sh"

build_dir=${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/omniscope/target}

cd "$plugin_dir"
cargo build --release --locked --target-dir "$build_dir"
normalize_elf "$build_dir/release/omniscope-search" "$plugin_dir/bin/omniscope-search"
(cd "$plugin_dir/bin" && sha256sum omniscope-search > omniscope-search.sha256)

echo "Shipped bin/omniscope-search:"
sha256sum "$plugin_dir/bin/omniscope-search"