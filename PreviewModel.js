function parseDesktopEntry(raw) {
  var lines = String(raw || "").split(/\r?\n/)
  var inEntry = false
  var values = ({})
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/^\s*[#;]/.test(line) || !line.trim()) continue
    if (/^\s*\[/.test(line)) {
      inEntry = line.trim() === "[Desktop Entry]"
      continue
    }
    if (!inEntry) continue
    var equals = line.indexOf("=")
    if (equals <= 0) continue
    var key = line.slice(0, equals).trim()
    if (key.indexOf("[") >= 0) continue
    values[key] = line.slice(equals + 1).trim()
  }
  return values
}

function desktopSummary(values) {
  var fields = ["Name", "GenericName", "Comment", "Type", "Exec", "TryExec", "Icon", "Categories", "Keywords", "Terminal", "Path", "URL"]
  var lines = []
  for (var i = 0; i < fields.length; i++) {
    var key = fields[i]
    if (values[key] !== undefined && values[key] !== "") lines.push(key + ": " + values[key])
  }
  return lines.join("\n")
}

function boundedText(buffer, maxLines) {
  var text = buffer.toString("utf8").replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  var lines = text.split("\n")
  var truncated = lines.length > maxLines
  if (truncated) lines = lines.slice(0, maxLines)
  return { text: lines.join("\n"), truncated: truncated }
}

function looksBinary(buffer) {
  if (!buffer || buffer.length === 0) return false
  var suspicious = 0
  for (var i = 0; i < buffer.length; i++) {
    var byte = buffer[i]
    if (byte === 0) return true
    if (byte < 7 || (byte > 13 && byte < 32)) suspicious += 1
  }
  return suspicious / buffer.length > 0.08
}

function escapeRichText(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}

function ansiColor(index) {
  var basic = [
    "#000000", "#cd3131", "#0dbc79", "#e5e510",
    "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
    "#666666", "#f14c4c", "#23d18b", "#f5f543",
    "#3b8eea", "#d670d6", "#29b8db", "#ffffff"
  ]
  if (index >= 0 && index < basic.length) return basic[index]
  if (index >= 16 && index <= 231) {
    var value = index - 16
    var levels = [0, 95, 135, 175, 215, 255]
    var red = levels[Math.floor(value / 36) % 6]
    var green = levels[Math.floor(value / 6) % 6]
    var blue = levels[value % 6]
    return rgbHex(red, green, blue)
  }
  if (index >= 232 && index <= 255) {
    var gray = 8 + (index - 232) * 10
    return rgbHex(gray, gray, gray)
  }
  return ""
}

function rgbHex(red, green, blue) {
  function component(value) {
    var hex = Math.max(0, Math.min(255, Number(value) || 0)).toString(16)
    return hex.length === 1 ? "0" + hex : hex
  }
  return "#" + component(red) + component(green) + component(blue)
}

function ansiToHtml(raw) {
  var text = String(raw || "")
  var expression = /\x1b\[([0-9;]*)m/g
  var style = { color: "", bold: false, italic: false }
  var cursor = 0
  var out = ""

  function render(segment) {
    if (!segment) return ""
    var escaped = escapeRichText(segment)
      .replace(/ /g, "&#160;")
      .replace(/\t/g, "&#160;&#160;&#160;&#160;")
      .replace(/\n/g, "<br>")
    var declarations = []
    if (style.color) declarations.push("color:" + style.color)
    if (style.bold) declarations.push("font-weight:700")
    if (style.italic) declarations.push("font-style:italic")
    return declarations.length ? "<span style=\"" + declarations.join(";") + "\">" + escaped + "</span>" : escaped
  }

  function applyCodes(codes) {
    if (codes.length === 0) codes = [0]
    for (var i = 0; i < codes.length; i++) {
      var code = codes[i]
      if (code === 0) style = { color: "", bold: false, italic: false }
      else if (code === 1) style.bold = true
      else if (code === 3) style.italic = true
      else if (code === 22) style.bold = false
      else if (code === 23) style.italic = false
      else if (code === 39) style.color = ""
      else if (code >= 30 && code <= 37) style.color = ansiColor(code - 30)
      else if (code >= 90 && code <= 97) style.color = ansiColor(code - 90 + 8)
      else if (code === 38 && codes[i + 1] === 2 && i + 4 < codes.length) {
        style.color = rgbHex(codes[i + 2], codes[i + 3], codes[i + 4])
        i += 4
      } else if (code === 38 && codes[i + 1] === 5 && i + 2 < codes.length) {
        style.color = ansiColor(codes[i + 2])
        i += 2
      }
    }
  }

  var match
  while ((match = expression.exec(text)) !== null) {
    out += render(text.slice(cursor, match.index))
    var codes = match[1] === "" ? [] : match[1].split(";").map(function(value) { return Number(value) })
    applyCodes(codes)
    cursor = expression.lastIndex
  }
  out += render(text.slice(cursor))
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    parseDesktopEntry: parseDesktopEntry,
    desktopSummary: desktopSummary,
    boundedText: boundedText,
    looksBinary: looksBinary,
    escapeRichText: escapeRichText,
    ansiColor: ansiColor,
    ansiToHtml: ansiToHtml
  }
}
