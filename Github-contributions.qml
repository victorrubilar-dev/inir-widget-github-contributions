// GitHub Contributions widget for iNiR / Quickshell
// Fetches data from https://github-contributions-api.jogruber.de
//
// Mejoras aplicadas:
// - Sistema de usuario con validación, normalización y estado explícito
//   (borrador local en el popover + Apply/Clear, sin spam a la API).
// - Estilo con tokens de Appearance (sin colores hardcodeados) y estados
//   vacíos / carga / error diferenciados.
// - Buenas prácticas: helpers puros, clamp de config, cancelación de
//   peticiones, timeout, respeto a powerActive y rutas de config derivadas
//   de configEntryName.

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

    // ── Config ──────────────────────────────────────────────────────
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

    // ── Constantes (evitan magic numbers) ───────────────────────────
    readonly property string apiBase: "https://github-contributions-api.jogruber.de/v4/"
    readonly property int maxUsernameLength: 39
    readonly property int requestTimeoutMs: 15000
    readonly property int minWeeks: 8
    readonly property int maxWeeks: 53
    readonly property int minRefreshMinutes: 5
    readonly property int maxRefreshMinutes: 720

    // Paleta clásica de GitHub (dato de marca, no token de tema).
    readonly property var classicPalette: ["#161b22", "#0e4429", "#006d32", "#26a641", "#39d353"]

    // ── Config derivada (con clamp y fallbacks null-safe) ───────────
    readonly property string cfgSurfaceStyle: _readConfigKey("surfaceStyle") ?? "card"
    readonly property int pad: Math.round(clampInt(_readConfigKey("padding"), 0, 32, 12) * scaleFactor)
    readonly property int itemSpacing: Math.round(clampInt(_readConfigKey("spacing"), 0, 32, 8) * scaleFactor)

    readonly property string cfgUsernameRaw: (_readConfigKey("username") ?? "").toString()
    // Nombre normalizado: única fuente de verdad para API y UI.
    readonly property string cfgUsername: normalizeUsername(root.cfgUsernameRaw)
    readonly property bool hasUsername: root.cfgUsername.length > 0
    readonly property bool isUsernameValid: usernameError(root.cfgUsernameRaw) === ""

    readonly property int cfgWeeks: clampInt(_readConfigKey("weeks"), root.minWeeks, root.maxWeeks, 53)
    readonly property int cellSize: Math.round(clampInt(_readConfigKey("cellSize"), 6, 18, 11) * scaleFactor)
    readonly property int cellSpacing: Math.round(clampInt(_readConfigKey("cellSpacing"), 1, 8, 3) * scaleFactor)
    readonly property string cfgColorTheme: _readConfigKey("colorTheme") ?? "classic"
    readonly property bool cfgShowMonthLabels: _readConfigKey("showMonthLabels") ?? true
    readonly property bool cfgShowLegend: _readConfigKey("showLegend") ?? true
    readonly property bool cfgShowTotal: _readConfigKey("showTotal") ?? true
    readonly property int cfgRefreshMinutes: clampInt(_readConfigKey("refreshMinutes"), root.minRefreshMinutes, root.maxRefreshMinutes, 60)

    // ── Estado ──────────────────────────────────────────────────────
    property var weeksModel: []
    property var monthLabels: []
    property int totalContributions: 0
    property bool loading: false
    property string stateText: ""
    property string lastUpdatedText: ""
    property var _activeXhr: null

    readonly property bool hasData: root.weeksModel.length > 0 && root.stateText === ""
    readonly property bool showEmptyState: !root.hasUsername && !root.loading
    readonly property bool showErrorState: root.stateText !== "" && !root.loading
    readonly property bool canRefresh: root.hasUsername && root.isUsernameValid && !root.loading

    implicitWidth: contentColumn.implicitWidth + pad * 2
    implicitHeight: contentColumn.implicitHeight + pad * 2
    resizableAxes: ({ uniform: "widgetScale" })
    resizeMinWidth: 220
    resizeMinHeight: 110

    // ── Helpers de config (no hardcodear la ruta) ───────────────────
    function configPath(key) {
        return "background.widgets." + root.configEntryName + "." + key
    }

    function saveConfig(key, value) {
        Config.setNestedValue(root.configPath(key), value)
    }

    function clampInt(v, min, max, fallback) {
        const n = Math.round(Number(v))
        if (!Number.isFinite(n))
            return fallback
        return Math.max(min, Math.min(max, n))
    }

    // ── Sistema de usuario ──────────────────────────────────────────
    // Normaliza: recorta espacios y una @ inicial ("@user" -> "user").
    function normalizeUsername(raw) {
        let s = (raw ?? "").toString().trim()
        if (s.startsWith("@"))
            s = s.slice(1).trim()
        return s.replace(/\s+/g, "")
    }

    // "" = válido. Mensajes en español para mostrar inline.
    function usernameError(raw) {
        const s = normalizeUsername(raw)
        if (s.length === 0)
            return "Escribe tu usuario de GitHub"
        if (s.length > root.maxUsernameLength)
            return "Máximo 39 caracteres"
        if (/[^a-zA-Z0-9-]/.test(s))
            return "Solo letras, números y guiones"
        if (s.startsWith("-") || s.endsWith("-"))
            return "No puede empezar ni terminar con guion"
        if (/--/.test(s))
            return "Evita guiones dobles"
        return ""
    }

    // Llamado por el popover con el borrador. Devuelve true si se guardó.
    function applyUsername(raw) {
        const err = usernameError(raw)
        if (err !== "")
            return false
        const next = normalizeUsername(raw)
        if (next !== root.cfgUsername)
            saveConfig("username", next)
        return true
    }

    function clearUsername() {
        if (root.cfgUsernameRaw !== "")
            saveConfig("username", "")
        root.weeksModel = []
        root.monthLabels = []
        root.totalContributions = 0
        root.stateText = ""
    }

    // ── Red ─────────────────────────────────────────────────────────
    function requestRefresh(manual) {
        // Ahorro de energía: el refresco automático se omite cuando el
        // shell pausa los widgets; el refresco manual siempre se permite.
        if (!manual && !root.powerActive)
            return
        root.fetchContributions()
    }

    function fetchContributions() {
        if (!root.hasUsername) {
            abortRequest()
            root.loading = false
            root.stateText = ""
            root.weeksModel = []
            root.monthLabels = []
            root.totalContributions = 0
            return
        }
        if (!root.isUsernameValid) {
            abortRequest()
            root.loading = false
            root.stateText = usernameError(root.cfgUsernameRaw)
            root.weeksModel = []
            root.monthLabels = []
            return
        }
        abortRequest()
        root.loading = true
        root.stateText = ""

        const xhr = new XMLHttpRequest()
        root._activeXhr = xhr
        fetchTimeout.restart()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            if (root._activeXhr !== xhr)
                return // respuesta de una petición ya cancelada
            root._activeXhr = null
            fetchTimeout.stop()
            root.loading = false
            if (xhr.status === 200) {
                try {
                    const data = JSON.parse(xhr.responseText)
                    if (data.error) {
                        root.stateText = "Usuario no encontrado"
                        root.weeksModel = []
                        root.monthLabels = []
                        return
                    }
                    root.totalContributions = extractTotal(data.total)
                    root.buildGrid(data.contributions || [])
                    root.lastUpdatedText = Qt.formatTime(new Date(), "HH:mm")
                } catch (e) {
                    root.stateText = "Error al leer la respuesta"
                }
            } else if (xhr.status === 0) {
                root.stateText = "Sin conexión o petición cancelada"
            } else if (xhr.status === 404) {
                root.stateText = "Usuario no encontrado"
                root.weeksModel = []
                root.monthLabels = []
            } else if (xhr.status === 403 || xhr.status === 429) {
                root.stateText = "Límite de la API, reintenta más tarde"
            } else {
                root.stateText = "Error de red (" + xhr.status + ")"
            }
        }
        xhr.open("GET", root.apiBase + encodeURIComponent(root.cfgUsername) + "?y=last")
        xhr.send()
    }

    function abortRequest() {
        fetchTimeout.stop()
        if (root._activeXhr) {
            try { root._activeXhr.abort() } catch (e) {}
            root._activeXhr = null
        }
    }

    function extractTotal(total) {
        if (!total)
            return 0
        if (total.lastYear !== undefined)
            return Number(total.lastYear) || 0
        let sum = 0
        for (const k in total) sum += Number(total[k]) || 0
        return sum
    }

    Timer {
        id: fetchTimeout
        interval: root.requestTimeoutMs
        repeat: false
        onTriggered: {
            root.abortRequest()
            root.loading = false
            root.stateText = "Tiempo de espera agotado"
        }
    }

    // Refetch con debounce: evita doble petición en el arranque
    // (Timer triggeredOnStart + cambio inicial de binding) y reentradas.
    Timer {
        id: fetchDebounce
        interval: 300
        repeat: false
        onTriggered: root.requestRefresh(false)
    }

    // Refetch cuando cambia el usuario guardado.
    onCfgUsernameChanged: fetchDebounce.restart()
    Component.onDestruction: root.abortRequest()

    Timer {
        interval: Math.max(root.minRefreshMinutes, root.cfgRefreshMinutes) * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: fetchDebounce.restart()
    }

    // ── Grid ────────────────────────────────────────────────────────
    function buildGrid(list) {
        if (!list || list.length === 0) {
            root.weeksModel = []
            root.monthLabels = []
            return
        }
        const days = list.slice().sort((a, b) => a.date < b.date ? -1 : (a.date > b.date ? 1 : 0))
        const firstDow = new Date(days[0].date + "T00:00:00").getDay()
        const padded = []
        for (let i = 0; i < firstDow; i++) padded.push(null)
        for (let i = 0; i < days.length; i++) padded.push(days[i])
        while (padded.length % 7 !== 0) padded.push(null)

        let weeks = []
        for (let i = 0; i < padded.length; i += 7) weeks.push(padded.slice(i, i + 7))
        if (root.cfgWeeks > 0 && weeks.length > root.cfgWeeks)
            weeks = weeks.slice(weeks.length - root.cfgWeeks)
        root.weeksModel = weeks
        root.computeMonthLabels()
    }

    function firstDayOf(week) {
        for (let i = 0; i < week.length; i++) {
            if (week[i] !== null)
                return week[i]
        }
        return null
    }

    function computeMonthLabels() {
        const labels = []
        let prevMonth = -1
        for (let i = 0; i < root.weeksModel.length; i++) {
            const day = root.firstDayOf(root.weeksModel[i])
            if (!day) {
                labels.push("")
                continue
            }
            const month = new Date(day.date + "T00:00:00").getMonth()
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
        if (level === undefined || level === null)
            return "transparent"
        const idx = Math.max(0, Math.min(4, Number(level) || 0))
        if (root.cfgColorTheme === "classic")
            return root.classicPalette[idx] ?? root.classicPalette[0]
        const alphas = [0.12, 0.32, 0.55, 0.78, 1.0]
        return ColorUtils.applyAlpha(Appearance.colors.colPrimary, alphas[idx] ?? alphas[0])
    }

    function formatTooltip(day) {
        if (!day)
            return ""
        const d = new Date(day.date + "T00:00:00")
        const dateStr = d.toLocaleDateString(Qt.locale(), Locale.LongFormat)
        const count = day.count ?? 0
        return (count === 1 ? "1 contribución" : count + " contribuciones") + " el " + dateStr
    }

    function formatTotal(n) {
        return n.toLocaleString(Qt.locale())
    }

    // ── Popover de edición ──────────────────────────────────────────
    editPopoverContent: Component {
        ColumnLayout {
            id: popoverRoot
            spacing: 8

            // Borrador local: no toca la config hasta pulsar Aplicar.
            property string draft: root.cfgUsername
            property string draftError: root.usernameError(root.cfgUsernameRaw)
            readonly property bool draftDirty: normalizeForCompare(popoverRoot.draft) !== root.cfgUsername
            readonly property bool canApply: popoverRoot.draftError === ""
                && popoverRoot.draftDirty && !root.loading

            function normalizeForCompare(s) {
                return root.normalizeUsername(s)
            }

            function refreshDraftError() {
                popoverRoot.draftError = root.usernameError(popoverRoot.draft)
            }

            Component.onCompleted: {
                popoverRoot.draft = root.cfgUsername
                popoverRoot.refreshDraftError()
            }

            Connections {
                target: root
                function onCfgUsernameChanged() {
                    // Sincroniza si el cambio vino de fuera (p. ej. ajustes).
                    if (popoverRoot.normalizeForCompare(popoverRoot.draft) === root.cfgUsername)
                        return
                    if (usernameField && usernameField.activeFocus)
                        return
                    popoverRoot.draft = root.cfgUsername
                    popoverRoot.refreshDraftError()
                }
            }

            StyledText {
                text: "Cuenta de GitHub"
                font.pixelSize: Appearance.font.pixelSize.small
                font.weight: Font.Medium
                color: Appearance.colors.colOnLayer2
            }

            RowLayout {
                spacing: 6
                Layout.fillWidth: true

                MaterialTextField {
                    id: usernameField
                    Layout.fillWidth: true
                    Layout.preferredWidth: 170
                    text: popoverRoot.draft
                    placeholderText: "usuario-de-github"
                    maximumLength: root.maxUsernameLength + 1 // +1 para la @ opcional
                    inputMethodHints: Qt.ImhLowercaseOnly | Qt.ImhNoPredictiveText
                    onTextChanged: {
                        popoverRoot.draft = text
                        popoverRoot.refreshDraftError()
                    }
                    onAccepted: {
                        // El guardado dispara onCfgUsernameChanged -> fetchDebounce.
                        if (popoverRoot.canApply)
                            root.applyUsername(popoverRoot.draft)
                    }
                    Keys.onEscapePressed: {
                        popoverRoot.draft = root.cfgUsername
                        text = root.cfgUsername
                        popoverRoot.refreshDraftError()
                    }
                }

                RippleButton {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    buttonRadius: Appearance.rounding.small
                    enabled: popoverRoot.canApply
                    opacity: enabled ? 1 : 0.4
                    downAction: () => {
                        // El guardado dispara onCfgUsernameChanged -> fetchDebounce.
                        root.applyUsername(popoverRoot.draft)
                    }
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "check"
                        iconSize: 18
                        color: Appearance.colors.colPrimary
                    }
                    StyledToolTip { text: "Guardar usuario" }
                }

                RippleButton {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    buttonRadius: Appearance.rounding.small
                    enabled: root.hasUsername || popoverRoot.draft.length > 0
                    opacity: enabled ? 1 : 0.4
                    downAction: () => {
                        popoverRoot.draft = ""
                        usernameField.text = ""
                        popoverRoot.refreshDraftError()
                        root.clearUsername()
                    }
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        text: "close"
                        iconSize: 18
                        color: Appearance.colors.colOnLayer2
                    }
                    StyledToolTip { text: "Limpiar usuario" }
                }

                SelectionGroupButton {
                    leftmost: true
                    rightmost: true
                    buttonIcon: "refresh"
                    buttonText: ""
                    toggled: false
                    enabled: root.canRefresh
                    opacity: enabled ? 1 : 0.4
                    onClicked: root.requestRefresh(true)
                }
            }

            StyledText {
                Layout.fillWidth: true
                Layout.maximumWidth: 300
                wrapMode: Text.Wrap
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: popoverRoot.draftError === "" && !popoverRoot.draftDirty
                    ? ColorUtils.applyAlpha(Appearance.colors.colOnLayer2, 0.7)
                    : popoverRoot.draftError !== ""
                        ? Appearance.colors.colError
                        : Appearance.colors.colPrimary
                text: popoverRoot.draftError !== ""
                    ? popoverRoot.draftError
                    : popoverRoot.draftDirty
                        ? "Pulsa ✓ o Enter para guardar @" + root.normalizeUsername(popoverRoot.draft)
                        : root.hasUsername ? "@" + root.cfgUsername + " · guardado" : "Sin usuario guardado"
            }

            GridLayout {
                columns: 3
                columnSpacing: 4
                rowSpacing: 4
                Layout.fillWidth: true
                Repeater {
                    model: [
                        { label: "Meses", icon: "calendar_month", key: "showMonthLabels", on: root.cfgShowMonthLabels },
                        { label: "Leyenda", icon: "info", key: "showLegend", on: root.cfgShowLegend },
                        { label: "Total", icon: "tag", key: "showTotal", on: root.cfgShowTotal }
                    ]
                    SelectionGroupButton {
                        required property var modelData
                        Layout.fillWidth: true
                        leftmost: true
                        rightmost: true
                        buttonIcon: modelData.icon
                        buttonText: modelData.label
                        toggled: modelData.on
                        onClicked: root.saveConfig(modelData.key, !modelData.on)
                    }
                }
            }

            RowLayout {
                spacing: 4
                StyledText {
                    text: "Colores:"
                    color: Appearance.colors.colOnLayer2
                    font.pixelSize: Appearance.font.pixelSize.small
                }
                Repeater {
                    model: [
                        { label: "Clásico", value: "classic" },
                        { label: "Tema", value: "theme" }
                    ]
                    SelectionGroupButton {
                        required property var modelData
                        leftmost: true
                        rightmost: true
                        buttonText: modelData.label
                        toggled: root.cfgColorTheme === modelData.value
                        onClicked: root.saveConfig("colorTheme", modelData.value)
                    }
                }
            }

            RowLayout {
                spacing: 8
                StyledText {
                    text: "Semanas:"
                    color: Appearance.colors.colOnLayer2
                    font.pixelSize: Appearance.font.pixelSize.small
                }
                StyledSpinBox {
                    from: root.minWeeks
                    to: root.maxWeeks
                    stepSize: 1
                    value: root.cfgWeeks
                    onValueModified: root.saveConfig("weeks", value)
                }
                StyledText {
                    text: "Actualizar (min):"
                    color: Appearance.colors.colOnLayer2
                    font.pixelSize: Appearance.font.pixelSize.small
                }
                StyledSpinBox {
                    from: root.minRefreshMinutes
                    to: root.maxRefreshMinutes
                    stepSize: 5
                    value: root.cfgRefreshMinutes
                    onValueModified: root.saveConfig("refreshMinutes", value)
                }
            }
        }
    }

    // ── Fondo (tokens, sin colores fijos) ───────────────────────────
    Rectangle {
        anchors.fill: parent
        radius: root.cfgSurfaceStyle === "pill" ? Appearance.rounding.full
            : root.cornerRadiusOverride >= 0 ? root.cornerRadiusOverride : Appearance.rounding.normal
        color: root.cfgSurfaceStyle === "minimal" || root.cfgSurfaceStyle === "outline" ? "transparent"
            : ColorUtils.applyAlpha(root.colText, root.cfgSurfaceStyle === "card"
                ? Math.max(root.backgroundOpacity, 0.10) : Math.max(root.backgroundOpacity, 0.06))
        border.width: root.cfgSurfaceStyle === "outline" ? Math.max(1, root.borderWidth) : 0
        border.color: ColorUtils.applyAlpha(root.colText, Math.max(root.borderOpacity, 0.16))

        Behavior on color {
            enabled: Appearance.animationsEnabled
            ColorAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Appearance.animation.elementMoveFast.type
            }
        }
    }

    // ── Contenido ───────────────────────────────────────────────────
    Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.margins: root.pad
        spacing: root.itemSpacing
        width: parent.width - root.pad * 2

        // Cabecera: avatar + usuario/total + refrescar
        RowLayout {
            visible: root.hasUsername
            width: parent.width
            spacing: Math.round(8 * root.scaleFactor)

            Rectangle {
                Layout.preferredWidth: Math.round(28 * root.scaleFactor)
                Layout.preferredHeight: Math.round(28 * root.scaleFactor)
                Layout.alignment: Qt.AlignVCenter
                radius: width / 2
                clip: true
                color: ColorUtils.applyAlpha(root.colText, 0.10)
                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "person"
                    iconSize: Math.round(16 * root.scaleFactor)
                    color: ColorUtils.applyAlpha(root.colText, 0.8)
                }
                Image {
                    id: avatarImg
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    smooth: true
                    mipmap: true
                    cache: true
                    asynchronous: true
                    source: root.hasUsername ? "https://github.com/" + root.cfgUsername + ".png?size=56" : ""
                    visible: status === Image.Ready
                    onStatusChanged: if (status === Image.Error) visible = false
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 0
                StyledText {
                    Layout.fillWidth: true
                    text: "@" + root.cfgUsername
                    font.pixelSize: Math.round(Appearance.font.pixelSize.small * root.scaleFactor)
                    font.weight: Font.Medium
                    color: root.colText
                    elide: Text.ElideRight
                }
                StyledText {
                    visible: root.cfgShowTotal
                    text: root.loading ? "Cargando…" : formatTotal(root.totalContributions) + " contribuciones"
                    font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor)
                    font.family: Appearance.font.family.numbers
                    color: ColorUtils.applyAlpha(root.colText, 0.65)
                }
            }

            RippleButton {
                Layout.preferredWidth: 30
                Layout.preferredHeight: 30
                Layout.alignment: Qt.AlignVCenter
                buttonRadius: Appearance.rounding.full
                enabled: root.canRefresh
                opacity: enabled ? 1 : 0.35
                colBackground: "transparent"
                colBackgroundHover: ColorUtils.applyAlpha(root.colText, 0.08)
                colRipple: ColorUtils.applyAlpha(root.colText, 0.12)
                downAction: () => root.requestRefresh(true)
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    text: "refresh"
                    iconSize: Math.round(16 * root.scaleFactor)
                    color: ColorUtils.applyAlpha(root.colText, 0.85)
                }
                StyledToolTip { text: "Actualizar ahora" }
            }
        }

        // Estado vacío: CTA para configurar
        ColumnLayout {
            visible: root.showEmptyState
            width: parent.width
            spacing: Math.round(6 * root.scaleFactor)
            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: "person_add"
                iconSize: Math.round(28 * root.scaleFactor)
                color: ColorUtils.applyAlpha(root.colText, 0.55)
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Configura tu usuario de GitHub"
                font.pixelSize: Math.round(Appearance.font.pixelSize.small * root.scaleFactor)
                font.weight: Font.Medium
                color: root.colText
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "Entra en modo edición del widget para escribir tu usuario."
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor)
                color: ColorUtils.applyAlpha(root.colText, 0.6)
            }
        }

        // Estado de error con reintento
        ColumnLayout {
            visible: root.showErrorState
            width: parent.width
            spacing: Math.round(6 * root.scaleFactor)
            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: "cloud_off"
                iconSize: Math.round(26 * root.scaleFactor)
                color: Appearance.colors.colError
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: root.stateText
                font.pixelSize: Math.round(Appearance.font.pixelSize.small * root.scaleFactor)
                color: root.colText
            }
            RippleButton {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: retryLabel.implicitWidth + 28
                Layout.preferredHeight: 32
                buttonRadius: Appearance.rounding.full
                enabled: root.canRefresh
                opacity: enabled ? 1 : 0.4
                colBackground: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.14)
                colBackgroundHover: ColorUtils.applyAlpha(Appearance.colors.colPrimary, 0.22)
                downAction: () => root.requestRefresh(true)
                contentItem: StyledText {
                    id: retryLabel
                    anchors.centerIn: parent
                    text: "Reintentar"
                    font.pixelSize: Math.round(Appearance.font.pixelSize.small * root.scaleFactor)
                    font.weight: Font.Medium
                    color: Appearance.colors.colPrimary
                }
            }
        }

        // Indicador de carga (solo cuando hay usuario)
        RowLayout {
            visible: root.loading && root.hasUsername
            width: parent.width
            spacing: Math.round(6 * root.scaleFactor)
            opacity: root.loading ? 1 : 0
            Behavior on opacity {
                enabled: Appearance.animationsEnabled
                NumberAnimation { duration: Appearance.animation.elementMoveFast.duration }
            }
            MaterialSymbol {
                text: "progress_activity"
                iconSize: Math.round(14 * root.scaleFactor)
                color: ColorUtils.applyAlpha(root.colText, 0.7)
                RotationAnimation on rotation {
                    running: root.loading && Appearance.animationsEnabled
                    loops: Animation.Infinite
                    duration: 1200
                    from: 0
                    to: 360
                }
            }
            StyledText {
                text: "Cargando contribuciones…"
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor)
                color: ColorUtils.applyAlpha(root.colText, 0.7)
            }
        }

        // Etiquetas de mes
        Row {
            visible: root.cfgShowMonthLabels && root.hasData
            spacing: root.cellSpacing
            Repeater {
                model: root.monthLabels
                Item {
                    required property string modelData
                    width: root.cellSize
                    height: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor)
                    clip: true
                    StyledText {
                        text: parent.modelData
                        font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                        color: ColorUtils.applyAlpha(root.colText, 0.6)
                    }
                }
            }
        }

        // Grid de contribuciones
        Row {
            visible: root.hasData
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
                            radius: Math.max(2, Math.round(root.cellSize * 0.25))
                            color: modelData ? root.levelColor(modelData.level) : "transparent"
                            border.width: cellHover.containsMouse && modelData ? 1 : 0
                            border.color: ColorUtils.applyAlpha(root.colText, 0.5)

                            Behavior on color {
                                enabled: Appearance.animationsEnabled
                                ColorAnimation { duration: Appearance.animation.elementMoveFast.duration }
                            }

                            MouseArea {
                                id: cellHover
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

        // Leyenda + última actualización
        RowLayout {
            visible: root.cfgShowLegend && root.hasData
            width: parent.width
            spacing: Math.round(4 * root.scaleFactor)
            StyledText {
                text: "Menos"
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                color: ColorUtils.applyAlpha(root.colText, 0.6)
                Layout.alignment: Qt.AlignVCenter
            }
            Row {
                spacing: root.cellSpacing
                Layout.alignment: Qt.AlignVCenter
                Repeater {
                    model: [0, 1, 2, 3, 4]
                    Rectangle {
                        required property int modelData
                        width: Math.round(root.cellSize * 0.85)
                        height: Math.round(root.cellSize * 0.85)
                        radius: Math.max(2, Math.round(root.cellSize * 0.25))
                        color: root.levelColor(modelData)
                    }
                }
            }
            StyledText {
                text: "Más"
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                color: ColorUtils.applyAlpha(root.colText, 0.6)
                Layout.alignment: Qt.AlignVCenter
            }
            Item { Layout.fillWidth: true }
            StyledText {
                visible: root.lastUpdatedText !== ""
                text: "· " + root.lastUpdatedText
                font.pixelSize: Math.round(Appearance.font.pixelSize.smaller * root.scaleFactor * 0.85)
                font.family: Appearance.font.family.numbers
                color: ColorUtils.applyAlpha(root.colText, 0.45)
                Layout.alignment: Qt.AlignVCenter
            }
        }
    }
}
