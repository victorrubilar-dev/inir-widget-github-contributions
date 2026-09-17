// GitHub Contributions widget for iNiR / Quickshell
// Fetches data from https://github-contributions-api.jogruber.de

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import Quickshell
import qs
import qs.services
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.widgets
import qs.modules.background.widgets

AbstractBackgroundWidget {
    id: root

    configEntryName: "custom.github-contributions"
    defaultConfig: ({
        placementStrategy: "free",
        widgetScale: 100, widgetOpacity: 100, colorMode: "auto", dim: 0,
        username: "",
        weeks: 53,
        cellSize: 11,
        cellSpacing: 3,
        colorTheme: "classic",
        showMonthLabels: true,
        showLegend: true,
        showTotal: true,
        refreshMinutes: 60,
        surfaceStyle: "card", padding: 12, spacing: 8,
        x: 300, y: 300
    })

    implicitWidth: contentColumn.implicitWidth + pad * 2
    implicitHeight: contentColumn.implicitHeight + pad * 2
    resizableAxes: ({ uniform: "widgetScale" })
    resizeMinWidth: 200
    resizeMinHeight: 90

    readonly property string cfgSurfaceStyle: _readConfigKey("surfaceStyle") ?? "card"
    readonly property int pad: Math.round(Number(_readConfigKey("padding") ?? 12) * scaleFactor)
    readonly property int itemSpacing: Math.round(Number(_readConfigKey("spacing") ?? 8) * scaleFactor)

    readonly property string cfgUsername: _readConfigKey("username") ?? ""
    readonly property int cfgWeeks: Number(_readConfigKey("weeks") ?? 53)
    readonly property int cellSize: Math.round(Number(_readConfigKey("cellSize") ?? 11) * scaleFactor)
    readonly property int cellSpacing: Math.round(Number(_readConfigKey("cellSpacing") ?? 3) * scaleFactor)
    readonly property string cfgColorTheme: _readConfigKey("colorTheme") ?? "classic"
    readonly property bool cfgShowMonthLabels: _readConfigKey("showMonthLabels") ?? true
    readonly property bool cfgShowLegend: _readConfigKey("showLegend") ?? true
    readonly property bool cfgShowTotal: _readConfigKey("showTotal") ?? true
    readonly property int cfgRefreshMinutes: Number(_readConfigKey("refreshMinutes") ?? 60)

    property var weeksModel: []
    property var monthLabels: []
    property int totalContributions: 0
    property bool loading: false
    property string stateText: ""

    function fetchContributions() {
        if (!root.cfgUsername || root.cfgUsername.trim() === "") {
            root.stateText = "Set your GitHub username"
            root.weeksModel = []
            root.monthLabels = []
            root.totalContributions = 0
            return
        }
        root.loading = true
        root.stateText = ""
        let xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                root.loading = false
                if (xhr.status === 200) {
                    try {
                        let data = JSON.parse(xhr.responseText)
                        if (data.error) {
                            root.stateText = "User not found"
                            root.weeksModel = []
                            root.monthLabels = []
                            return
                        }
                        let total = 0
                        if (data.total) {
                            if (data.total.lastYear !== undefined) {
                                total = data.total.lastYear
                            } else {
                                for (let k in data.total) total += data.total[k]
                            }
                        }
                        root.totalContributions = total
                        root.buildGrid(data.contributions || [])
                    } catch (e) {
                        root.stateText = "Error parsing response"
                    }
                } else {
                    root.stateText = "Network error (" + xhr.status + ")"
                }
            }
        }
        xhr.open("GET", "https://github-contributions-api.jogruber.de/v4/"
                  + encodeURIComponent(root.cfgUsername) + "?y=last")
        xhr.send()
    }

    onCfgUsernameChanged: root.fetchContributions()

    Timer {
        interval: Math.max(5, root.cfgRefreshMinutes) * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchContributions()
    }

    function buildGrid(list) {
        if (!list || list.length === 0) {
            root.weeksModel = []
            root.monthLabels = []
            return
        }
        let days = list.slice().sort(function (a, b) {
            return a.date < b.date ? -1 : (a.date > b.date ? 1 : 0)
        })
        let firstDate = new Date(days[0].date + "T00:00:00")
        let firstDow = firstDate.getDay()
        let padded = []
        for (let i = 0; i < firstDow; i++) padded.push(null)
        for (let i = 0; i < days.length; i++) padded.push(days[i])
        while (padded.length % 7 !== 0) padded.push(null)

        let weeks = []
        for (let i = 0; i < padded.length; i += 7) {
            weeks.push(padded.slice(i, i + 7))
        }
        if (root.cfgWeeks > 0 && weeks.length > root.cfgWeeks) {
            weeks = weeks.slice(weeks.length - root.cfgWeeks)
        }
        root.weeksModel = weeks
        root.computeMonthLabels()
    }

    function firstDayOf(week) {
        for (let i = 0; i < week.length; i++) {
            if (week[i] !== null) return week[i]
        }
        return null
    }

    function computeMonthLabels() {
        let labels = []
        let prevMonth = -1
        for (let i = 0; i < root.weeksModel.length; i++) {
            let day = root.firstDayOf(root.weeksModel[i])
            if (!day) { labels.push(""); continue }
            let month = new Date(day.date + "T00:00:00").getMonth()
            if (month !== prevMonth) {
                labels.push(Qt.locale().monthName(month, Locale.ShortFormat))
                prevMonth = month
            } else {
                labels.push("")
            }
        }
        root.monthLabels = labels
    }

    function levelColor(level) {
        if (level === undefined || level === null) return "transparent"
        if (root.cfgColorTheme === "classic") {
            const palette = ["#161b22", "#0e4429", "#006d32", "#26a641", "#39d353"]
            return palette[level] !== undefined ? palette[level] : palette[0]
        }
        const alphas = [0.10, 0.32, 0.55, 0.78, 1.0]
        return ColorUtils.applyAlpha("#ffffff", alphas[level] !== undefined ? alphas[level] : alphas[0])
    }

    function formatTooltip(day) {
        if (!day) return ""
        let d = new Date(day.date + "T00:00:00")
        let dateStr = d.toLocaleDateString(Qt.locale(), Locale.LongFormat)
        let count = day.count ?? 0
        return (count === 1 ? "1 contribución" : count + " contribuciones") + " el " + dateStr
    }

    editPopoverContent: Component {
        ColumnLayout {
            spacing: 6

            RowLayout {
                spacing: 6
                StyledText {
                    text: "Usuario:"
                    color: root.colText
                }
                QQC2.TextField {
                    id: usernameField
                    Layout.fillWidth: true
                    Layout.preferredWidth: 140
                    text: root.cfgUsername
                    placeholderText: "usuario-de-github"
                    onEditingFinished: Config.setNestedValue(
                        "background.widgets.custom.github-contributions.username", text.trim())
                }
                SelectionGroupButton {
                    leftmost: true; rightmost: true
                    buttonIcon: "refresh"
                    buttonText: ""
                    toggled: false
                    onClicked: root.fetchContributions()
                }
            }

            GridLayout {
                columns: 3
                columnSpacing: 4
                rowSpacing: 4
                Repeater {
                    model: [
                        { label: "Meses", icon: "calendar_month", key: "showMonthLabels", on: root.cfgShowMonthLabels },
                        { label: "Leyenda", icon: "info", key: "showLegend", on: root.cfgShowLegend },
                        { label: "Total", icon: "tag", key: "showTotal", on: root.cfgShowTotal }
                    ]
                    SelectionGroupButton {
                        required property var modelData
                        Layout.fillWidth: true
                        leftmost: true; rightmost: true
                        buttonIcon: modelData.icon
                        buttonText: modelData.label
                        toggled: modelData.on
                        onClicked: Config.setNestedValue(
                            "background.widgets.custom.github-contributions." + modelData.key, !modelData.on)
                    }
                }
            }

            RowLayout {
                spacing: 4
                StyledText { text: "Colores:"; color: root.colText }
                Repeater {
                    model: [
                        { label: "Clásico", value: "classic" },
                        { label: "Tema", value: "theme" }
                    ]
                    SelectionGroupButton {
                        required property var modelData
                        leftmost: true; rightmost: true
                        buttonText: modelData.label
                        toggled: root.cfgColorTheme === modelData.value
                        onClicked: Config.setNestedValue(
                            "background.widgets.custom.github-contributions.colorTheme", modelData.value)
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        radius: root.cornerRadiusOverride >= 0 ? root.cornerRadiusOverride : Appearance.rounding.small
        color: root.cfgSurfaceStyle === "minimal" || root.cfgSurfaceStyle === "outline" ? "transparent"
            : ColorUtils.applyAlpha("#10141c", root.cfgSurfaceStyle === "card" ? Math.max(root.backgroundOpacity, 0.72) : Math.max(root.backgroundOpacity, 0.45))
        border.width: root.cfgSurfaceStyle === "outline" ? Math.max(1, root.borderWidth) : 1
        border.color: ColorUtils.applyAlpha("#ffffff", Math.max(root.borderOpacity, 0.10))
    }

    Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: root.pad
        spacing: root.itemSpacing

        Row {
            visible: root.cfgShowTotal || root.stateText !== ""
            spacing: Math.round(6 * root.scaleFactor)
            MaterialSymbol {
                text: "code"
                iconSize: Math.round(15 * root.scaleFactor)
                color: ColorUtils.applyAlpha("#ffffff", 0.9)
                anchors.verticalCenter: parent.verticalCenter
                visible: root.stateText === ""
            }
            StyledText {
                text: root.stateText !== "" ? root.stateText
                    : (root.loading ? "Cargando…" : (root.cfgShowTotal ? root.totalContributions + " contribuciones · @" + root.cfgUsername : "@" + root.cfgUsername))
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor)
                color: ColorUtils.applyAlpha("#ffffff", 0.92)
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Row {
            visible: root.cfgShowMonthLabels && root.weeksModel.length > 0
            spacing: root.cellSpacing
            Repeater {
                model: root.monthLabels
                Item {
                    required property string modelData
                    width: root.cellSize
                    height: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor)
                    StyledText {
                        text: parent.modelData
                        font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                        color: ColorUtils.applyAlpha("#ffffff", 0.7)
                    }
                }
            }
        }

        Row {
            spacing: root.cellSpacing
            Repeater {
                model: root.weeksModel
                Column {
                    required property var modelData
                    spacing: root.cellSpacing
                    Repeater {
                        model: parent.modelData
                        Rectangle {
                            required property var modelData
                            width: root.cellSize
                            height: root.cellSize
                            radius: Math.max(2, Math.round(root.cellSize * 0.2))
                            color: modelData ? root.levelColor(modelData.level) : "transparent"

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: parent.modelData !== null
                                QQC2.ToolTip.visible: containsMouse && parent.modelData !== null
                                QQC2.ToolTip.text: root.formatTooltip(parent.modelData)
                                QQC2.ToolTip.delay: 300
                            }
                        }
                    }
                }
            }
        }

        Row {
            visible: root.cfgShowLegend && root.weeksModel.length > 0
            spacing: Math.round(4 * root.scaleFactor)
            StyledText {
                text: "Menos"
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                color: ColorUtils.applyAlpha("#ffffff", 0.7)
                anchors.verticalCenter: parent.verticalCenter
            }
            Row {
                spacing: root.cellSpacing
                anchors.verticalCenter: parent.verticalCenter
                Repeater {
                    model: [0, 1, 2, 3, 4]
                    Rectangle {
                        required property int modelData
                        width: root.cellSize
                        height: root.cellSize
                        radius: Math.max(2, Math.round(root.cellSize * 0.2))
                        color: root.levelColor(modelData)
                    }
                }
            }
            StyledText {
                text: "Más"
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                color: ColorUtils.applyAlpha("#ffffff", 0.7)
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}