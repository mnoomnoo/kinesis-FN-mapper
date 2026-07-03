import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

import "keydata.js" as KeyData

PlasmoidItem {
    id: root

    // Path to the config-driven daemon. Derived at startup from this package's
    // own install location (see Component.onCompleted) so the repo works from
    // any clone location on any machine — no hardcoded path.
    property string daemonPath: ""
    property string homePath: ""
    property string configPath: ""

    property bool running: false
    property bool dirty: false
    property string message: ""

    property var groups: ["Numpad overlay", "Media keys"]
    property var rowsByGroup: ({})   // group name -> array of entry objects (shared refs)
    property var allRows: []         // flat list, source of truth for save
    property var rowByCode: ({})     // KEY_* code -> entry object, for tile lookup

    property var selectedEntry: null // the key currently open in the editor
    property int rev: 0              // bumped on every edit so tile badges re-read entry

    // --- shell bridge -------------------------------------------------------
    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        property var cbs: ({})
        property int nonce: 0
        onNewData: (source, data) => {
            var cb = cbs[source]
            disconnectSource(source)
            delete cbs[source]
            if (cb) cb((data["stdout"] || ""), (data["stderr"] || ""), data["exit code"])
        }
        function run(cmd, cb) {
            var tagged = cmd + " # " + (nonce++)   // trailing shell comment => unique source
            cbs[tagged] = cb || function () {}
            connectSource(tagged)
        }
    }

    function sh(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // --- config load/build --------------------------------------------------
    function readConfig() {
        executable.run("cat " + sh(configPath) + " 2>/dev/null", function (out) {
            var cfg = null
            var txt = out.trim()
            if (txt.length) {
                try { cfg = JSON.parse(txt) }
                catch (e) { root.message = "Config parse error — showing defaults" }
            }
            root.buildRows(cfg)
        })
    }

    function buildRows(cfg) {
        var modMap = { KEY_LEFTCTRL: "ctrl", KEY_LEFTALT: "alt",
                       KEY_LEFTSHIFT: "shift", KEY_LEFTMETA: "super" }
        var flat = []
        var byGroup = {}
        var byCode = {}
        for (var g = 0; g < groups.length; g++) byGroup[groups[g]] = []

        for (var i = 0; i < KeyData.FN_KEYS.length; i++) {
            var fk = KeyData.FN_KEYS[i]
            var e = { code: fk.code, label: fk.label, group: fk.group,
                      type: "pass", target: "KEY_PLAYPAUSE",
                      mods: { ctrl: false, alt: false, shift: false, super: false },
                      cmd: "" }
            var c = cfg ? cfg[fk.code] : null
            if (c && c.type) {
                e.type = c.type
                if (c.type === "remap") {
                    var keys = c.keys || []
                    for (var k = 0; k < keys.length; k++) {
                        if (modMap[keys[k]]) e.mods[modMap[keys[k]]] = true
                        else e.target = keys[k]   // last non-modifier wins
                    }
                } else if (c.type === "run") {
                    e.cmd = c.cmd || ""
                }
            }
            flat.push(e)
            byGroup[fk.group].push(e)
            byCode[fk.code] = e
        }
        root.allRows = flat
        root.rowsByGroup = byGroup
        root.rowByCode = byCode
        root.selectedEntry = null
        root.rev++
        root.dirty = false
    }

    // --- config save --------------------------------------------------------
    function writeConfig() {
        var cfg = {}
        for (var i = 0; i < allRows.length; i++) {
            var e = allRows[i]
            if (e.type === "remap") {
                var keys = []
                if (e.mods.ctrl)  keys.push("KEY_LEFTCTRL")
                if (e.mods.alt)   keys.push("KEY_LEFTALT")
                if (e.mods.shift) keys.push("KEY_LEFTSHIFT")
                if (e.mods.super) keys.push("KEY_LEFTMETA")
                keys.push(e.target)
                cfg[e.code] = { type: "remap", keys: keys }
            } else if (e.type === "run") {
                cfg[e.code] = { type: "run", cmd: e.cmd }
            } else {
                cfg[e.code] = { type: e.type }   // pass / block
            }
        }
        var b64 = Qt.btoa(JSON.stringify(cfg, null, 2) + "\n")
        var dir = configPath.substring(0, configPath.lastIndexOf("/"))
        var cmd = "mkdir -p " + sh(dir) + " && printf %s " + sh(b64) +
                  " | base64 -d > " + sh(configPath)
        executable.run(cmd, function (out, err, code) {
            if (code === 0) { root.dirty = false; root.message = "Saved — restart to apply" }
            else { root.message = "Save failed: " + err.trim() }
        })
    }

    // --- daemon control -----------------------------------------------------
    function refreshStatus() {
        executable.run("pgrep -f " + sh("python3.*fn_remap\\.py") + " >/dev/null && echo up || echo down",
                       function (out) { root.running = (out.trim() === "up") })
    }

    function startDaemon() {
        root.message = "Starting (authorise in the prompt)…"
        var inner = "setsid -f python3 " + sh(daemonPath) + " --config " + sh(configPath) + " >/dev/null 2>&1"
        executable.run("pkexec sh -c " + sh(inner), function () { statusDelay.restart() })
    }

    function stopDaemon() {
        root.message = "Stopping…"
        executable.run("pkexec pkill -f " + sh("python3.*fn_remap\\.py"),
                       function () { statusDelay.restart() })
    }

    function restartDaemon() {
        root.message = "Restarting (authorise in the prompt)…"
        var inner = "pkill -f 'python3.*fn_remap\\.py'; sleep 0.3; " +
                    "setsid -f python3 " + sh(daemonPath) + " --config " + sh(configPath) + " >/dev/null 2>&1"
        executable.run("pkexec sh -c " + sh(inner), function () { statusDelay.restart() })
    }

    Timer { id: statusDelay; interval: 800; onTriggered: root.refreshStatus() }
    Timer { interval: 2000; running: true; repeat: true; onTriggered: root.refreshStatus() }

    Component.onCompleted: {
        // Derive daemonPath from this package's own location: main.qml lives at
        // <pkg>/contents/ui/, so fn_remap.py is three dirs up. realpath resolves
        // the install symlink back to the real repo (and fails if it's missing).
        var uiDir = Qt.resolvedUrl(".").toString()
                       .replace(/^file:\/\//, "").replace(/\/$/, "")
        root.daemonPath = uiDir + "/../../../fn_remap.py"   // portable fallback
        executable.run("realpath -e " + sh(root.daemonPath),
            function (out, err, code) {
                var p = out.trim()
                if (code === 0 && p.length) root.daemonPath = p   // clean, verified path
                else root.message = "Could not locate fn_remap.py — using default path"
            })

        executable.run("printf %s \"$HOME\"", function (out) {
            root.homePath = out.trim()
            root.configPath = root.homePath + "/.config/kinesis-fn/fn_map.json"
            root.readConfig()
            root.refreshStatus()
        })
    }

    // Flatten KeyData.NUMPAD_GRID into a list of cells for the GridLayout,
    // honouring column spans (KEY_KP0) and gaps (""). A cell is
    // { code, span }; code "" is an empty spacer.
    function gridCells() {
        var cells = []
        var grid = KeyData.NUMPAD_GRID
        for (var r = 0; r < grid.length; r++) {
            var row = grid[r]
            for (var c = 0; c < row.length; c++) {
                var code = row[c]
                if (code === "") {
                    var prev = c > 0 ? row[c - 1] : ""
                    if (prev !== "" && (KeyData.NUMPAD_SPAN[prev] || 1) > 1)
                        continue   // consumed by the preceding spanning key
                    cells.push({ code: "", span: 1 })
                } else {
                    cells.push({ code: code, span: (KeyData.NUMPAD_SPAN[code] || 1) })
                }
            }
        }
        return cells
    }

    // --- compact (panel) representation -------------------------------------
    compactRepresentation: Kirigami.Icon {
        source: Qt.resolvedUrl("../icons/kinesisfn.svg")
        active: mouse.containsMouse
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: root.expanded = !root.expanded
        }
    }

    // --- full representation ------------------------------------------------
    fullRepresentation: ColumnLayout {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        // Grow the popup to fit all content (no scroll): request exactly the
        // summed height of the children rather than a fixed height.
        Layout.preferredHeight: implicitHeight
        spacing: Kirigami.Units.smallSpacing

        // header: status pill + daemon controls
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Rectangle {
                radius: height / 2
                implicitHeight: Kirigami.Units.gridUnit * 1.4
                implicitWidth: statusRow.implicitWidth + Kirigami.Units.largeSpacing
                color: Qt.rgba(pillColor.r, pillColor.g, pillColor.b, 0.15)
                readonly property color pillColor: root.running ? "#2ecc71"
                                                                : Kirigami.Theme.disabledTextColor
                RowLayout {
                    id: statusRow
                    anchors.centerIn: parent
                    spacing: Kirigami.Units.smallSpacing
                    Rectangle {
                        width: Kirigami.Units.gridUnit * 0.6; height: width; radius: width / 2
                        color: parent.parent.pillColor
                    }
                    PlasmaComponents3.Label {
                        text: root.running ? "Running" : "Stopped"
                        color: parent.parent.pillColor
                    }
                }
            }

            Item { Layout.fillWidth: true }

            PlasmaComponents3.Button {
                icon.name: root.running ? "media-playback-stop" : "media-playback-start"
                text: root.running ? "Stop" : "Start"
                onClicked: root.running ? root.stopDaemon() : root.startDaemon()
            }
            PlasmaComponents3.Button {
                display: PlasmaComponents3.AbstractButton.IconOnly
                icon.name: "view-refresh"
                text: "Restart daemon"
                highlighted: root.dirty
                QQC2.ToolTip.text: text
                QQC2.ToolTip.visible: hovered
                onClicked: root.restartDaemon()
            }
        }

        PlasmaComponents3.Label {
            visible: root.message.length > 0
            text: root.message
            font: Kirigami.Theme.smallFont
            opacity: 0.8
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
        }

        Kirigami.Separator { Layout.fillWidth: true }

        // key map, laid out like the physical KB800 blue FN legends: embedded
        // keypad (digits + operator column) beside the vertical FN key column
        RowLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            spacing: Kirigami.Units.largeSpacing

            // digit / operator keypad
            GridLayout {
                Layout.alignment: Qt.AlignTop
                Layout.fillWidth: true
                columns: 4
                rowSpacing: Kirigami.Units.smallSpacing
                columnSpacing: Kirigami.Units.smallSpacing

                Repeater {
                    model: root.gridCells()
                    delegate: Item {
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.columnSpan: modelData.span
                        // equal base width per column so the grid stays aligned
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 3 * modelData.span
                        // follow the tile's content height so badges aren't clipped
                        Layout.preferredHeight: cellKey.implicitHeight
                        Layout.minimumHeight: cellKey.implicitHeight
                        implicitHeight: cellKey.implicitHeight

                        NumpadKey {
                            id: cellKey
                            anchors.fill: parent
                            visible: parent.modelData.code !== ""
                            entry: root.rowByCode[parent.modelData.code]
                            rev: root.rev
                            selected: entry && root.selectedEntry === entry
                            onClicked: root.selectedEntry = entry
                        }
                    }
                }
            }

            // far-right vertical FN column: media then locks
            ColumnLayout {
                Layout.alignment: Qt.AlignTop
                Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                spacing: Kirigami.Units.smallSpacing
                Repeater {
                    model: KeyData.FN_COLUMN
                    delegate: NumpadKey {
                        required property var modelData
                        entry: root.rowByCode[modelData]
                        rev: root.rev
                        selected: root.selectedEntry === entry
                        onClicked: root.selectedEntry = entry
                    }
                }
            }
        }

        // editor for the selected key
        KeyEditor {
            Layout.fillWidth: true
            // never let the layout squeeze the box below its content, or the
            // note at the bottom renders outside the rounded border
            Layout.minimumHeight: implicitHeight
            visible: root.selectedEntry !== null
            entry: root.selectedEntry
            onEdited: { root.dirty = true; root.rev++ }
        }

        // footer: reload / save
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing
            Item { Layout.fillWidth: true }
            PlasmaComponents3.Button {
                text: "Reload"; icon.name: "document-revert"
                onClicked: { root.message = ""; root.readConfig() }
            }
            PlasmaComponents3.Button {
                text: "Save"; icon.name: "document-save"
                enabled: root.dirty
                highlighted: root.dirty
                onClicked: root.writeConfig()
            }
        }
    }
}
