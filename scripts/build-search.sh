#!/usr/bin/env bash
set -euo pipefail
plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
build_dir=${CARGO_TARGET_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/omniscope/target}
cargo build --release --locked --manifest-path "$plugin_dir/Cargo.toml" --target-dir "$build_dir"
install -Dm755 "$build_dir/release/omniscope-search" "$plugin_dir/bin/omniscope-search"
