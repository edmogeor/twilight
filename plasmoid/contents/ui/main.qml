/*
 * Light/Dark Mode Toggle Plasmoid for gloam
 * SPDX-License-Identifier: GPL-3.0
 */
import QtQuick
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property bool isDarkMode: {
        var bg = Kirigami.Theme.backgroundColor
        return (bg.r * 0.299 + bg.g * 0.587 + bg.b * 0.114) < 0.5
    }
    property bool isRunning: false

    // Unlock as soon as the theme actually changes — no need to wait for
    // gloam's subsidiary operations (Kvantum, GTK, Konsole …) to finish.
    onIsDarkModeChanged: isRunning = false

    Plasmoid.icon: isDarkMode ? "weather-clear-night" : "weather-clear"
    toolTipMainText: isDarkMode ? "Dark Mode" : "Light Mode"
    toolTipSubText: "Click to toggle"

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Light Mode"
            icon.name: "weather-clear"
            onTriggered: root.runCommand("gloam light")
        },
        PlasmaCore.Action {
            text: "Dark Mode"
            icon.name: "weather-clear-night"
            onTriggered: root.runCommand("gloam dark")
        },
        PlasmaCore.Action {
            text: "Toggle"
            icon.name: "system-switch-user"
            onTriggered: root.runCommand("gloam toggle")
        },
        PlasmaCore.Action {
            isSeparator: true
        }
    ]

    Plasmoid.onActivated: runCommand("gloam toggle")

    Plasma5Support.DataSource {
        id: commandRunner
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            root.isRunning = false
            disconnectSource(sourceName)
        }
    }

    // Safety timer to reset isRunning if command fails/hangs or the theme
    // doesn't actually change (e.g. already in the requested mode).
    Timer {
        interval: 3000
        running: root.isRunning
        repeat: false
        onTriggered: root.isRunning = false
    }

    function runCommand(cmd) {
        if (isRunning) return
        isRunning = true
        commandRunner.connectSource(cmd)
    }

    preferredRepresentation: fullRepresentation
    fullRepresentation: MouseArea {
        id: mouseArea

        enabled: !root.isRunning
        hoverEnabled: true
        onClicked: root.runCommand("gloam toggle")

        Kirigami.Icon {
            source: Plasmoid.icon
            anchors.fill: parent
            active: mouseArea.containsMouse && !root.isRunning
            visible: !root.isRunning
        }

        QQC2.BusyIndicator {
            anchors.fill: parent
            running: root.isRunning
            visible: root.isRunning
        }

        PlasmaCore.ToolTipArea {
            anchors.fill: parent
            mainText: root.toolTipMainText
            subText: root.toolTipSubText
        }
    }
}
