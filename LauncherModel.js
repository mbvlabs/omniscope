// Pure helpers for turning Omarchy's JSONC menu into OmniScope launcher rows.

function stripJsonc(raw) {
  return String(raw || "")
    .replace(/^\s*\/\/[^\n]*(\n|$)/gm, "")
    .replace(/,(\s*[}\]])/g, "$1")
}

function normalizeAliases(value) {
  if (Array.isArray(value)) return value.filter(function(v) { return !!v })
  if (typeof value === "string" && value) return [value]
  return []
}

function normalizeItem(id, value) {
  var raw = value || {}
  var parent = raw.parent
  if (parent === undefined)
    parent = id.indexOf(".") >= 0 ? id.split(".").slice(0, -1).join(".") : "root"
  return {
    id: id,
    parent: parent,
    icon: raw.icon || "",
    label: raw.label || id,
    description: raw.description || "",
    action: raw.action || "",
    aliases: normalizeAliases(raw.aliases),
    when: raw.when || ""
  }
}

function parseMenuJsonc(raw) {
  var parsed
  try { parsed = JSON.parse(stripJsonc(raw)) } catch (e) { return [] }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return []
  var source = parsed.items && typeof parsed.items === "object" ? parsed.items : parsed
  var out = []
  for (var id in source) {
    if (!source[id] || typeof source[id] !== "object" || Array.isArray(source[id])) continue
    out.push(normalizeItem(id, source[id]))
  }
  return out
}

function mergeMenuSources(defaultItems, userItems) {
  var merged = ({})
  var order = []
  var sources = [defaultItems || [], userItems || []]
  for (var s = 0; s < sources.length; s++) {
    for (var i = 0; i < sources[s].length; i++) {
      var item = sources[s][i]
      if (!item || !item.id) continue
      if (!merged[item.id]) order.push(item.id)
      var next = ({})
      var previous = merged[item.id] || ({})
      for (var key in previous) next[key] = previous[key]
      for (var nextKey in item) next[nextKey] = item[nextKey]
      merged[item.id] = next
    }
  }
  return { items: merged, order: order }
}

function pathFor(items, id) {
  var labels = []
  var current = items[id]
  var guard = 0
  while (current && current.id !== "root" && guard < 32) {
    labels.unshift(current.label)
    current = items[current.parent]
    guard += 1
  }
  return labels.join(" › ")
}

function launcherLabel(items, item) {
  var path = pathFor(items, item.id)
  var parts = path.split(" › ")
  if (parts[0] === "Install" && parts.length > 1)
    return "Install " + parts[parts.length - 1]
  return item.label
}

function buildLauncherRows(defaultItems, userItems, whenResults, sourcePath) {
  var menu = mergeMenuSources(defaultItems, userItems)
  var rows = []
  for (var i = 0; i < menu.order.length; i++) {
    var item = menu.items[menu.order[i]]
    if (!item || !item.action) continue
    if (item.when && whenResults && whenResults[item.id] === false) continue
    var breadcrumb = pathFor(menu.items, item.id)
    var label = launcherLabel(menu.items, item)
    var locator = "omarchy-menu://" + item.id
    var aliases = item.aliases.slice()
    aliases.push(item.id.replace(/[._-]+/g, " "), breadcrumb, item.label, item.action)
    var row = {
      id: "launcher." + item.id,
      launcherId: item.id,
      kind: "launcher",
      source: "Omarchy menu",
      label: label,
      detail: breadcrumb,
      category: breadcrumb,
      action: item.action,
      description: item.description || ("Runs the existing Omarchy “" + breadcrumb + "” workflow."),
      icon: item.icon || "",
      path: locator,
      sourcePath: sourcePath + "#" + item.id,
      aliases: aliases
    }
    rows.push(row)
  }
  return rows
}

function shellQuote(value) {
  return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
}

function guardScript(defaultItems, userItems) {
  var menu = mergeMenuSources(defaultItems, userItems)
  var lines = []
  for (var i = 0; i < menu.order.length; i++) {
    var item = menu.items[menu.order[i]]
    if (!item || !item.action || !item.when) continue
    lines.push("if ( " + item.when + " ) >/dev/null 2>&1; then printf '%s\\t1\\n' " + shellQuote(item.id) + "; else printf '%s\\t0\\n' " + shellQuote(item.id) + "; fi")
  }
  return lines.join("\n")
}

function parseGuardResults(raw) {
  var out = ({})
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts.length === 2 && parts[0]) out[parts[0]] = parts[1] === "1"
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    stripJsonc: stripJsonc,
    parseMenuJsonc: parseMenuJsonc,
    mergeMenuSources: mergeMenuSources,
    pathFor: pathFor,
    buildLauncherRows: buildLauncherRows,
    guardScript: guardScript,
    parseGuardResults: parseGuardResults
  }
}
