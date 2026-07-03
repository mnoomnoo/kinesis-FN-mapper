import QtQuick
import QtQuick.Layouts
import org.kde.plasma.components as PlasmaComponents3
import org.kde.kirigami as Kirigami

import "keydata.js" as KeyData

// One numpad/media key tile. Reads the shared plain-JS `entry` object; clicking
// selects it for editing. `rev` is a repaint nonce bumped by main.qml after any
// edit so the badge re-reads `entry` (whose sub-property changes QML can't track).
Rectangle {
    id: tile

    property var entry
    property bool selected: false
    property int rev: 0

    signal clicked()

    // is this key doing anything other than a plain pass-through?
    readonly property bool mapped: (tile.rev, entry && entry.type !== "pass")

    radius: Kirigami.Units.smallSpacing
    // grow to fit the badge (mapped keys show a second line) but never below a
    // comfortable single-line tile size
    implicitHeight: Math.max(Kirigami.Units.gridUnit * 2.6,
                             content.implicitHeight + Kirigami.Units.smallSpacing * 2)
    Layout.fillWidth: true
    Layout.fillHeight: true
    // don't let a row squeeze the tile below its content, or the badge clips
    Layout.minimumHeight: implicitHeight

    color: selected ? Kirigami.Theme.highlightColor
                    : mapped ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                       Kirigami.Theme.highlightColor.g,
                                       Kirigami.Theme.highlightColor.b, 0.14)
                    : mouse.containsMouse ? Kirigami.Theme.alternateBackgroundColor
                                          : Kirigami.Theme.backgroundColor
    border.width: 1
    border.color: selected ? Kirigami.Theme.highlightColor
                           : Qt.rgba(Kirigami.Theme.textColor.r,
                                     Kirigami.Theme.textColor.g,
                                     Kirigami.Theme.textColor.b, 0.15)

    ColumnLayout {
        id: content
        anchors.fill: parent
        anchors.margins: Kirigami.Units.smallSpacing
        spacing: 0

        PlasmaComponents3.Label {
            text: entry ? entry.label.replace(/^FN · /, "") : ""
            font.bold: true
            color: tile.selected ? Kirigami.Theme.highlightedTextColor
                                 : Kirigami.Theme.textColor
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
        PlasmaComponents3.Label {
            text: (tile.rev, KeyData.summary(entry))
            visible: text.length > 0
            font: Kirigami.Theme.smallFont
            opacity: 0.85
            color: tile.selected ? Kirigami.Theme.highlightedTextColor
                                 : Kirigami.Theme.textColor
            elide: Text.ElideRight
            Layout.fillWidth: true
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: tile.clicked()
    }
}
