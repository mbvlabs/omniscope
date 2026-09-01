// Nerd Font file glyphs shared by the result list and preview pane.

var defaultIcon = "\uf15b"

var extensionIcons = {
  go: "",
  js: "",
  jsx: "",
  mjs: "",
  cjs: "",
  ts: "",
  tsx: "",
  json: "",
  jsonc: "",
  md: "",
  markdown: "",
  lua: "",
  py: "",
  pyw: "",
  rs: "",
  sh: "",
  bash: "",
  zsh: "",
  fish: "",
  html: "",
  htm: "",
  css: "",
  scss: "",
  sass: "",
  vue: "",
  svelte: "",
  c: "",
  h: "",
  cc: "",
  cpp: "",
  cxx: "",
  hpp: "",
  java: "",
  php: "",
  rb: "",
  swift: "",
  kt: "",
  kts: "",
  sql: "",
  db: "",
  sqlite: "",
  toml: "",
  yaml: "",
  yml: "",
  xml: "󰗀",
  qml: "",
  pdf: "󰈦",
  png: "󰋩",
  jpg: "󰋩",
  jpeg: "󰋩",
  gif: "󰋩",
  webp: "󰋩",
  svg: "󰜡",
  bmp: "󰋩",
  tiff: "󰋩",
  mp3: "󰎆",
  flac: "󰎆",
  wav: "󰎆",
  ogg: "󰎆",
  mp4: "󰕧",
  mkv: "󰕧",
  mov: "󰕧",
  webm: "󰕧",
  zip: "",
  gz: "",
  bz2: "",
  xz: "",
  zst: "",
  tar: "",
  lock: "󰌾",
  log: "󰌱",
  txt: "󰈙"
}

var filenameIcons = {
  "dockerfile": "󰡨",
  "compose.yaml": "󰡨",
  "compose.yml": "󰡨",
  "package.json": "",
  "package-lock.json": "",
  "go.mod": "",
  "go.sum": "",
  "cargo.toml": "",
  "cargo.lock": "",
  "makefile": "",
  "license": "",
  "readme": "󰂺",
  "readme.md": "󰂺"
}

function iconForPath(path) {
  var name = String(path || "").split("/").pop().toLowerCase()
  if (!name) return defaultIcon
  if (filenameIcons[name]) return filenameIcons[name]
  if (name.indexOf(".env") === 0 || name === ".gitignore" || name === ".gitattributes") return ""
  var dot = name.lastIndexOf(".")
  if (dot < 0 || dot === name.length - 1) return defaultIcon
  return extensionIcons[name.slice(dot + 1)] || defaultIcon
}

if (typeof module !== "undefined") {
  module.exports = {
    iconForPath: iconForPath
  }
}
