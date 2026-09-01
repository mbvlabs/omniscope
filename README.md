# OmniScope

![OmniScope preview](preview.png)

Telescope-inspired search for the Omarchy shell. OmniScope is a summoned menu plugin that searches applications, files, Omarchy launchers, and shows inline file previews.

## Install

```sh
omarchy plugin add https://github.com/mbvlabs/omniscope.git --enable
```

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
- **Files** — home-directory files with live query filtering
- **Launchers** — actions from your Omarchy menu configuration

Use `Tab` / `Shift+Tab` to switch modes. Type to filter, arrow keys to navigate, `Enter` to open, `Escape` to close.

## Dependencies

OmniScope expects these commands on `PATH`:

| Command | Used for |
|---------|----------|
| `fd` | File indexing and live search |
| `node` | File preview worker |
| `bat` | Syntax-highlighted text previews |
| `file` | MIME type detection |

On Omarchy, `fd`, `bat`, and `file` are typically already available. Ensure `node` is installed if you want file previews.

## Remove

```sh
omarchy plugin remove io.github.mbvlabs.omniscope
```

## License

MIT — see [LICENSE](LICENSE).
