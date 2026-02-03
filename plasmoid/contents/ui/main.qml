/*
 * Day/Night Toggle Plasmoid for plasma-daynight-sync
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
    property string currentLaf: ""
    property string darkLaf: ""

    readonly property bool inPanel: (Plasmoid.location === PlasmaCore.Types.TopEdge
        || Plasmoid.location === PlasmaCore.Types.RightEdge
        || Plasmoid.location === PlasmaCore.Types.BottomEdge
        || Plasmoid.location === PlasmaCore.Types.LeftEdge)

    Plasmoid.icon: isDarkMode ? "weather-clear-night" : "weather-clear"
    toolTipMainText: isDarkMode ? "Dark Mode" : "Light Mode"
    toolTipSubText: "Click to toggle"

    Plasmoid.onActivated: toggleMode()

    Component.onCompleted: {
        checkCurrentMode()
    }

    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: (sourceName, data) => {
            var stdout = data["stdout"].trim()

            if (sourceName.indexOf("LookAndFeelPackage") !== -1) {
                root.currentLaf = stdout
                executable.connectSource("kreadconfig6 --file kdeglobals --group KDE --key DefaultDarkLookAndFeel")
            } else if (sourceName.indexOf("DefaultDarkLookAndFeel") !== -1) {
                root.darkLaf = stdout
                root.isDarkMode = (root.currentLaf === root.darkLaf)
                root.isRunning = false
            } else {
                root.isRunning = false
                checkCurrentMode()
            }
            disconnectSource(sourceName)
        }
    }

    function checkCurrentMode() {
        executable.connectSource("kreadconfig6 --file kdeglobals --group KDE --key LookAndFeelPackage")
    }

    function toggleMode() {
        if (isRunning) return
        isRunning = true
        if (isDarkMode) {
            executable.connectSource("plasma-daynight-sync light")
        } else {
            executable.connectSource("plasma-daynight-sync dark")
        }
    }

    preferredRepresentation: fullRepresentation
    fullRepresentation: MouseArea {
        id: mouseArea

        hoverEnabled: true
        onClicked: root.toggleMode()

        Kirigami.Icon {
            source: Plasmoid.icon
            anchors {
                fill: parent
            }
            active: mouseArea.containsMouse
        }

        PlasmaCore.ToolTipArea {
            anchors.fill: parent
            mainText: root.toolTipMainText
            subText: root.toolTipSubText
        }
    }
}
