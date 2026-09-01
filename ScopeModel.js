// OmniScope fuzzy matching engine.
//
// Pure-JS, in-memory fuzzy finder tuned for the Omarchy Quickshell process.
// Items are loaded once when the panel opens; each keystroke re-ranks the
// in-memory array rather than re-spawning a process.

// Returns null when the query chars do not all appear in `text` in order,
// otherwise an object with the match score and the text ranges to highlight.
function fuzzyMatch(query, text) {
  var needle = String(query || "").toLowerCase()
  var haystack = String(text || "").toLowerCase()
  if (!needle) return { score: 0, ranges: [] }

  var needleLen = needle.length
  var haystackLen = haystack.length
  if (needleLen > haystackLen) return null

  // Greedy best-position scan. Walk the needle left to right and place each
  // char at the earliest possible haystack position; this is exactly fzf's
  // "we match the earliest occurrences" heuristic and gives us the easiest
  // (most likely consecutive) run.
  var positions = new Array(needleLen)
  var searchFrom = 0
  for (var i = 0; i < needleLen; i++) {
    var found = haystack.indexOf(needle[i], searchFrom)
    if (found < 0) return null
    positions[i] = found
    searchFrom = found + 1
  }

  // Improve the match: try to pull each char as far left as allowed while
  // staying in order, which recovers better boundaries. This mirrors fzf's
  // backward pass that prefers earlier, better-anchored matches.
  for (var scan = needleLen - 1; scan >= 1; scan--) {
    var target = scan - 1
    var limit = positions[target + 1]
    // Look for a better (earlier) home for positions[scan] within
    // [positions[scan]-1, positions[target]+1).
    var best = positions[scan]
    for (var p = positions[scan] - 1; p >= positions[target] + 1; p--) {
      if (haystack[p] === needle[scan]) best = p
      else break
    }
    positions[scan] = best
  }

  var score = 0
  var consecutive = 1
  var firstChar = positions[0]
  var ranges = []
  var rangeStart = positions[0]
  var rangeEnd = positions[0]

  for (var j = 0; j < needleLen; j++) {
    var pos = positions[j]
    var isWordStart = (pos === 0) || !isWordChar(haystack[pos - 1])

    if (j > 0 && pos === positions[j - 1] + 1) {
      consecutive += 1
    } else {
      consecutive = 1
    }

    score += 16
    if (consecutive === 2) score += 12
    else if (consecutive >= 3) score += 8
    if (isWordStart) score += 8
    if (haystack[pos] === needle[j] && j === 0 && pos === 0) score += 4

    if (j > 0 && pos === positions[j - 1] + 1) {
      rangeEnd = pos
    } else {
      if (j > 0) ranges.push({ start: rangeStart, end: rangeEnd + 1 })
      rangeStart = pos
      rangeEnd = pos
    }
  }
  ranges.push({ start: rangeStart, end: rangeEnd + 1 })

  if (firstChar > 0) score -= firstChar

  return { score: score, ranges: ranges }
}

function isWordChar(c) {
  return /[a-zA-Z0-9_]/.test(c)
}

// Rank a single pre-normalized item against the query. `item` has already had
// its text fields expanded into `searchText` (label + aliases + description +
// path folded to lowercase). Returns null if no field matches, else the item
// augmented with score and highlight ranges per visible field.
function rankItem(item, query) {
  if (!item) return null

  var result = fuzzyMatch(query, item.searchText)
  if (!result) return null

  var labelMatch = fuzzyMatch(query, item.label)
  var pathMatch = fuzzyMatch(query, item.pathText)

  var score = result.score
  // Prefer exact / prefix hits heavily, mirroring the menu's scoring tiers.
  var labelLower = item.label.toLowerCase()
  var q = String(query || "").toLowerCase()
  if (labelLower === q) score += 1000
  else if (labelLower.indexOf(q) === 0) score += 500
  else if (labelLower.indexOf(q) >= 0) score += 200
  else if (pathMatch && pathMatch.score > score) score = pathMatch.score + 100
  else if (item.label.indexOf(q) >= 0) score += 60

  // Apps float slightly above other equal-relevance result kinds.
  if (item.kind === "app") score += 5

  var out = {
    id: item.id,
    kind: item.kind,
    label: item.label,
    detail: item.detail,
    icon: item.icon,
    appId: item.appId,
    appName: item.appName,
    path: item.path,
    fileSize: item.fileSize,
    fileType: item.fileType,
    mtime: item.mtime,
    executable: item.executable,
    launcherId: item.launcherId,
    source: item.source,
    sourcePath: item.sourcePath,
    category: item.category,
    action: item.action,
    description: item.description,
    score: score,
    labelRanges: labelMatch ? labelMatch.ranges : [],
    pathRanges: pathMatch ? pathMatch.ranges : []
  }
  return out
}

// Sort a list of already-ranked items best-first, ties broken by label.
function sortRanked(items) {
  return items.slice().sort(function(a, b) {
    if (a.score !== b.score) return b.score - a.score
    var la = String(a.label || "").toLowerCase()
    var lb = String(b.label || "").toLowerCase()
    if (la < lb) return -1
    if (la > lb) return 1
    return 0
  })
}

// Main entry: given the raw loaded items (apps + files) and a query, return
// the ranked, filtered array to display.
function search(items, query) {
  if (!Array.isArray(items)) return []
  var q = String(query || "").trim()
  if (!q) return items.slice()

  var ranked = []
  for (var i = 0; i < items.length; i++) {
    var hit = rankItem(items[i], q)
    if (hit) ranked.push(hit)
  }
  return sortRanked(ranked)
}

// Build the searchText field for a raw item at load time so the hot path
// (per keystroke) never has to rebuild strings or lower-case repeatedly.
function buildSearchText(item) {
  var label = String(item.label || "")
  var extra = ""
  if (Array.isArray(item.aliases)) extra = item.aliases.join(" ")
  var pathPart = String(item.path || "")
  var searchText = (label + " " + extra + " " + pathPart).toLowerCase()
  return searchText
}

if (typeof module !== "undefined") {
  module.exports = {
    fuzzyMatch: fuzzyMatch,
    rankItem: rankItem,
    sortRanked: sortRanked,
    search: search,
    buildSearchText: buildSearchText
  }
}
