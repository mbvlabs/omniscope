import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "ScopeModel.js" as Scope
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
    property bool filesLoaded: false
    property bool launchersLoaded: false
    property int loadRevision: 0
    property var desktopPaths: ({})

    property var apps: []              // raw app rows
    property var files: []             // raw file rows
    property var dynamicFiles: []      // full-home matches for the active query
    property string dynamicFilesQuery: ""
    property var launchers: []          // Omarchy menu action rows
    property var allItems: []          // combined raw items
    property var displayRows: []       // ranked, filtered rows for display

    readonly property string defaultMenuPath: root.omarchyPath + "/default/omarchy/omarchy-menu.jsonc"
    readonly property string userMenuPath: Quickshell.env("HOME") + "/.config/omarchy/extensions/omarchy-menu.jsonc"
    readonly property string previewWorkerPath: root.manifest && root.manifest.__sourceDir
        ? root.manifest.__sourceDir + "/preview-worker.js"
        : ""
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
        root.startLoad();
        root.opened = true;
        Qt.callLater(function () {
            keyCatcher.forceActiveFocus();
        });
    }

    function close() {
        root.opened = false;
        root.filterText = "";
        dynamicFilesTimer.stop();
        dynamicFilesProc.pendingQuery = "";
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
        root.appsLoaded = false;
        root.filesLoaded = false;
        root.launchersLoaded = root.defaultMenuReady && root.userMenuReady;
        root.selectedIndex = 0;
        root.cursorActive = true;
        root.filterText = "";
        root.dynamicFiles = [];
        root.dynamicFilesQuery = "";
        dynamicFilesTimer.stop();
        dynamicFilesProc.pendingQuery = "";
        root.previewCache = ({});
        root.previewRequestedId = "";
        root.pendingPreview = null;

        root.loadDesktopPaths(revision);
        root.loadFiles(revision);
        if (root.launchersLoaded)
            root.rebuildLaunchers();
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

    function loadApps(revision) {
        if (!root.appLibrary) {
            root.appsLoaded = true;
            root.maybeFinished(revision);
            return;
        }
        var rows = root.appLibrary.sortedEntries("");
        var out = [];
        for (var i = 0; i < rows.length; i++) {
            var entry = rows[i].entry;
            if (!entry)
                continue;
            var appId = String(entry.id || "");
            if (!appId)
                continue;
            var name = root.appLibrary.entryName(entry);
            var generic = root.appLibrary.entrySubtext(entry);
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
            raw.searchText = Scope.buildSearchText(raw);
            out.push(raw);
        }
        root.apps = out;
        root.appsLoaded = true;
        root.maybeFinished(revision);
    }

    function loadFiles(revision) {
        if (!filesProc.running) {
            filesProc.revision = revision;
            filesProc.collected = "";
            filesProc.command = ["fd", "--hidden", "--type", "file", "--exclude", ".git", "--exclude", "node_modules", "--exclude", ".cache", "--max-results", "3000", "--absolute-path", "", Quickshell.env("HOME")];
            filesProc.running = true;
        } else {
            filesProc.pendingRevision = revision;
        }
    }

    function parseFiles(raw) {
        var lines = String(raw || "").split("\n");
        var out = [];
        var seen = ({});
        for (var i = 0; i < lines.length; i++) {
            var path = lines[i].trim();
            if (!path)
                continue;
            if (seen[path])
                continue;
            seen[path] = true;
            var name = path.split("/").pop();
            out.push({
                id: "file." + path,
                kind: "file",
                label: name,
                detail: path,
                appId: "",
                appName: "",
                path: path,
                icon: FileIcons.iconForPath(path),
                aliases: [],
                searchText: Scope.buildSearchText({
                    label: name,
                    aliases: [],
                    path: path
                })
            });
        }
        return out;
    }

    function scheduleDynamicFileSearch() {
        var query = root.filterText.trim();
        var fileScope = root.mode === "all" || root.mode === "files";
        if (!root.opened || !fileScope || query.length < 2) {
            dynamicFilesTimer.stop();
            dynamicFilesProc.pendingQuery = "";
            return;
        }
        if (root.dynamicFilesQuery === query)
            return;
        dynamicFilesTimer.restart();
    }

    function startDynamicFileSearch(query) {
        var current = root.filterText.trim();
        if (!root.opened || query !== current || query.length < 2)
            return;
        if (dynamicFilesProc.running) {
            dynamicFilesProc.pendingQuery = query;
            return;
        }

        var terms = query.split(/\s+/).filter(function (term) { return term.length > 0; });
        if (terms.length === 0)
            return;
        var command = [
            "fd", "--hidden", "--type", "file",
            "--exclude", ".git", "--exclude", "node_modules", "--exclude", ".cache",
            "--max-results", "3000", "--absolute-path", "--full-path", "--fixed-strings"
        ];
        for (var i = 1; i < terms.length; i++)
            command.push("--and", terms[i]);
        command.push("--", terms[0], Quickshell.env("HOME"));

        dynamicFilesProc.query = query;
        dynamicFilesProc.collected = "";
        dynamicFilesProc.command = command;
        dynamicFilesProc.running = true;
    }

    function searchableItems(query) {
        if (!root.dynamicFiles.length || root.dynamicFilesQuery !== query)
            return root.allItems;
        var out = root.allItems.slice();
        var seen = ({});
        for (var i = 0; i < out.length; i++)
            seen[out[i].id] = true;
        for (var d = 0; d < root.dynamicFiles.length; d++) {
            var row = root.dynamicFiles[d];
            if (!seen[row.id]) {
                seen[row.id] = true;
                out.push(row);
            }
        }
        return out;
    }

    function rebuildLauncherSources() {
        if (!root.defaultMenuReady || !root.userMenuReady)
            return;
        root.rebuildLaunchers();
        root.evaluateLauncherGuards();
    }

    function rebuildLaunchers() {
        var rows = Launchers.buildLauncherRows(root.defaultMenuItems, root.userMenuItems, root.launcherWhenResults, root.defaultMenuPath);
        for (var i = 0; i < rows.length; i++)
            rows[i].searchText = Scope.buildSearchText(rows[i]);
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
        if (!root.appsLoaded || !root.filesLoaded || !root.launchersLoaded)
            return;
        root.allItems = root.apps.concat(root.files).concat(root.launchers);
        root.rebuildDisplay();
    }

    // ------------------------------------------------------------------ search
    function setFilter(next) {
        root.filterText = next;
        if (root.dynamicFilesQuery !== next.trim()) {
            root.dynamicFiles = [];
            root.dynamicFilesQuery = "";
        }
        root.selectedIndex = 0;
        root.cursorActive = true;
        root.rebuildDisplay();
        root.scheduleDynamicFileSearch();
    }

    function rebuildDisplay() {
        var query = root.filterText.trim();
        var source = root.searchableItems(query);

        var scoped = source;
        if (root.mode === "apps") {
            scoped = [];
            for (var a = 0; a < source.length; a++)
                if (source[a].kind === "app")
                    scoped.push(source[a]);
        } else if (root.mode === "files") {
            scoped = [];
            for (var b = 0; b < source.length; b++)
                if (source[b].kind === "file")
                    scoped.push(source[b]);
        } else if (root.mode === "launchers") {
            scoped = [];
            for (var c = 0; c < source.length; c++)
                if (source[c].kind === "launcher")
                    scoped.push(source[c]);
        }

        root.displayRows = Scope.search(scoped, query);

        for (var n = 0; n < root.displayRows.length; n++) {
            var rr = root.displayRows[n];
            if (!rr.labelRanges)
                rr.labelRanges = [];
            if (!rr.pathRanges)
                rr.pathRanges = [];
        }

        if (root.displayRows.length === 0)
            root.selectedIndex = 0;
        else if (root.selectedIndex >= root.displayRows.length)
            root.selectedIndex = root.displayRows.length - 1;
        else if (root.selectedIndex < 0)
            root.selectedIndex = 0;

        Qt.callLater(function () {
            if (root.selectedIndex >= 0 && root.selectedIndex < root.displayRows.length)
                resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
        });

        root.updatePreview();
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
        var request = {
            id: row.id,
            path: row.path,
            row: row,
            revision: revision
        };
        if (previewProc.running) {
            root.pendingPreview = request;
            return;
        }
        root.startFilePreview(request);
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
        if (root.displayRows.length === 0)
            return;
        root.cursorActive = true;
        root.selectedIndex = (root.selectedIndex + delta + root.displayRows.length) % root.displayRows.length;
        resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain);
        root.updatePreview();
    }

    function scrollPreview(pixels) {
        if (previewScroll.contentHeight <= previewScroll.height)
            return;
        var maximum = Math.max(0, previewScroll.contentHeight - previewScroll.height);
        previewScroll.contentY = Math.max(0, Math.min(maximum, previewScroll.contentY + pixels));
    }

    function activateSelected() {
        if (root.selectedIndex < 0 || root.selectedIndex >= root.displayRows.length)
            return;
        var row = root.displayRows[root.selectedIndex];
        if (!row)
            return;
        root.close();
        if (row.kind === "app") {
            if (root.appLibrary)
                root.appLibrary.launch(row.appId, row.appName);
        } else if (row.kind === "launcher") {
            Util.execDetached(row.action);
        } else {
            // File results always open in Omarchy's configured editor. The
            // launcher supplies a terminal for terminal editors such as nvim.
            root.openFile(row.path);
        }
    }

    function cycleMode() {
        var modes = ["all", "apps", "files", "launchers"];
        var idx = modes.indexOf(root.mode);
        root.mode = modes[(idx + 1) % modes.length];
        root.selectedIndex = 0;
        root.rebuildDisplay();
        root.scheduleDynamicFileSearch();
    }

    // Build a per-character model for a label so matched ranges can be accented.
    // Returns a JS array of { ch, hit } objects consumed by Repeater.
    function makeGlyphs(text, ranges) {
        var out = [];
        if (!ranges)
            ranges = [];
        var str = String(text || "");
        for (var i = 0; i < str.length; i++) {
            var hit = false;
            for (var r = 0; r < ranges.length; r++) {
                if (ranges[r] && i >= ranges[r].start && i < ranges[r].end) {
                    hit = true;
                    break;
                }
            }
            out.push({
                ch: str.charAt(i),
                hit: hit
            });
        }
        return out;
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
        id: filesProc
        property string collected: ""
        property int revision: 0
        property int pendingRevision: 0
        stdout: SplitParser {
            onRead: function (data) {
                root.appendCollector(filesProc, data);
            }
        }
        onExited: function (exitCode, exitStatus) {
            if (filesProc.revision === root.loadRevision) {
                root.files = root.parseFiles(filesProc.collected);
                root.filesLoaded = true;
                root.maybeFinished(filesProc.revision);
            }
            if (filesProc.pendingRevision) {
                var rev = filesProc.pendingRevision;
                filesProc.pendingRevision = 0;
                root.loadFiles(rev);
            }
        }
    }

    Timer {
        id: dynamicFilesTimer
        interval: 160
        repeat: false
        onTriggered: root.startDynamicFileSearch(root.filterText.trim())
    }

    Process {
        id: dynamicFilesProc
        property string collected: ""
        property string query: ""
        property string pendingQuery: ""
        stdout: SplitParser {
            onRead: function (data) {
                root.appendCollector(dynamicFilesProc, data);
            }
        }
        onExited: function (exitCode, exitStatus) {
            var current = root.filterText.trim();
            var fileScope = root.mode === "all" || root.mode === "files";
            if (exitCode === 0 && exitStatus === 0 && root.opened && fileScope && dynamicFilesProc.query === current) {
                root.dynamicFiles = root.parseFiles(dynamicFilesProc.collected);
                root.dynamicFilesQuery = dynamicFilesProc.query;
                root.rebuildDisplay();
            }

            var pending = dynamicFilesProc.pendingQuery;
            dynamicFilesProc.pendingQuery = "";
            if (pending && pending !== root.dynamicFilesQuery)
                Qt.callLater(function () {
                    root.startDynamicFileSearch(pending);
                });
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

            var pending = root.pendingPreview;
            root.pendingPreview = null;
            if (pending)
                Qt.callLater(function () {
                    root.startFilePreview(pending);
                });
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
            if (root.opened)
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
                        root.cycleMode();
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
                                model: root.displayRows
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

                                            Row {
                                                id: labelGlyphRow
                                                width: Math.min(implicitWidth, Math.round(parent.width * 0.44))
                                                anchors.verticalCenter: parent.verticalCenter
                                                clip: true

                                                Repeater {
                                                    id: glyphs
                                                    model: root.makeGlyphs(root.itemString(row.item, "label"), row.item && row.item.labelRanges ? row.item.labelRanges : [])

                                                    delegate: Text {
                                                        text: modelData.ch
                                                        textFormat: Text.PlainText
                                                        color: modelData.hit ? root.matchHighlight : (row.hasCursor ? root.selectedText : root.foreground)
                                                        font.family: root.fontFamily
                                                        font.pixelSize: root.textSm
                                                        font.weight: modelData.hit ? Font.Bold : Font.Normal
                                                    }
                                                }
                                            }

                                            Text {
                                                width: Math.max(0, parent.width - labelGlyphRow.width - parent.spacing)
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
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onEntered: {
                                            root.cursorActive = true;
                                            root.selectedIndex = row.index;
                                            root.updatePreview();
                                        }
                                        onClicked: {
                                            root.cursorActive = true;
                                            root.selectedIndex = row.index;
                                            root.activateSelected();
                                        }
                                    }
                                }
                            }

                            Column {
                                anchors.centerIn: parent
                                spacing: root.tw2
                                visible: root.displayRows.length === 0

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
                                    text: root.filterText ? "No matches for “" + root.filterText + "”" : "Loading…"
                                    color: root.foreground
                                    opacity: 0.7
                                    font.family: root.fontFamily
                                    font.pixelSize: root.textSm
                                    horizontalAlignment: Text.AlignHCenter
                                    width: Math.min(resultsPane.width, 240)
                                    elide: Text.ElideRight
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
                                    text: root.displayRows.length
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
                        text: (root.displayRows.length ? (root.selectedIndex + 1) : 0) + "," + root.displayRows.length + "  " + root.modeTitle.toUpperCase()
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
