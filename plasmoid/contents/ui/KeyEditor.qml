import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

import "keydata.js" as KeyData

// Editor for a single FN key, bound to the shared plain-JS `entry`. Controls are
// populated imperatively in sync() (called whenever `entry` changes) rather than
// via declarative bindings on the editable values — that both avoids QML's
// two-way-binding-break gotcha and dodges the reactivity bug the old KeyRow had:
// visibility keys off the *local* `type` string (a real notifiable property), so
// switching action type live shows/hides the right controls.
Rectangle {
    id: editor

    property var entry: null
    property string type: "pass"
    signal edited()

    readonly property var typeList: ["pass", "block", "remap", "run"]
    readonly property var typeLabels: ["Pass through", "Block", "Remap", "Run command"]
    readonly property var modKeys: ["ctrl", "alt", "shift", "super"]
    readonly property var targetDisplays: KeyData.TARGETS.map(KeyData.targetDisplay)

    radius: Kirigami.Units.smallSpacing
    color: Kirigami.Theme.alternateBackgroundColor
    border.width: 1
    border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                          Kirigami.Theme.textColor.b, 0.15)
    implicitHeight: layout.implicitHeight + Kirigami.Units.largeSpacing * 2

    onEntryChanged: sync()

    // consume clicks landing on the editor's empty areas so they don't fall
    // through to the popup's background dismiss handler and close the editor
    MouseArea { anchors.fill: parent }

    function sync() {
        if (!entry) return
        editor.type = entry.type
        targetCombo.currentIndex = KeyData.targetIndex(entry.target)
        cmdField.text = entry.cmd
        for (var i = 0; i < modRepeater.count; i++)
            modRepeater.itemAt(i).checked = entry.mods[modKeys[i]]
        // the type buttons are checkable, so their checked state is re-driven
        // here on each key switch rather than via a (click-broken) binding
        for (var j = 0; j < typeRepeater.count; j++)
            typeRepeater.itemAt(j).checked = (entry.type === typeList[j])
    }

    function setType(t) {
        editor.type = t
        if (entry) { entry.type = t; editor.edited() }
    }

    ColumnLayout {
        id: layout
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Heading {
            // a space when empty so the heading always reserves one
            // line — keeps the editor's implicit height constant, which is what
            // main.qml uses to reserve the editor slot at a stable size
            text: entry ? entry.label : " "
            level: 4
            Layout.fillWidth: true
            elide: Text.ElideRight
        }

        // action type — segmented row of exclusive buttons
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                id: typeRepeater
                model: editor.typeLabels
                delegate: PlasmaComponents3.Button {
                    required property var modelData
                    required property int index
                    text: modelData
                    // stateful: stays pressed to show the active action. autoExclusive
                    // keeps exactly one down; sync() re-drives `checked` on key switch
                    // (the click otherwise breaks a declarative binding).
                    checkable: true
                    autoExclusive: true
                    checked: editor.type === editor.typeList[index]
                    Layout.fillWidth: true
                    onClicked: editor.setType(editor.typeList[index])
                }
            }
        }

        // action-type parameters. A StackLayout keeps the editor a constant
        // height — it always sizes to its tallest page (remap) — so selecting
        // keys of different action types never resizes the popup.
        StackLayout {
            Layout.fillWidth: true
            currentIndex: editor.typeList.indexOf(editor.type)

            // 0 · pass
            ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents3.Label {
                    text: "This key passes through unchanged."
                    font: Kirigami.Theme.smallFont
                    opacity: 0.8
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
                Item { Layout.fillHeight: true }
            }

            // 1 · block
            ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                PlasmaComponents3.Label {
                    text: "This key will be swallowed — it sends nothing."
                    font: Kirigami.Theme.smallFont
                    opacity: 0.8
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }
                Item { Layout.fillHeight: true }
            }

            // 2 · remap (tallest page — sets the reserved height)
            ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents3.Label { text: "Send:" }
                    PlasmaComponents3.ComboBox {
                        id: targetCombo
                        model: editor.targetDisplays
                        Layout.fillWidth: true
                        onActivated: {
                            if (!editor.entry) return
                            editor.entry.target = KeyData.TARGETS[currentIndex].code
                            editor.edited()
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents3.Label { text: "With:" }
                    Repeater {
                        id: modRepeater
                        model: KeyData.MOD_META
                        delegate: PlasmaComponents3.Button {
                            required property var modelData
                            required property int index
                            text: modelData.label
                            checkable: true
                            onToggled: {
                                if (!editor.entry) return
                                editor.entry.mods[editor.modKeys[index]] = checked
                                editor.edited()
                            }
                        }
                    }
                    Item { Layout.fillWidth: true }
                }
            }

            // 3 · run
            ColumnLayout {
                spacing: Kirigami.Units.smallSpacing
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PlasmaComponents3.Label { text: "Run:" }
                    PlasmaComponents3.TextField {
                        id: cmdField
                        placeholderText: "shell command, e.g. kcalc"
                        Layout.fillWidth: true
                        onTextEdited: {
                            if (!editor.entry) return
                            editor.entry.cmd = text
                            editor.edited()
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
