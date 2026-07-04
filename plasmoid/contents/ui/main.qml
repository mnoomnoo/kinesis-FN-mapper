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

    // Paths to the bundled daemon and its setup script, both under
    // <pkg>/contents/daemon/. Derived at startup from this package's own install
    // location (see Component.onCompleted) so it works from any clone/store
    // location on any machine — no hardcoded path. daemonPath is handed to the
    // setup script, which installs a root-owned copy + a systemd system service.
    property string daemonPath: ""
    property string setupScript: ""
    property string homePath: ""
    property string userName: ""
    property string configPath: ""

    property bool running: false
    // whether the kinesis-fn.service systemd unit is installed (autostart set up)
    property bool serviceInstalled: false
    // whether python3-evdev is importable — the daemon can't run without it, and
    // a missing dep would make the service fail its Restart=on-failure loop
    // silently, so we guard the "Enable autostart" action on it.
    property bool evdevOk: true
    // in-memory key edits not yet written to disk. Once saved, the daemon's
    // file-watch reloads the config live, so there's no separate "needs restart"
    // state to track.
    property bool unsaved: false
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
                catch (e) { root.notify("Config parse error — showing defaults") }
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
        // pre-select Mute so the editor opens populated (all controls visible)
        // at startup instead of showing an empty reserved slot
        root.selectedEntry = byCode["KEY_MUTE"] || (flat.length ? flat[0] : null)
        root.rev++
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
            // On success the file now matches the in-memory model, so `unsaved`
            // clears. The daemon watches the config file and reloads itself
            // within ~1s, so there's nothing more for the user to do — no restart.
            if (code === 0) { root.unsaved = false; root.notify("Saved — applies within a second") }
            else { root.notify("Save failed: " + err.trim()) }
        })
    }

    // Rebuild every key from the factory defaults and persist; the daemon's
    // file-watch picks the new config up within ~1s, no restart needed.
    function resetDefaults() {
        root.buildRows(KeyData.DEFAULTS)   // every key back to pass-through
        root.writeConfig()
        root.notify("Reset to defaults — applied")
    }

    // Throw away in-memory edits by reloading the saved file (the file *is* the
    // last-saved state). buildRows() re-selects Mute, so restore the open key
    // afterwards.
    function discardChanges() {
        var selCode  = root.selectedEntry ? root.selectedEntry.code : ""
        executable.run("cat " + sh(configPath) + " 2>/dev/null", function (out) {
            var cfg = null, txt = out.trim()
            if (txt.length) { try { cfg = JSON.parse(txt) } catch (e) {} }
            root.buildRows(cfg)
            root.unsaved = false
            if (selCode && root.rowByCode[selCode])
                root.selectedEntry = root.rowByCode[selCode]
            root.notify("Reverted to last saved")
        })
    }

    // --- daemon control (via the systemd system service) --------------------
    // Two facts per poll: is the unit installed (autostart set up?) and is it
    // active (running?). Querying needs no privilege — only start/stop/setup do.
    function refreshStatus() {
        var cmd = "test -f /etc/systemd/system/kinesis-fn.service && echo yes || echo no; " +
                  "systemctl is-active --quiet kinesis-fn.service && echo up || echo down"
        executable.run(cmd, function (out) {
            var lines = out.trim().split(/\s+/)
            root.serviceInstalled = (lines[0] === "yes")
            root.running = (lines[1] === "up")
        })
    }

    // pkexec exits 126 when the auth dialog is dismissed and 127 when the user
    // is not authorised — treat both as "the action never ran".
    function authCancelled(code) { return code === 126 || code === 127 }

    // One-time setup: install the root-owned daemon + enable the boot service.
    // Guarded on evdev so we never leave a service that just crash-loops.
    function enableAutostart() {
        if (!root.evdevOk) { root.notify("Install python3-evdev first, then enable autostart"); return }
        root.notify("Enabling autostart (authorise in the prompt)…")
        var cmd = "pkexec " + sh(root.setupScript) + " enable " +
                  sh(root.userName) + " " + sh(root.homePath) + " " + sh(root.daemonPath)
        executable.run(cmd, function (out, err, code) {
            if (authCancelled(code)) { root.flash("Setup cancelled") }
            else if (code !== 0) { root.notify("Setup failed: " + err.trim()) }
            else { root.flash("Autostart enabled") }
            statusDelay.restart()
        })
    }

    function disableAutostart() {
        root.notify("Disabling autostart (authorise in the prompt)…")
        executable.run("pkexec " + sh(root.setupScript) + " disable", function (out, err, code) {
            if (authCancelled(code)) { root.flash("Disable cancelled") }
            else if (code !== 0) { root.notify("Disable failed: " + err.trim()) }
            else { root.flash("Autostart disabled") }
            statusDelay.restart()
        })
    }

    function startDaemon() {
        root.notify("Starting (authorise in the prompt)…")
        executable.run("pkexec systemctl start kinesis-fn.service", function (out, err, code) {
            if (authCancelled(code)) { root.flash("Start cancelled") }
            else { root.flash("Started") }
            statusDelay.restart()
        })
    }

    function stopDaemon() {
        root.notify("Stopping…")
        executable.run("pkexec systemctl stop kinesis-fn.service", function (out, err, code) {
            root.flash(authCancelled(code) ? "Stop cancelled" : "Stopped")
            statusDelay.restart()
        })
    }

    function restartDaemon() {
        root.notify("Restarting (authorise in the prompt)…")
        executable.run("pkexec systemctl restart kinesis-fn.service", function (out, err, code) {
            if (authCancelled(code)) { root.flash("Restart cancelled") }
            else { root.flash("Restarted") }
            statusDelay.restart()
        })
    }

    Timer { id: statusDelay; interval: 800; onTriggered: root.refreshStatus() }
    Timer { interval: 2000; running: true; repeat: true; onTriggered: root.refreshStatus() }

    // Message helpers. flash() shows a transient confirmation that clears itself
    // (the pill already conveys the running state, so "Started"/"Restarted" don't
    // need to linger). notify() shows a sticky message and cancels any pending
    // auto-clear, for instructions and errors that should stay until superseded.
    Timer { id: msgClear; interval: 3000; onTriggered: root.message = "" }
    function flash(m)  { root.message = m; msgClear.restart() }
    function notify(m) { msgClear.stop(); root.message = m }

    Component.onCompleted: {
        // Derive the daemon + setup-script paths from this package's own location:
        // main.qml lives at <pkg>/contents/ui/, and both bundled files sit under
        // <pkg>/contents/daemon/. realpath resolves the dev-install symlink back to
        // the real repo (and, for a store copy install, canonicalises the path).
        var uiDir = Qt.resolvedUrl(".").toString()
                       .replace(/^file:\/\//, "").replace(/\/$/, "")
        root.daemonPath  = uiDir + "/../daemon/fn_remap.py"
        root.setupScript = uiDir + "/../daemon/kinesis-fn-setup.sh"
        executable.run("realpath -e " + sh(root.daemonPath), function (out, err, code) {
            if (code === 0 && out.trim().length) root.daemonPath = out.trim()
            else root.notify("Could not locate the bundled daemon (fn_remap.py)")
        })
        executable.run("realpath -e " + sh(root.setupScript), function (out, err, code) {
            if (code === 0 && out.trim().length) root.setupScript = out.trim()
        })

        // The daemon needs python3-evdev; warn (and block Enable autostart) if it's
        // missing rather than installing a service that just crash-loops at boot.
        executable.run("python3 -c 'import evdev' >/dev/null 2>&1 && echo ok || echo no",
            function (out) {
                root.evdevOk = (out.trim() === "ok")
                if (!root.evdevOk && !root.serviceInstalled)
                    root.notify("python3-evdev is not installed — install it, then enable autostart")
            })

        // Identity for the setup script (--user) and config path. printf leaves no
        // trailing newline on $HOME, so id's newline cleanly separates the two.
        executable.run("id -un; printf %s \"$HOME\"", function (out) {
            var parts = out.split("\n")
            root.userName = (parts[0] || "").trim()
            root.homePath = (parts[1] || "").trim()
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
    fullRepresentation: Item {
        Layout.minimumWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredWidth: Kirigami.Units.gridUnit * 26
        // size the popup to the content column. The editor's slot is reserved
        // in the column at all times (see the KeyEditor below), so this height
        // is constant — the popup no longer grows/collapses as keys are
        // selected. No maximumHeight clamp so the column always gets its full
        // implicit height.
        implicitWidth: col.implicitWidth
        implicitHeight: col.implicitHeight
        Layout.preferredHeight: col.implicitHeight

        // click-off-a-key dismiss: clicks on empty popup space fall through to
        // here (tiles, editor, and chrome buttons consume their own clicks) and
        // close the editor by clearing the selection
        MouseArea {
            anchors.fill: parent
            onClicked: root.selectedEntry = null
        }

        ColumnLayout {
            id: col
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            // header: status pill + daemon controls
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                Rectangle {
                    id: statusPill
                    radius: height / 2
                    implicitHeight: Kirigami.Units.gridUnit * 1.4
                    implicitWidth: statusRow.implicitWidth + Kirigami.Units.largeSpacing
                    color: Qt.rgba(pillColor.r, pillColor.g, pillColor.b, 0.15)
                    // saved edits apply live (the daemon watches its config), so
                    // the pill only ever reports running vs. stopped
                    readonly property color pillColor: root.running ? "#2ecc71"
                                                     : Kirigami.Theme.disabledTextColor

                    HoverHandler { id: pillHover }
                    QQC2.ToolTip.text: root.running ? "FN-remap daemon is running"
                                                    : "FN-remap daemon is stopped"
                    QQC2.ToolTip.visible: pillHover.hovered

                    RowLayout {
                        id: statusRow
                        anchors.centerIn: parent
                        spacing: Kirigami.Units.smallSpacing
                        Rectangle {
                            width: Kirigami.Units.gridUnit * 0.6; height: width; radius: width / 2
                            color: statusPill.pillColor
                        }
                        PlasmaComponents3.Label {
                            text: root.running ? "Running" : "Stopped"
                            color: statusPill.pillColor
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                // Not set up yet: a single one-time "Enable autostart" that installs
                // the root-owned daemon + boot service (one polkit prompt, ever).
                PlasmaComponents3.Button {
                    visible: !root.serviceInstalled
                    icon.name: "run-install"
                    text: "Enable autostart"
                    enabled: root.evdevOk
                    highlighted: true
                    QQC2.ToolTip.text: root.evdevOk
                        ? "Install the daemon as a service that starts at boot (one-time, authorise in the prompt)"
                        : "Install python3-evdev first"
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.enableAutostart()
                }

                // Set up: control the service (start/stop, restart to apply edits),
                // plus remove it. start/stop/restart prompt; the boot case does not.
                PlasmaComponents3.Button {
                    visible: root.serviceInstalled
                    icon.name: root.running ? "media-playback-stop" : "media-playback-start"
                    text: root.running ? "Stop" : "Start"
                    QQC2.ToolTip.text: root.running
                        ? "Stop the FN-remap daemon"
                        : "Start the FN-remap daemon (authorise in the prompt)"
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.running ? root.stopDaemon() : root.startDaemon()
                }
                PlasmaComponents3.Button {
                    visible: root.serviceInstalled
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    icon.name: "view-refresh"
                    text: "Restart daemon"
                    QQC2.ToolTip.text: text
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.restartDaemon()
                }
                PlasmaComponents3.Button {
                    visible: root.serviceInstalled
                    display: PlasmaComponents3.AbstractButton.IconOnly
                    icon.name: "list-remove"
                    text: "Disable autostart"
                    QQC2.ToolTip.text: "Remove the autostart service and its daemon"
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.disableAutostart()
                }
            }

            PlasmaComponents3.Label {
                text: root.message.length > 0 ? root.message : " "
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
                            // keep natural height so the column stays pinned to
                            // the top instead of stretching to fill the row
                            Layout.fillHeight: false
                            entry: root.rowByCode[modelData]
                            rev: root.rev
                            selected: root.selectedEntry === entry
                            onClicked: root.selectedEntry = entry
                        }
                    }
                    // absorb any leftover vertical space at the bottom
                    Item { Layout.fillHeight: true }
                }
            }

            // editor for the selected key. Its slot stays reserved in the
            // column at all times so the popup is a constant height: opacity
            // (unlike visible) keeps the item in the layout, so col.implicitHeight
            // always includes the editor and the popup never grows/shrinks as
            // keys are selected/deselected. `enabled` follows the selection so
            // the hidden editor can't take focus, and its click-catcher stays
            // transparent to the popup's background dismiss handler.
            KeyEditor {
                id: keyEditor
                Layout.fillWidth: true
                // never let the layout squeeze the box below its content, or the
                // note at the bottom renders outside the rounded border
                Layout.minimumHeight: implicitHeight
                Layout.preferredHeight: implicitHeight
                opacity: root.selectedEntry !== null ? 1 : 0
                enabled: root.selectedEntry !== null
                entry: root.selectedEntry
                // edits stay in memory; rev++ repaints tiles live. Nothing is
                // written until the user clicks "Save changes" in the footer.
                onEdited: { root.rev++; root.unsaved = true }
            }

            // footer: save / discard pending edits, and reset to defaults. Edits
            // accumulate in memory and are only written to disk on "Save changes".
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Item { Layout.fillWidth: true }
                PlasmaComponents3.Button {
                    text: "Save changes"; icon.name: "document-save"
                    enabled: root.unsaved
                    highlighted: root.unsaved
                    QQC2.ToolTip.text: "Write your key changes to the config file"
                    QQC2.ToolTip.visible: hovered
                    onClicked: root.writeConfig()
                }
                PlasmaComponents3.Button {
                    text: "Discard changes"; icon.name: "document-revert"
                    enabled: root.unsaved
                    QQC2.ToolTip.text: "Revert unsaved key changes to the last saved config"
                    QQC2.ToolTip.visible: hovered
                    onClicked: discardDialog.open()
                }
                PlasmaComponents3.Button {
                    text: "Reset to defaults"; icon.name: "edit-undo"
                    QQC2.ToolTip.text: "Restore every key to its default mapping"
                    QQC2.ToolTip.visible: hovered
                    onClicked: resetDialog.open()
                }
            }
        }

        // confirm before wiping every custom mapping — the reset is auto-saved
        // to disk immediately, so there is no undo
        Kirigami.PromptDialog {
            id: resetDialog
            title: "Reset to defaults?"
            subtitle: "This clears every custom mapping and cannot be undone."
            standardButtons: Kirigami.Dialog.NoButton
            customFooterActions: [
                Kirigami.Action {
                    text: "Cancel"
                    icon.name: "dialog-cancel"
                    onTriggered: resetDialog.close()
                },
                Kirigami.Action {
                    text: "Reset"
                    icon.name: "edit-undo"
                    onTriggered: { root.resetDefaults(); resetDialog.close() }
                }
            ]
        }

        // confirm before throwing away unsaved edits — a discard reloads the
        // last-saved file and cannot be undone
        Kirigami.PromptDialog {
            id: discardDialog
            title: "Discard unsaved changes?"
            subtitle: "This reverts every key to the last saved config and cannot be undone."
            standardButtons: Kirigami.Dialog.NoButton
            customFooterActions: [
                Kirigami.Action {
                    text: "Cancel"
                    icon.name: "dialog-cancel"
                    onTriggered: discardDialog.close()
                },
                Kirigami.Action {
                    text: "Discard"
                    icon.name: "document-revert"
                    onTriggered: { root.discardChanges(); discardDialog.close() }
                }
            ]
        }
    }
}
