import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "LauncherModel.js" as Launchers
import "FileIcons.js" as FileIcons

Item {
    id: root

    // Injected by omarchy-shell when this plugin is summoned.
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null

    // Shared application library (DesktopEntries), owned by the shell.
    readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

    // ------------------------------------------------------------------ state
    property bool opened: false
    property string mode: "all"        // "all" | "apps" | "files" | "launchers"
    property string filterText: ""
    property int selectedIndex: 0
    property bool cursorActive: true
    property bool appsLoaded: false
    property bool launchersLoaded: false
    property int loadRevision: 0
    property var desktopPaths: ({})

    property var apps: []              // raw app rows
    property var launchers: []          // Omarchy menu action rows
    property var displayRows: []       // ranked, filtered rows for display
    property bool searchReady: false
    property bool searchStopping: false
    property bool searchBusy: false
    property bool pagePending: false
    property bool filesIndexed: false
    property int indexedFileCount: 0
    property int resultTotal: 0
    property int searchRevision: 0
    property int displayedRevision: -1
    property int resultIndexVersion: -1
    property int pendingSelection: -1
    property real searchElapsedMs: 0
    property string searchError: ""
    // Omarchy strips __sourceDir from third-party manifests. Resolve bundled
    // files against this QML document (must be a binding, not a JS helper —
    // Qt.resolvedUrl uses the caller's document URL).
    readonly property string pluginDir: {
        var url = String(Qt.resolvedUrl(".") || "");
        if (url.indexOf("file://") !== 0)
            return "";
        var path = decodeURIComponent(url.slice(7));
        if (path.indexOf("localhost/") === 0)
            path = path.slice(9);
        while (path.length > 1 && path.charAt(path.length - 1) === "/")
            path = path.slice(0, -1);
        return path.charAt(0) === "/" ? path : "";
    }
    readonly property string searchWorkerPath: root.pluginDir ? root.pluginDir + "/bin/omniscope-search" : ""
    readonly property string previewWorkerPath: root.pluginDir ? root.pluginDir + "/preview-worker.js" : ""

    ListModel { id: resultModel }

    readonly property string defaultMenuPath: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    readonly property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    property var defaultMenuItems: []
    property var userMenuItems: []
    property bool defaultMenuReady: false
    property bool userMenuReady: false
    property var launcherWhenResults: ({})

    property int previewRevision: 0
    property string previewRequestedId: ""
    property var pendingPreview: null
    property var previewCache: ({})
    property string previewState: "empty" // empty | structured | loading | text | desktop | image | unsupported | error
    property string previewName: ""
    property string previewLocator: ""
    property string previewMime: ""
    property string previewSizeText: ""
    property string previewContent: ""
    property bool previewRich: false
    property string previewImageSource: ""
    property string previewIconGlyph: "\uf15b"

    // ------------------------------------------------------------------ colors
    property color background: Color.menu.background
    property color foreground: Color.menu.text
    property color border: Color.menu.border
    property var borderSpec: Border.flat(Util.alpha(border, 0.62), 1)
    property color scrim: Color.menu.scrim
    property color selectedText: Color.menu.selectedText
    property color matchHighlight: Color.accent
    property string fontFamily: Style.font.menuFamily

    // Tailwind-like sizing tokens. Keeping these independent from the shell's
    // font/spacing multiplier gives this dense picker a predictable hierarchy.
    readonly property int tw1: 4
    readonly property int tw2: 8
    readonly property int tw3: 12
    readonly property int tw4: 16
    readonly property int tw6: 24
    readonly property int textXs: 12
    readonly property int textSm: 14
    readonly property int textBase: 16
    readonly property int textXl: 20

    property int searchHeight: 36
    property int resultRowHeight: 24
    property int rowSpacing: 0
    property int paneGap: tw3
    property int framePadding: tw2
    property int titleHeight: tw4
    property int frameRadius: 2
    property int previewWidth: Math.round(cardWidth * 0.58)
    readonly property int maxCollectorBytes: 2 * 1024 * 1024

    readonly property int cardWidth: Math.min(panel.width - tw6 * 2, 1024)
    readonly property int contentWidth: cardWidth
    property int resultsWidth: contentWidth - previewWidth - paneGap
    readonly property int cardHeight: Math.min(Math.round(cardWidth * 0.6), panel.height - tw6 * 2)
    readonly property int resultsHeight: cardHeight - searchHeight - paneGap
    readonly property string modeTitle: root.mode === "apps" ? "Applications" : (root.mode === "files" ? "Files" : (root.mode === "launchers" ? "Launchers" : "All"))

    // ------------------------------------------------------------------ hooks
    function open(payloadJson) {
        root.opened = true;
        // Clear a stuck stop gate from a previous close that missed onExited.
        if (root.searchStopping && !searchProc.running && !searchProc.processId)
            root.searchStopping = false;
        root.startLoad();
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus();
        });
    }

    function close() {
        root.opened = false;
        root.filterText = "";
        root.searchRevision += 1;
        searchStartupTimer.stop();
        root.searchError = "";
        // Prefer processId: `running` can lag and leave searchStopping stuck,
        // which then blocks every later ensureSearchWorker() call.
        root.searchStopping = root.searchStopping || !!searchProc.processId || searchProc.running;
        root.searchReady = false;
        searchProc.running = false;
        root.searchBusy = false;
        root.pagePending = false;
        root.filesIndexed = false;
        root.indexedFileCount = 0;
        root.resultTotal = 0;
        root.displayRows = [];
        resultModel.clear();
        previewTimer.stop();
        root.previewRevision += 1;
        root.pendingPreview = null;
        root.previewCache = ({});
        root.updatePreview();
        // If onExited never fires, clear the stop gate so the next open works.
        if (root.searchStopping)
            searchStopFallback.restart();
    }

    function toggle() {
        if (root.opened)
            root.close();
        else
            root.open("{}");
    }

    function ping() {
        return "ok";
    }

    function openFile(path) {
        var target = String(path || "");
        if (!target)
            return "invalid";
        Quickshell.execDetached([root.omarchyPath + "/bin/omarchy-launch-editor", target]);
        return "ok";
    }

    // ------------------------------------------------------------------ data
    function startLoad() {
        root.loadRevision += 1;
        var revision = root.loadRevision;
        root.launchersLoaded = root.defaultMenuReady && root.userMenuReady;
        root.selectedIndex = 0;
        root.cursorActive = true;
        root.filterText = "";
        root.previewCache = ({});
        root.previewRequestedId = "";
        root.pendingPreview = null;

        root.ensureSearchWorker();
        root.loadDesktopPaths(revision);
        root.loadApps(revision);
        if (root.launchersLoaded)
            root.rebuildLaunchers();
        root.rebuildDisplay();
    }

    function loadDesktopPaths(revision) {
        if (!desktopProc.running) {
            var home = Quickshell.env("HOME");
            var dataHome = Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share");
            var dataDirs = (Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share").split(":");
            var roots = [dataHome + "/applications"];
            for (var i = 0; i < dataDirs.length; i++) {
                if (dataDirs[i])
                    roots.push(dataDirs[i] + "/applications");
            }
            var quotedRoots = [];
            for (var r = 0; r < roots.length; r++)
                quotedRoots.push(Util.shellQuote(roots[r]));
            desktopProc.revision = revision;
            desktopProc.collected = "";
            desktopProc.command = ["bash", "-c", "for d in " + quotedRoots.join(" ") + "; do [[ -d \"$d\" ]] && find \"$d\" -type f -name '*.desktop' -print; done"];
            desktopProc.running = true;
        } else {
            desktopProc.pendingRevision = revision;
        }
    }

    function parseDesktopPaths(raw) {
        var lines = String(raw || "").split("\n");
        var out = ({});
        for (var i = 0; i < lines.length; i++) {
            var path = lines[i].trim();
            if (!path)
                continue;
            var file = path.split("/").pop();
            var id = file.slice(-8) === ".desktop" ? file.slice(0, -8) : file;
            // Roots are searched user-first; preserve the first match so local
            // desktop entries correctly shadow system entries.
            if (!out[id])
                out[id] = path;
            var marker = path.indexOf("/applications/");
            if (marker >= 0) {
                var relativeId = path.slice(marker + 14).replace(/\//g, "-");
                if (relativeId.slice(-8) === ".desktop")
                    relativeId = relativeId.slice(0, -8);
                if (!out[relativeId])
                    out[relativeId] = path;
            }
        }
        return out;
    }

    function desktopPathFor(appId) {
        var id = String(appId || "");
        if (id.slice(-8) === ".desktop")
            id = id.slice(0, -8);
        return root.desktopPaths[id] || ("desktop-entry://" + id + ".desktop");
    }

    function desktopEntryName(entry) {
        return String((entry && entry.name) || (entry && entry.id) || "");
    }

    function desktopEntrySubtext(entry) {
        return String((entry && entry.genericName) || "");
    }

    function launchApp(appId, appName) {
        if (root.appLibrary) {
            root.appLibrary.launch(appId, appName);
            return;
        }
        var id = String(appId || "");
        if (!id)
            return;
        // Same launch path AppLibrary uses when the shell facade is missing.
        Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"));
    }

    function loadApps(revision) {
        var rows = [];
        if (root.appLibrary) {
            rows = root.appLibrary.sortedEntries("");
        } else {
            // Omarchy injects manifest but sometimes not shell for third-party
            // keepLoaded menus, which leaves appLibrary null. Use DesktopEntries
            // directly so applications still appear in search.
            var values = [];
            try {
                values = DesktopEntries.applications.values || [];
            } catch (error) {
                values = [];
            }
            for (var v = 0; v < values.length; v++) {
                var desktopEntry = values[v];
                if (!desktopEntry || desktopEntry.noDisplay)
                    continue;
                if (!root.desktopEntryName(desktopEntry))
                    continue;
                rows.push({entry: desktopEntry});
            }
        }
        var out = [];
        for (var i = 0; i < rows.length; i++) {
            var entry = rows[i].entry;
            if (!entry)
                continue;
            var appId = String(entry.id || "");
            if (!appId)
                continue;
            var name = root.appLibrary ? root.appLibrary.entryName(entry) : root.desktopEntryName(entry);
            var generic = root.appLibrary ? root.appLibrary.entrySubtext(entry) : root.desktopEntrySubtext(entry);
            var desktopPath = root.desktopPathFor(appId);
            var raw = {
                id: "app." + appId,
                kind: "app",
                label: name,
                detail: generic,
                appId: appId,
                appName: name,
                path: desktopPath,
                aliases: [generic, desktopPath]
            };
            try {
                if (entry.keywords && typeof entry.keywords.join === "function")
                    raw.aliases = raw.aliases.concat(entry.keywords);
                if (entry.comment)
                    raw.aliases = raw.aliases.concat([String(entry.comment)]);
            } catch (e) {}
            out.push(raw);
        }
        root.apps = out;
        root.appsLoaded = true;
        root.maybeFinished(revision);
    }

    function rebuildLauncherSources() {
        if (!root.defaultMenuReady || !root.userMenuReady)
            return;
        root.rebuildLaunchers();
        root.evaluateLauncherGuards();
    }

    function rebuildLaunchers() {
        var rows = Launchers.buildLauncherRows(root.defaultMenuItems, root.userMenuItems, root.launcherWhenResults, root.defaultMenuPath);
        root.launchers = rows;
        root.launchersLoaded = true;
        root.maybeFinished(root.loadRevision);
    }

    function evaluateLauncherGuards() {
        var script = Launchers.guardScript(root.defaultMenuItems, root.userMenuItems);
        if (!script) {
            root.launcherWhenResults = ({});
            root.rebuildLaunchers();
            return;
        }
        if (launcherGuardProc.running) {
            launcherGuardProc.pending = true;
            return;
        }
        launcherGuardProc.pending = false;
        launcherGuardProc.collected = "";
        launcherGuardProc.command = ["bash", "-lc", script];
        launcherGuardProc.running = true;
    }

    function maybeFinished(revision) {
        if (revision !== root.loadRevision)
            return;
        root.sendSearch({type: "replace", items: root.apps.concat(root.launchers)});
        root.rebuildDisplay();
    }

    // ------------------------------------------------------------------ search
    function setFilter(next) {
        root.filterText = next;
        root.selectedIndex = 0;
        root.cursorActive = true;
        root.rebuildDisplay();
    }

    function rebuildDisplay() {
        if (!root.opened)
            return;
        root.searchRevision += 1;
        root.searchBusy = true;
        root.pagePending = false;
        root.pendingSelection = -1;
        previewTimer.stop();
        root.previewRevision += 1;
        root.previewRequestedId = "";
        root.pendingPreview = null;
        root.requestSearchPage(0);
    }

    function ensureSearchWorker() {
        if (!root.opened)
            return;
        // Recover from a missed onExited after close/reopen.
        if (root.searchStopping && !searchProc.running && !searchProc.processId) {
            root.searchStopping = false;
            searchStopFallback.stop();
        }
        if (root.searchStopping || searchProc.running || searchProc.processId)
            return;
        if (!root.searchWorkerPath) {
            root.searchBusy = false;
            root.searchError = "Search helper path is missing from the plugin manifest.";
            return;
        }
        root.searchReady = false;
        root.filesIndexed = false;
        root.searchError = "";
        searchProc.command = [root.searchWorkerPath];
        searchProc.running = true;
        searchStartupTimer.restart();
    }

    function sendSearch(message) {
        if (root.searchReady && searchProc.running)
            searchProc.write(JSON.stringify(message) + "\n");
    }

    function requestSearchPage(offset) {
        root.sendSearch({type: "search", id: root.searchRevision, query: root.filterText.trim(),
            mode: root.mode, offset: offset, limit: 100});
    }

    function loadMore() {
        if (!root.opened || root.searchBusy || root.pagePending || root.displayRows.length >= root.resultTotal)
            return;
        root.pagePending = true;
        root.requestSearchPage(root.displayRows.length);
    }

    function receiveSearch(data) {
        if (!root.opened || root.searchStopping)
            return;
        var message;
        try { message = JSON.parse(data); }
        catch (error) {
            root.searchError = "Search helper returned invalid data.";
            root.searchBusy = false;
            return;
        }
        if (message.type === "ready") {
            if (message.protocol !== 1) {
                root.searchError = "Rebuild the search helper to update it.";
                return;
            }
            searchStartupTimer.stop();
            root.searchReady = true;
            root.searchError = "";
            root.sendSearch({type: "replace", items: root.apps.concat(root.launchers)});
            root.rebuildDisplay();
            return;
        }
        if (message.type === "indexed") {
            root.filesIndexed = true;
            root.indexedFileCount = message.count;
            return;
        }
        if (message.type === "error") {
            root.searchError = message.message || "Search failed.";
            root.searchBusy = false;
            root.pagePending = false;
            return;
        }
        if (message.type !== "results" || !root.opened || message.id !== root.searchRevision
            || message.query !== root.filterText.trim() || message.mode !== root.mode)
            return;
        var rows = message.rows || [];
        if (message.offset !== 0 && (message.offset !== root.displayRows.length
            || message.indexVersion !== root.resultIndexVersion)) {
            root.rebuildDisplay();
            return;
        }
        var selectedId = root.displayedRevision === root.searchRevision && root.displayRows[root.selectedIndex]
            ? root.displayRows[root.selectedIndex].id : "";
        var positionSelection = message.offset === 0 || root.pendingSelection >= 0;
        // Model changes can emit contentYChanged while a page is being applied.
        root.pagePending = true;
        if (message.offset === 0) {
            resultModel.clear();
            root.displayRows = rows;
        } else {
            root.displayRows = root.displayRows.concat(rows);
        }
        for (var i = 0; i < rows.length; i++)
            resultModel.append({rowId: rows[i].id});
        root.resultTotal = message.total;
        root.resultIndexVersion = message.indexVersion;
        root.displayedRevision = message.id;
        root.searchElapsedMs = message.elapsedMs;
        root.searchBusy = false;
        root.pagePending = false;
        root.searchError = "";
        if (selectedId && message.offset === 0) {
            root.selectedIndex = 0;
            for (var s = 0; s < rows.length; s++)
                if (rows[s].id === selectedId) { root.selectedIndex = s; break; }
        }
        if (root.pendingSelection >= 0) {
            root.selectedIndex = root.pendingSelection;
            root.pendingSelection = -1;
        }
        root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.displayRows.length - 1));
        Qt.callLater(function () {
            if (positionSelection && root.selectedIndex >= 0 && root.selectedIndex < root.displayRows.length)
                resultList.positionViewAtIndex(root.selectedIndex, ListView.End);
        });
        root.updatePreview();
    }

    function searchStatus() {
        return JSON.stringify({ready: root.searchReady, indexed: root.filesIndexed,
            opened: root.opened, workerPid: searchProc.processId,
            running: searchProc.running, stopping: root.searchStopping,
            worker: root.searchWorkerPath, files: root.indexedFileCount,
            apps: root.apps.length, launchers: root.launchers.length,
            query: root.filterText, mode: root.mode, busy: root.searchBusy,
            total: root.resultTotal, loaded: root.displayRows.length,
            selected: root.selectedIndex, preview: root.previewState,
            elapsedMs: root.searchElapsedMs, error: root.searchError});
    }

    function updatePreview() {
        var row = root.selectedIndex >= 0 && root.selectedIndex < root.displayRows.length ? root.displayRows[root.selectedIndex] : null;
        if (!row) {
            root.previewRevision += 1;
            root.previewRequestedId = "";
            root.pendingPreview = null;
            root.previewState = "empty";
            root.previewName = "";
            root.previewLocator = "";
            root.previewMime = "";
            root.previewSizeText = "";
            root.previewContent = "";
            root.previewRich = false;
            root.previewImageSource = "";
            root.previewIconGlyph = "\uf15b";
            previewScroll.contentY = 0;
            return;
        }

        if (row.id === root.previewRequestedId)
            return;
        root.previewRevision += 1;
        var revision = root.previewRevision;
        root.previewRequestedId = row.id;
        root.pendingPreview = null;
        root.previewName = row.label || "";
        root.previewLocator = row.path || "";
        root.previewSizeText = "";
        root.previewRich = false;
        root.previewImageSource = "";
        previewScroll.contentY = 0;

        if (row.kind === "app") {
            root.previewState = "structured";
            root.previewMime = "Application";
            root.previewIconGlyph = "\ue900";
            root.previewContent = (row.detail ? row.detail + "\n\n" : "") + "Desktop entry\n" + (row.path || "");
            return;
        }
        if (row.kind === "launcher") {
            root.previewState = "structured";
            root.previewMime = row.source || "Omarchy launcher";
            root.previewIconGlyph = row.icon || "\uf135";
            root.previewContent = (row.description || "Omarchy launcher action.") + "\n\nCategory\n" + (row.category || "Omarchy") + "\n\nAction\n" + (row.action || "") + "\n\nSource\n" + (row.sourcePath || row.path || "");
            return;
        }

        root.previewState = "loading";
        root.previewMime = fileExt(row.path);
        root.previewIconGlyph = row.icon || "\uf15b";
        root.previewContent = "Loading bounded preview…";
        var cached = root.previewCache[row.path];
        if (cached) {
            root.applyFilePreview(row, revision, cached);
            return;
        }
        root.queueFilePreview(row, revision);
    }

    function queueFilePreview(row, revision) {
        root.pendingPreview = {
            id: row.id,
            path: row.path,
            row: row,
            revision: revision
        };
        previewTimer.restart();
    }

    function startFilePreview(request) {
        if (!request || request.id !== root.previewRequestedId || request.revision !== root.previewRevision)
            return;
        previewProc.rowId = request.id;
        previewProc.path = request.path;
        previewProc.revision = request.revision;
        previewProc.command = ["node", root.previewWorkerPath, request.path, root.background.hslLightness >= 0.5 ? "light" : "dark"];
        previewProc.running = true;
    }

    function applyFilePreview(row, revision, data) {
        if (!row || row.id !== root.previewRequestedId || revision !== root.previewRevision)
            return;
        root.previewState = data.state || "error";
        root.previewMime = data.mime || fileExt(row.path);
        root.previewSizeText = data.size || "";
        root.previewContent = data.content || data.message || "Preview unavailable.";
        root.previewRich = data.rich === true;
        if (data.truncated)
            root.previewContent += root.previewRich ? "<br><br>…&#160;preview&#160;truncated" : "\n\n… preview truncated";
        root.previewImageSource = data.imageData || "";
        root.previewIconGlyph = row.icon || (data.state === "image" ? "\uf03e" : "\uf15b");
    }

    function itemIcon(item) {
        if (!item)
            return "\uf15b";
        if (item.icon)
            return String(item.icon);
        if (item.kind === "app")
            return "\ue900";
        if (item.kind === "launcher")
            return "\uf135";
        return FileIcons.iconForPath(item.path);
    }

    function fileExt(path) {
        var name = String(path || "").split("/").pop();
        var dot = name.lastIndexOf(".");
        if (dot <= 0 || dot === name.length - 1)
            return "File";
        return name.substring(dot + 1).toUpperCase() + " file";
    }

    function select(delta) {
        if (root.searchBusy || root.displayRows.length === 0)
            return;
        root.cursorActive = true;
        var next = root.selectedIndex + delta;
        if (next >= root.displayRows.length && root.displayRows.length < root.resultTotal) {
            root.pendingSelection = next;
            root.loadMore();
            return;
        }
        root.selectedIndex = (root.selectedIndex + delta + root.displayRows.length) % root.displayRows.length;
        resultList.positionViewAtIndex(root.selectedIndex, ListView.End);
        root.updatePreview();
        if (root.selectedIndex >= root.displayRows.length - 15)
            root.loadMore();
    }

    function scrollPreview(pixels) {
        if (previewScroll.contentHeight <= previewScroll.height)
            return;
        var maximum = Math.max(0, previewScroll.contentHeight - previewScroll.height);
        previewScroll.contentY = Math.max(0, Math.min(maximum, previewScroll.contentY + pixels));
    }

    function activateSelected() {
        if (!root.searchReady || root.searchError || root.searchBusy || root.displayedRevision !== root.searchRevision
            || root.selectedIndex < 0 || root.selectedIndex >= root.displayRows.length)
            return;
        var row = root.displayRows[root.selectedIndex];
        if (!row)
            return;
        root.close();
        if (row.kind === "app") {
            root.launchApp(row.appId, row.appName);
        } else if (row.kind === "launcher") {
            Util.execDetached(row.action);
        } else {
            // File results always open in Omarchy's configured editor. The
            // launcher supplies a terminal for terminal editors such as nvim.
            root.openFile(row.path);
        }
    }

    function cycleMode(direction) {
        var modes = ["all", "apps", "files", "launchers"];
        var idx = modes.indexOf(root.mode);
        root.mode = modes[(idx + (direction === -1 ? -1 : 1) + modes.length) % modes.length];
        root.selectedIndex = 0;
        root.rebuildDisplay();
    }

    function escapeLabel(text) {
        return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
            .replace(/>/g, "&gt;").replace(/\"/g, "&quot;").replace(/\n/g, "↵");
    }

    // One Text per label; ranges from Rust use QML's UTF-16 offsets.
    function highlightedLabel(text, ranges) {
        var label = String(text || "");
        var output = "";
        var offset = 0;
        for (var i = 0; ranges && i < ranges.length; i++) {
            var start = Math.max(offset, ranges[i].start);
            var end = Math.min(label.length, ranges[i].end);
            output += root.escapeLabel(label.slice(offset, start));
            output += '<font color="' + root.matchHighlight + '"><b>'
                + root.escapeLabel(label.slice(start, end)) + '</b></font>';
            offset = end;
        }
        return output + root.escapeLabel(label.slice(offset));
    }

    function itemString(item, key) {
        if (!item || item[key] === undefined || item[key] === null)
            return "";
        return String(item[key]);
    }

    function appendCollector(proc, data) {
        if (proc.collected.length >= root.maxCollectorBytes)
            return;
        var chunk = String(data || "") + "\n";
        var remaining = root.maxCollectorBytes - proc.collected.length;
        if (chunk.length > remaining)
            chunk = chunk.slice(0, remaining);
        proc.collected += chunk;
    }

    // ------------------------------------------------------------------ files
    Process {
        id: desktopProc
        property string collected: ""
        property int revision: 0
        property int pendingRevision: 0
        stdout: SplitParser {
            onRead: function (data) {
                root.appendCollector(desktopProc, data);
            }
        }
        onExited: function (exitCode, exitStatus) {
            if (desktopProc.revision === root.loadRevision) {
                root.desktopPaths = root.parseDesktopPaths(desktopProc.collected);
                root.loadApps(desktopProc.revision);
            }
            if (desktopProc.pendingRevision) {
                var rev = desktopProc.pendingRevision;
                desktopProc.pendingRevision = 0;
                root.loadDesktopPaths(rev);
            }
        }
    }

    Process {
        id: searchProc
        stdinEnabled: true
        stdout: SplitParser {
            onRead: function (data) { root.receiveSearch(data); }
        }
        stderr: SplitParser {
            onRead: function (data) { console.warn("OmniScope search: " + data); }
        }
        onExited: function (exitCode, exitStatus) {
            var restarting = root.searchStopping && root.opened;
            root.searchStopping = false;
            searchStopFallback.stop();
            root.searchReady = false;
            root.searchBusy = false;
            root.pagePending = false;
            root.searchError = root.opened && !restarting
                ? "Search helper stopped. Reopen OmniScope to retry." : "";
            // A fast close/reopen may occur before the old process exits.
            if (restarting)
                Qt.callLater(root.ensureSearchWorker);
        }
    }

    Timer {
        id: searchStartupTimer
        interval: 5000
        onTriggered: {
            if (!root.searchReady) {
                root.searchBusy = false;
                root.searchError = !root.searchWorkerPath
                    ? "Search helper path could not be resolved."
                    : ("Search helper failed to start: " + root.searchWorkerPath);
            }
        }
    }

    Timer {
        id: searchStopFallback
        interval: 1500
        onTriggered: {
            if (!root.searchStopping)
                return;
            root.searchStopping = false;
            if (root.opened)
                root.ensureSearchWorker();
        }
    }

    Timer {
        interval: 60000
        running: root.opened && root.searchReady
        repeat: true
        onTriggered: root.sendSearch({type: "refresh"})
    }

    Timer {
        id: previewTimer
        interval: 75
        onTriggered: {
            if (!previewProc.running && root.pendingPreview && root.opened && !root.searchBusy) {
                var request = root.pendingPreview;
                root.pendingPreview = null;
                root.startFilePreview(request);
            }
        }
    }

    Process {
        id: launcherGuardProc
        property string collected: ""
        property bool pending: false
        stdout: SplitParser {
            onRead: function (data) {
                root.appendCollector(launcherGuardProc, data);
            }
        }
        onExited: function (exitCode, exitStatus) {
            if (exitCode === 0 && exitStatus === 0) {
                root.launcherWhenResults = Launchers.parseGuardResults(launcherGuardProc.collected);
                root.rebuildLaunchers();
            }
            if (launcherGuardProc.pending)
                Qt.callLater(function () {
                    root.evaluateLauncherGuards();
                });
        }
    }

    Process {
        id: previewProc
        property string rowId: ""
        property string path: ""
        property int revision: 0
        stdout: StdioCollector {
            id: previewOutput
            waitForEnd: true
        }
        onExited: function (exitCode, exitStatus) {
            var activeRow = null;
            if (previewProc.rowId === root.previewRequestedId && previewProc.revision === root.previewRevision) {
                for (var i = 0; i < root.displayRows.length; i++) {
                    if (root.displayRows[i].id === previewProc.rowId) {
                        activeRow = root.displayRows[i];
                        break;
                    }
                }
                var data;
                try {
                    data = JSON.parse(String(previewOutput.text || ""));
                } catch (error) {
                    data = {
                        state: "error",
                        mime: fileExt(previewProc.path),
                        size: "",
                        message: "Preview helper returned malformed output."
                    };
                }
                if (exitCode !== 0 || exitStatus !== 0)
                    data = {
                        state: "error",
                        mime: data.mime || fileExt(previewProc.path),
                        size: data.size || "",
                        message: data.message || "Preview helper failed."
                    };
                var nextCache = ({});
                for (var key in root.previewCache)
                    nextCache[key] = root.previewCache[key];
                nextCache[previewProc.path] = data;
                root.previewCache = nextCache;
                root.applyFilePreview(activeRow, previewProc.revision, data);
            }

            if (root.pendingPreview)
                previewTimer.restart();
        }
    }

    FileView {
        id: defaultMenuFile
        path: root.defaultMenuPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.defaultMenuItems = Launchers.parseMenuJsonc(text());
            root.defaultMenuReady = true;
            root.rebuildLauncherSources();
        }
        onLoadFailed: function (error) {
            console.warn("OmniScope: failed to load Omarchy menu: " + error);
            root.defaultMenuItems = [];
            root.defaultMenuReady = true;
            root.rebuildLauncherSources();
        }
        onFileChanged: reload()
    }

    FileView {
        id: userMenuFile
        path: root.userMenuPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.userMenuItems = Launchers.parseMenuJsonc(text());
            root.userMenuReady = true;
            root.rebuildLauncherSources();
        }
        onLoadFailed: {
            root.userMenuItems = [];
            root.userMenuReady = true;
            root.rebuildLauncherSources();
        }
        onFileChanged: reload()
    }

    Connections {
        target: root.appLibrary
        function onAppsChanged() {
            root.loadApps(root.loadRevision);
        }
    }

    Connections {
        target: DesktopEntries.applications
        enabled: !root.appLibrary
        function onValuesChanged() {
            root.loadApps(root.loadRevision);
        }
    }

    // ------------------------------------------------------------------ window
    PanelWindow {
        id: panel
        visible: root.opened
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        color: "transparent"
        WlrLayershell.namespace: "io.github.mbvlabs.omniscope"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        exclusionMode: ExclusionMode.Ignore

        Rectangle {
            anchors.fill: parent
            color: root.scrim
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }

        Item {
            id: card
            width: root.cardWidth
            height: root.cardHeight
            anchors.centerIn: parent

            MouseArea {
                anchors.fill: parent
                onClicked: {}
            }

            Item {
                id: keyCatcher
                anchors.fill: parent
                focus: true

                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Escape) {
                        if (root.filterText)
                            root.setFilter("");
                        else
                            root.close();
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.activateSelected();
                        event.accepted = true;
        } else if (event.modifiers === Qt.ControlModifier && event.key === Qt.Key_J) {
            root.scrollPreview(root.resultRowHeight * 2);
            event.accepted = true;
        } else if (event.modifiers === Qt.ControlModifier && event.key === Qt.Key_K) {
            root.scrollPreview(-root.resultRowHeight * 2);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
                        root.select(-1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Down) {
                        root.select(1);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageUp) {
                        root.select(-6);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_PageDown) {
                        root.select(6);
                        event.accepted = true;
                    } else if (event.key === Qt.Key_Tab) {
                        root.cycleMode(event.modifiers === Qt.ShiftModifier ? -1 : 1);
                        event.accepted = true;
                    } else if (Util.editsFilter(event, root.filterText)) {
                        root.setFilter(Util.editedFilter(event, root.filterText));
                        event.accepted = true;
                    } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127 && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)) {
                        root.setFilter(root.filterText + event.text);
                        event.accepted = true;
                    }
                }
            }

                Row {
                    anchors.fill: parent
                    spacing: root.paneGap

                // Telescope-style left stack: a bordered results frame and a
                // physically separate prompt below it.
                Column {
                    width: root.resultsWidth
                    height: parent.height
                    spacing: root.paneGap

                    BorderSurface {
                        id: resultsFrame
                        width: parent.width
                        height: root.resultsHeight
                        radius: root.frameRadius
                        color: root.background
                        borderSpec: root.borderSpec

                        Item {
                            id: resultsPane
                            anchors.fill: parent
                            anchors.topMargin: root.titleHeight
                            anchors.rightMargin: root.framePadding
                            anchors.bottomMargin: root.framePadding
                            anchors.leftMargin: root.framePadding
                            clip: true

                            ListView {
                                id: resultList
                                anchors.fill: parent
                                clip: true
                                spacing: root.rowSpacing
                                boundsBehavior: Flickable.StopAtBounds
                                interactive: false
                                verticalLayoutDirection: ListView.BottomToTop
                                model: resultModel
                                visible: root.searchError === ""
                                opacity: root.searchBusy ? 0.5 : 1
                                onContentYChanged: {
                                    if (contentY + height >= contentHeight - root.resultRowHeight * 10)
                                        root.loadMore();
                                }
                                delegate: BorderSurface {
                                    id: row
                                    required property int index

                                    property var item: (index >= 0 && index < root.displayRows.length) ? root.displayRows[index] : null
                                    readonly property bool hasCursor: root.cursorActive && row.index === root.selectedIndex
                                    width: resultList.width
                                    height: root.resultRowHeight
                                    radius: root.frameRadius
                                    color: "transparent"
                                    borderSpec: Border.none()

                                    Row {
                                        anchors.fill: parent
                                        anchors.leftMargin: root.tw2
                                        anchors.rightMargin: root.tw2
                                        spacing: root.tw2

                                        Text {
                                            width: root.textXl
                                            text: root.itemIcon(row.item)
                                            color: row.hasCursor ? root.selectedText : root.foreground
                                            opacity: row.hasCursor ? 1 : 0.5
                                            font.family: root.fontFamily
                                            font.pixelSize: root.textSm
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignHCenter
                                        }

                                        Row {
                                            width: parent.width - parent.spacing - root.textXl
                                            height: parent.height
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: root.tw2
                                            clip: true

                                            Text {
                                                id: labelText
                                                width: Math.min(implicitWidth, Math.round(parent.width * 0.44))
                                                anchors.verticalCenter: parent.verticalCenter
                                                text: root.highlightedLabel(root.itemString(row.item, "label"), row.item ? row.item.labelRanges : [])
                                                textFormat: Text.StyledText
                                                color: row.hasCursor ? root.selectedText : root.foreground
                                                font.family: root.fontFamily
                                                font.pixelSize: root.textSm
                                                elide: Text.ElideRight
                                                maximumLineCount: 1
                                            }

                                            Text {
                                                width: Math.max(0, parent.width - labelText.width - parent.spacing)
                                                text: root.itemString(row.item, "path")
                                                textFormat: Text.PlainText
                                                color: row.hasCursor ? root.selectedText : root.foreground
                                                opacity: row.hasCursor ? 0.65 : 0.42
                                                font.family: root.fontFamily
                                                font.pixelSize: root.textXs
                                                anchors.verticalCenter: parent.verticalCenter
                                                elide: Text.ElideMiddle
                                            }
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: false
                                    }
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: root.tw2
                                visible: root.displayRows.length === 0 || root.searchError !== ""

                                Text {
                                    text: "\uf1c0"
                                    color: root.selectedText
                                    opacity: 0.7
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textXl
                                    horizontalAlignment: Text.AlignHCenter
                                    width: Math.min(resultsPane.width, 160)
                                }

                                Text {
                                    text: root.searchError || (root.searchBusy ? "Searching…" : (!root.filesIndexed
                                        && (root.mode === "all" || root.mode === "files") ? "Indexing files…"
                                        : (root.filterText ? "No matches for “" + root.filterText + "”" : "No results")))
                                    color: root.foreground
                                    opacity: 0.7
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textSm
                                    horizontalAlignment: Text.AlignHCenter
                                    width: resultsPane.width - root.tw4
                                    wrapMode: Text.Wrap
                                }
                            }
                        }

                        Rectangle {
                            z: 10
                            width: resultsTitleRow.implicitWidth + root.tw4
                            height: root.titleHeight
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: -Math.floor(height / 2) + resultsFrame.borderTop
                            radius: 0
                            color: root.background

                            Row {
                                id: resultsTitleRow
                                anchors.centerIn: parent
                                spacing: root.tw2

                                Text {
                                    text: "Results"
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textXs
                                    font.bold: true
                                }

                                Text {
                                    text: root.modeTitle
                                    color: root.matchHighlight
                                    opacity: 0.9
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textXs
                                }

                                Text {
                                    text: root.resultTotal
                                    color: root.foreground
                                    opacity: 0.4
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textXs
                                }
                            }
                        }
                    }

                    BorderSurface {
                        id: searchFrame
                        width: parent.width
                        height: root.searchHeight
                        radius: root.frameRadius
                        color: root.background
                        borderSpec: root.borderSpec

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: root.tw3
                            anchors.rightMargin: root.tw3
                            spacing: root.tw2

                            Text {
                                text: ">"
                                color: root.matchHighlight
                                font.family: root.fontFamily
                                font.pixelSize: root.textSm
                                font.bold: true
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                width: parent.width - 48
                                text: root.filterText || "type to search"
                                color: root.foreground
                                opacity: root.filterText ? 0.95 : 0.32
                                font.family: root.fontFamily
                                font.pixelSize: root.textSm
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                            }

                            Text {
                                text: "󰩫"
                                color: root.foreground
                                opacity: root.filterText ? 0.25 : 0.45
                                font.family: root.fontFamily
                                font.pixelSize: root.textSm
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Rectangle {
                            z: 10
                            width: searchTitleText.implicitWidth + root.tw4
                            height: root.titleHeight
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: -Math.floor(height / 2) + searchFrame.borderTop
                            radius: 0
                            color: root.background

                            Text {
                                id: searchTitleText
                                anchors.centerIn: parent
                                text: "Search"
                                color: root.foreground
                                opacity: 0.82
                                font.family: root.fontFamily
                                font.pixelSize: root.textXs
                                font.bold: true
                            }
                        }
                    }
                }

                // The preview is its own full-height frame, aligned with both left
                // frames rather than enclosed by a shared card.
                BorderSurface {
                    id: previewPane
                    width: root.previewWidth
                    height: parent.height
                    radius: root.frameRadius
                    color: root.background
                    borderSpec: root.borderSpec

                    Column {
                        id: previewColumn
                        anchors.fill: parent
                        anchors.topMargin: root.titleHeight + root.framePadding
                        anchors.rightMargin: root.tw4
                        anchors.bottomMargin: root.titleHeight + root.framePadding
                        anchors.leftMargin: root.tw4
                        spacing: root.tw3

                        Text {
                            id: previewIcon
                            text: root.previewIconGlyph
                            color: root.selectedText
                            opacity: 0.8
                            font.family: root.fontFamily
                            font.pixelSize: root.textXl
                        }

                        Text {
                            id: previewLabel
                            width: parent.width
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: root.textBase
                            font.bold: true
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            maximumLineCount: 2
                            textFormat: Text.PlainText
                            text: root.previewName
                        }

                        Text {
                            id: previewPath
                            width: parent.width
                            color: root.foreground
                            opacity: 0.7
                            font.family: root.fontFamily
                            font.pixelSize: root.textSm
                            wrapMode: Text.Wrap
                            elide: Text.ElideMiddle
                            maximumLineCount: 3
                            textFormat: Text.PlainText
                            text: root.previewLocator
                        }

                        Grid {
                            columns: 2
                            columnSpacing: root.tw4
                            rowSpacing: root.tw1

                            Text {
                                text: "Type"
                                color: root.foreground
                                opacity: 0.5
                                font.family: root.fontFamily
                                font.pixelSize: root.textXs
                            }
                            Text {
                                id: previewType
                                text: root.previewMime
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: root.textSm
                            }

                            Text {
                                visible: root.previewSizeText !== ""
                                text: "Size"
                                color: root.foreground
                                opacity: 0.5
                                font.family: root.fontFamily
                                font.pixelSize: root.textXs
                            }
                            Text {
                                id: previewSize
                                visible: root.previewSizeText !== ""
                                text: root.previewSizeText
                                textFormat: Text.PlainText
                                color: root.foreground
                                font.family: root.fontFamily
                                font.pixelSize: root.textSm
                            }
                        }

                        Item {
                            id: previewBody
                            width: parent.width
                            height: Math.max(0, parent.height - y)
                            clip: true

                            Image {
                                anchors.fill: parent
                                visible: root.previewState === "image"
                                source: root.previewImageSource
                                asynchronous: true
                                cache: false
                                fillMode: Image.PreserveAspectFit
                                sourceSize.width: previewBody.width
                                sourceSize.height: previewBody.height
                            }

                            Flickable {
                                id: previewScroll
                                anchors.fill: parent
                                visible: root.previewState === "text" || root.previewState === "desktop" || root.previewState === "structured"
                                contentWidth: width
                                contentHeight: previewText.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                flickableDirection: Flickable.VerticalFlick
                                interactive: contentHeight > height

                                ScrollBar.vertical: ScrollBar {
                                    policy: previewScroll.contentHeight > previewScroll.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
                                }

                                Text {
                                    id: previewText
                                    width: Math.max(0, previewScroll.width - root.tw2)
                                    text: root.previewContent
                                    color: root.foreground
                                    opacity: 0.86
                                    font.family: root.previewState === "structured" ? root.fontFamily : "monospace"
                                    font.pixelSize: root.textXs
                                    wrapMode: Text.WrapAnywhere
                                    textFormat: root.previewRich ? Text.RichText : Text.PlainText
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                width: Math.min(parent.width, 360)
                                spacing: root.tw2
                                visible: root.previewState === "loading" || root.previewState === "unsupported" || root.previewState === "error"

                                Text {
                                    width: parent.width
                                    text: root.previewState === "loading" ? "\uf110" : (root.previewState === "error" ? "\uf071" : "\uf05e")
                                    color: root.selectedText
                                    opacity: 0.75
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textXl
                                    horizontalAlignment: Text.AlignHCenter
                                }

                                Text {
                                    width: parent.width
                                    text: root.previewContent
                                    textFormat: Text.PlainText
                                    color: root.foreground
                                    opacity: 0.72
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textSm
                                    wrapMode: Text.Wrap
                                    horizontalAlignment: Text.AlignHCenter
                                }
                            }
                        }
                    }

                    Rectangle {
                        z: 10
                        width: previewTitleText.implicitWidth + root.tw4
                        height: root.titleHeight
                        anchors.horizontalCenter: parent.horizontalCenter
                        y: -Math.floor(height / 2) + previewPane.borderTop
                        radius: 0
                        color: root.background

                        Text {
                            id: previewTitleText
                            anchors.centerIn: parent
                            text: "Preview"
                            color: root.foreground
                            opacity: 0.82
                            font.family: root.fontFamily
                            font.pixelSize: root.textXs
                            font.bold: true
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: root.framePadding
                        anchors.bottomMargin: root.framePadding
                        text: (root.displayRows.length ? (root.selectedIndex + 1) : 0) + "," + root.resultTotal + "  " + root.modeTitle.toUpperCase()
                        color: root.foreground
                        opacity: 0.62
                        font.family: root.fontFamily
                        font.pixelSize: root.textXs
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: root.framePadding
                        anchors.bottomMargin: root.framePadding
                        width: parent.width - root.framePadding * 2 - 112
            text: "Tab scope  ·  ↑↓ select  ·  Ctrl+j/k preview  ·  Enter open  ·  Esc close"
                        color: root.foreground
                        opacity: 0.55
                        font.family: root.fontFamily
                        font.pixelSize: root.textXs
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
