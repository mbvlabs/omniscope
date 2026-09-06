# OmniScope

![OmniScope preview](preview.png)

Telescope-inspired search for the Omarchy shell. OmniScope is a summoned menu plugin that searches applications, files, Omarchy launchers, and shows inline file previews.

## Install

```sh
omarchy plugin add https://github.com/mbvlabs/omniscope.git --enable
cd ~/.config/omarchy/plugins/io.github.mbvlabs.omniscope
bash scripts/build-search.sh
```

Build the search helper after installing or updating the plugin. This requires
a current stable Rust toolchain; on Omarchy, `omarchy pkg add rust` installs
one. The build script installs the executable in the plugin's `bin/` directory
and keeps compiler output in `~/.cache/omniscope/target`. Rust is only needed at
build time. After updating, use `omarchy restart shell` to load the new helper
and clear any cached QML code.

## Usage

Summon OmniScope from the shell:

```sh
omarchy-shell shell summon io.github.mbvlabs.omniscope '{}'
```

A common keybinding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SPACE", "OmniScope", "omarchy-shell shell summon io.github.mbvlabs.omniscope '{}'")
```

### Modes

- **All** — search across applications, files, and Omarchy launchers
- **Apps** — desktop applications only
- **Files** — fuzzy search across the home-directory file index
- **Launchers** — actions from your Omarchy menu configuration

Use `Tab` / `Shift+Tab` to switch modes. Type to filter, arrow keys to navigate, `Enter` to open, `Escape` to close.

The Rust helper stays alive between openings, indexes files in the background,
and refreshes the index every 60 seconds. It includes hidden files, respects Git
ignore rules, and excludes `.git`, `node_modules`, and `.cache` directories.
New or deleted files appear after the next refresh. File queries match paths
relative to your home directory; words may match in any order, and each word is
fuzzy matched. Exact filenames and filename prefixes rank first. Results load
in pages of 100 as you scroll or navigate; the count shows all matches.

Only UTF-8 filenames are indexed. Spaces and embedded newlines are preserved.
Application and launcher actions continue to use Omarchy's existing launchers.

## Dependencies

OmniScope uses the following executables (only the preview tools need to be on `PATH`):

| Command | Used for |
|---------|----------|
| `bin/omniscope-search` | Persistent Rust indexing and fuzzy search (build above) |
| `node` | File preview worker |
| `bat` | Syntax-highlighted text previews |
| `file` | MIME type detection |

On Omarchy, `bat` and `file` are typically already available. Ensure `node` is installed if you want file previews.

## Development

```sh
cargo test --locked
cargo clippy --locked --all-targets -- -D warnings
bash scripts/build-search.sh
node scripts/benchmark-search.mjs
```

The benchmark measures uncached queries against your home-directory index and
reports both worker time and JSON round-trip time. An optional executable path
and search root can be passed as its first and second arguments.

The helper accepts newline-delimited JSON on stdin: `replace` supplies app and
launcher metadata, `search` accepts `id`, `query`, `mode`, `offset`, and `limit`,
`refresh` rescans files, and `cancel` abandons the current search. Stdout contains
`ready`, `indexed`, `results`, and `error` messages. Results include request IDs,
index versions, total counts, and highlight ranges in UTF-16 offsets. Closing
stdin terminates the helper. No file index is written to disk.

## Remove

```sh
omarchy plugin remove io.github.mbvlabs.omniscope
```

## License

MIT — see [LICENSE](LICENSE).
