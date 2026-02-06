/*
 * Light/Dark Mode Toggle Plasmoid for gloam
 * SPDX-License-Identifier: GPL-3.0
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property bool isDarkMode: false
    property bool isRunning: false

    readonly property bool inPanel: (Plasmoid.location === PlasmaCore.Types.TopEdge
        || Plasmoid.location === PlasmaCore.Types.RightEdge
        || Plasmoid.location === PlasmaCore.Types.BottomEdge
        || Plasmoid.location === PlasmaCore.Types.LeftEdge)

    Plasmoid.icon: isDarkMode ? "weather-clear-night" : "weather-clear"
    toolTipMainText: isDarkMode ? "Dark Mode" : "Light Mode"
    toolTipSubText: "Click to toggle"

    Plasmoid.contextualActions: [
        Kirigami.Action {
            text: "Light Mode"
            iconName: "weather-clear"
            onTriggered: root.setLightMode()
        },
        Kirigami.Action {
            text: "Dark Mode"
            iconName: "weather-clear-night"
            onTriggered: root.setDarkMode()
        },
        Kirigami.Action {
            text: "Toggle Mode"
            iconName: "system-switch-user"
            onTriggered: root.toggleMode()
        }
    ]

    Plasmoid.onActivated: toggleMode()

    Component.onCompleted: {
        modeReader.checkMode()
        modeWatcher.running = true
    }

    // Read mode from status file (written by gloam script)
    Plasma5Support.DataSource {
        id: modeReader
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            var mode = data["stdout"].trim()
            if (mode === "dark") {
                root.isDarkMode = true
            } else if (mode === "light") {
                root.isDarkMode = false
            }
            root.isRunning = false
            disconnectSource(sourceName)
        }

        function checkMode() {
            connectSource("cat $XDG_RUNTIME_DIR/gloam-runtime 2>/dev/null")
        }
    }

    // Toggle command runner
    Plasma5Support.DataSource {
        id: toggleRunner
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            root.isRunning = false
            disconnectSource(sourceName)
        }
    }

    // Poll status file (reading from tmpfs is very cheap)
    Timer {
        id: modeWatcher
        interval: 1000
        running: false
        repeat: true
        onTriggered: modeReader.checkMode()
    }

    // Safety timer to reset isRunning if command fails/hangs
    Timer {
        interval: 5000
        running: root.isRunning
        repeat: false
        onTriggered: root.isRunning = false
    }

    function setLightMode() {
        if (isRunning) return
        isRunning = true
        toggleRunner.connectSource("gloam light")
    }

    function setDarkMode() {
        if (isRunning) return
        isRunning = true
        toggleRunner.connectSource("gloam dark")
    }

    function toggleMode() {
        if (isDarkMode) {
            setLightMode()
        } else {
            setDarkMode()
        }
    }

    preferredRepresentation: fullRepresentation
    fullRepresentation: MouseArea {
        id: mouseArea

        hoverEnabled: true
        onClicked: root.toggleMode()

        Kirigami.Icon {
            source: Plasmoid.icon
            anchors.fill: parent
            active: mouseArea.containsMouse
        }

        PlasmaCore.ToolTipArea {
            anchors.fill: parent
            mainText: root.toolTipMainText
            subText: root.toolTipSubText
        }
    }
}
