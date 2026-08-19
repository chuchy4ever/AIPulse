import SwiftUI
import Charts
import ServiceManagement
import AppKit

func parseISO(_ value: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: value) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: value) { return date }
    let dateOnly = DateFormatter()
    dateOnly.dateFormat = "yyyy-MM-dd"
    dateOnly.locale = Locale(identifier: "en_US_POSIX")
    dateOnly.timeZone = TimeZone.current
    return dateOnly.date(from: value)
}

struct PopoverView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let language = appState.config?.language ?? "cs"
        let metric = appState.config?.barMetric ?? "weekly"
        let metricLabel = metric == "session" ? L.t("donut.session_window", language) : L.t("donut.weekly_limit", language)

        return ZStack {
            if let data = appState.data {
                VStack(spacing: 12) {
                    HeaderView(appState: appState)
                    Divider()

                    if let limits = data.limits,
                       let percent = (metric == "session" ? limits.session?.percent : limits.weekly?.percent) {
                        DonutSectionView(appState: appState, percent: percent,
                            metricLabel: metricLabel,
                            data: data
                        )

                        LimitRowsView(limits: limits, appState: appState)
                        Divider()
                    } else {
                        Text(L.t("limits.no_limits", language))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                    }

                    if let weekData = data.aggregations.currentWeekByDayOfWeek,
                       !weekData.isEmpty {
                        DayOfWeekChartView(data: weekData, appState: appState, limits: data.limits)
                            .padding(.horizontal, 12)
                    }

                    ModelsView(data: data, appState: appState)
                        .padding(.horizontal, 12)

                    FooterView(generatedAt: data.generatedAt, limitsFetchedAt: data.limits?.fetchedAt, language: language)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
                .frame(width: 350)
            } else {
                ErrorView(appState: appState)
            }
        }
    }
}

struct HeaderView: View {
    @ObservedObject var appState: AppState

    func openSettingsWindow() {
        if let existing = SettingsWindowHolder.shared.window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.center()
        let language = appState.config?.language ?? "cs"
        settingsWindow.title = L.t("settings.title", language)
        settingsWindow.isReleasedWhenClosed = false
        let hostingView = NSHostingController(rootView: SettingsView(appState: appState))
        settingsWindow.contentViewController = hostingView
        SettingsWindowHolder.shared.window = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        let language = appState.config?.language ?? "cs"
        return HStack {
            Text(L.t("header.title", language))
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            HStack(spacing: 8) {
                Button(action: { appState.refreshLimitsAsync() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)

                Button(action: { openSettingsWindow() }) {
                    Image(systemName: "gear")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }
}

struct DonutSectionView: View {
    @ObservedObject var appState: AppState
    let percent: Int
    let metricLabel: String
    let data: UsageData?

    var body: some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(metricLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.bottom, 2)

                    DonutChartView(percent: percent, color: appState.barColor, isRefreshing: appState.isRefreshingLimits, startedAt: appState.refreshStartedAt)
                        .onTapGesture {
                            appState.refreshLimitsAsync()
                        }

                }

                if let data = data, let components = data.services.anthropic.components, !components.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L.t("services.header", appState.config?.language ?? "cs"))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.bottom, 2)

                        ForEach(0..<components.count, id: \.self) { idx in
                            componentRowCompact(components[idx], incidents: data.services.anthropic.incidents ?? [])
                        }
                    }
                    .onTapGesture {
                        if let url = URL(string: "https://status.claude.com") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func componentRowCompact(_ component: ServiceComponent, incidents: [ServiceIncident]) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(component.status == "operational" ? Color.green : Color.red)
                .frame(width: 6, height: 6)
            Text(shortComponentName(component.name))
                .font(.system(size: 12))
                .fixedSize(horizontal: true, vertical: false)
                .lineLimit(1)
        }
        .help(tooltipForComponent(component, incidents: incidents))
    }

    private func shortComponentName(_ fullName: String) -> String {
        if fullName.contains("claude.ai") {
            return "claude.ai"
        } else if fullName.contains("Console") {
            return "Console"
        } else if fullName.contains("API") {
            return "API"
        } else if fullName.contains("Code") {
            return "Code"
        } else if fullName.contains("Cowork") {
            return "Cowork"
        } else if fullName.contains("Government") {
            return "Gov"
        }
        return fullName
    }

    private func tooltipForComponent(_ component: ServiceComponent, incidents: [ServiceIncident]) -> String {
        var tooltip = "\(component.name): \(component.status)"
        if let incident = incidents.first(where: { incident in
            component.name.lowercased().contains(incident.name.lowercased()) ||
            incident.name.lowercased().contains(component.name.lowercased())
        }) {
            tooltip += "\n\(incident.name)"
            if !incident.impact.isEmpty {
                tooltip += " (\(incident.impact))"
            }
        }
        return tooltip
    }
}

struct DonutChartView: View {
    let percent: Int
    let color: NSColor
    let isRefreshing: Bool
    let startedAt: Date?

    private var arc: some View {
        Circle()
            .inset(by: 8)
            .trim(from: 0, to: CGFloat(percent) / 100)
            .stroke(Color(color), style: StrokeStyle(lineWidth: 16, lineCap: .round))
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: 8)
                .stroke(Color.gray.opacity(0.18), lineWidth: 16)

            if isRefreshing {
                TimelineView(.animation) { context in
                    let elapsed = context.date.timeIntervalSince(startedAt ?? context.date)
                    let angle = min(elapsed / AppState.spinDuration, 1.0) * 360
                    let pulse = 0.55 + 0.35 * (sin(elapsed * 6.0) + 1) / 2
                    arc
                        .rotationEffect(.degrees(angle - 90))
                        .opacity(pulse)
                }
            } else {
                arc.rotationEffect(.degrees(-90))
            }

            Text("\(percent)%")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .opacity(isRefreshing ? 0.45 : 1)
        }
        .frame(width: 172, height: 172)
    }
}

struct LimitRowsView: View {
    let limits: Limits
    @ObservedObject var appState: AppState

    var body: some View {
        let language = appState.config?.language ?? "cs"
        return VStack(spacing: 8) {
            if let session = limits.session {
                LimitRowView(
                    label: L.t("limits.session", language),
                    sublabel: L.t("limits.session_label", language),
                    percent: session.percent,
                    resetsAt: session.resetsAt,
                    appState: appState
                )
            }

            if let weekly = limits.weekly {
                LimitRowView(
                    label: L.t("limits.weekly", language),
                    sublabel: L.t("limits.weekly_label", language),
                    percent: weekly.percent,
                    resetsAt: weekly.resetsAt,
                    appState: appState,
                    showDayMarkers: true
                )
            }
        }
        .padding(.horizontal, 12)
    }
}

struct LimitRowView: View {
    let label: String
    let sublabel: String
    let percent: Int
    let resetsAt: String?
    @ObservedObject var appState: AppState
    var showDayMarkers: Bool = false

    var body: some View {
        let color = appState.colorForPercent(percent)
        let workDays = max(1, min(7, appState.config?.workDays ?? 5))

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                    Text(sublabel)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(percent)%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(color))
            }

            ZStack(alignment: .leading) {
                ProgressView(value: CGFloat(percent) / 100)
                    .tint(Color(color))

                if showDayMarkers && workDays > 1 {
                    GeometryReader { geo in
                        ForEach(1..<workDays, id: \.self) { day in
                            Rectangle()
                                .fill(Color.primary.opacity(0.35))
                                .frame(width: 1, height: 6)
                                .offset(x: geo.size.width * CGFloat(day) / CGFloat(workDays), y: 1)
                        }
                    }
                    .frame(height: 8)
                }
            }

            Text(resetsAt.map { resetTimeString(from: $0) } ?? "")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }

    private func resetTimeString(from isoString: String) -> String {
        let language = appState.config?.language ?? "cs"

        guard let date = parseISO(isoString) else { return "—" }

        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "H:mm"
            let localeId = language == "en" ? "en_US" : "cs_CZ"
            timeFormatter.locale = Locale(identifier: localeId)
            let time = timeFormatter.string(from: date)
            return L.t("reset.resets_today", language).replacingOccurrences(of: "%@", with: time)
        } else {
            let dateFormatter = DateFormatter()
            let localeId = language == "en" ? "en_US" : "cs_CZ"
            dateFormatter.locale = Locale(identifier: localeId)
            if language == "en" {
                dateFormatter.dateFormat = "MMM d, H:mm"
            } else {
                dateFormatter.dateFormat = "d. M. 'v' H:mm"
            }
            let dateStr = dateFormatter.string(from: date)
            return L.t("reset.resets", language).replacingOccurrences(of: "%@", with: dateStr)
        }
    }
}

struct DayOfWeekChartView: View {
    let data: [DayData]
    @ObservedObject var appState: AppState
    let limits: Limits?

    var czechDays: [String] {
        let language = appState.config?.language ?? "cs"
        return ["day.mon", "day.tue", "day.wed", "day.thu", "day.fri", "day.sat", "day.sun"].map { L.t($0, language) }
    }
    let englishDays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var dayLabels: [String] {
        let language = appState.config?.language ?? "cs"
        return language == "en" ? englishDays : czechDays
    }

    var body: some View {
        let language = appState.config?.language ?? "cs"
        let dayLabels = language == "en" ? englishDays : czechDays
        let workDays = max(1, min(7, appState.config?.workDays ?? 5))
        let guideLinePercent = 100.0 / Double(workDays)

        let weeklyCapacity = calculateWeeklyCapacity()
        let dayPercentages = calculateDayPercentages(weeklyCapacity: weeklyCapacity)
        let rawMaxPercent = dayPercentages.max() ?? 0
        // An all-zero week would divide by zero and hand SwiftUI a NaN frame height.
        let maxPercent = rawMaxPercent > 0 ? rawMaxPercent : 1.0

        return VStack(alignment: .leading, spacing: 8) {
            Text(L.t("day_chart.title", language))
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(0..<7, id: \.self) { index in
                        VStack(spacing: 4) {
                            if let dayData = data.first(where: { englishNameToIndex($0.name) == index }) {
                                let percent = dayPercentages[index]
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.gray.opacity(0.15))

                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.blue.opacity(0.7))
                                        .frame(height: CGFloat(percent) / CGFloat(maxPercent) * 60)

                                    HStack {
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 2) {
                                            let locale = language == "en" ? Locale(identifier: "en_US") : Locale(identifier: "cs_CZ")
                                            Text(String(format: "%.0f M", locale: locale, Double(dayData.tokens) / 1_000_000))
                                                .font(.system(size: 9, design: .monospaced))
                                            Text(String(format: "%.1f %%", locale: locale, percent))
                                                .font(.system(size: 8, design: .monospaced))
                                        }
                                        .padding(4)
                                        .background(Color.black.opacity(0.7))
                                        .foregroundColor(.white)
                                        .cornerRadius(3)
                                        .opacity(0)
                                    }
                                    .frame(height: CGFloat(percent) / CGFloat(maxPercent) * 60)
                                }
                                .frame(maxHeight: 60)
                                .help(String(format: "%@ · %.1f M · %.1f %%", dayLabels[index], Double(dayData.tokens) / 1_000_000, percent))
                            } else {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 4)
                            }

                            Text(dayLabels[index])
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(height: 80)
                .overlay(alignment: .center) {
                    ZStack(alignment: .topLeading) {
                        VStack {
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { _ in
                                    VStack {
                                        if guideLinePercent > 0 && maxPercent > 0 && guideLinePercent <= maxPercent {
                                            let spacerHeight = max(0, min(60, (1 - CGFloat(guideLinePercent) / CGFloat(maxPercent)) * 60))
                                            Spacer()
                                                .frame(height: spacerHeight)

                                            Rectangle()
                                                .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                                .foregroundColor(.gray.opacity(0.5))
                                                .frame(height: 1)

                                            Spacer()
                                        }
                                    }
                                    if maxPercent > 0 {
                                        Divider()
                                            .opacity(0)
                                    }
                                }
                            }
                            .frame(height: 60)
                            Spacer()
                        }
                        .frame(height: 80)

                        .frame(height: 60)
                        .padding(.top, 10)
                    }
                }
            }

            if maxPercent > 0 {
                HStack {
                    let optimumText = String(format: L.t("day_chart.optimum", language), guideLinePercent)
                    Text(optimumText)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func calculateWeeklyCapacity() -> Double {
        guard let limits = limits, let weekly = limits.weekly, weekly.percent > 0 else { return 0 }
        let totalTokens = Double(data.map { $0.tokens }.reduce(0, +))
        return totalTokens / (Double(weekly.percent) / 100.0)
    }

    private func calculateDayPercentages(weeklyCapacity: Double) -> [Double] {
        guard weeklyCapacity > 0 else {
            return Array(repeating: 0.0, count: 7)
        }

        var percentages = Array(repeating: 0.0, count: 7)
        for index in 0..<7 {
            if let dayData = data.first(where: { englishNameToIndex($0.name) == index }) {
                percentages[index] = (Double(dayData.tokens) / weeklyCapacity) * 100.0
            }
        }
        return percentages
    }

    private func englishNameToIndex(_ name: String) -> Int {
        return englishDays.firstIndex(of: name) ?? -1
    }
}

struct ModelsView: View {
    let data: UsageData
    @ObservedObject var appState: AppState

    var body: some View {
        let language = appState.config?.language ?? "cs"
        return VStack(alignment: .leading, spacing: 8) {
            Text(L.t("models.title", language))
                .font(.system(size: 12, weight: .semibold))

            ForEach(Array(data.aggregations.currentWeekByModel.prefix(8)), id: \.model) { model in
                HStack {
                    Text(model.model)
                        .font(.system(size: 11))
                    Spacer()
                    Text(appState.formatTokens(model.tokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct FooterView: View {
    let generatedAt: String
    var limitsFetchedAt: String?
    let language: String

    private var freshestTimestamp: String {
        guard let fetched = limitsFetchedAt,
              let a = parseISO(generatedAt), let b = parseISO(fetched) else { return generatedAt }
        return b > a ? fetched : generatedAt
    }
    @State private var currentTime = Date()
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack {
            let timeStr = timeAgo(from: freshestTimestamp)
            let footerText = L.t("footer.updated", language).replacingOccurrences(of: "%@", with: timeStr)
            Text(footerText)
                .font(.system(size: 9))
                .foregroundColor(shouldHighlightAge(freshestTimestamp) ? .red : .secondary)
            Spacer()
        }
        .onReceive(timer) { newDate in
            currentTime = newDate
        }
        .onDisappear {
            timer.upstream.connect().cancel()
        }
    }

    private func timeAgo(from isoString: String) -> String {
        guard let date = parseISO(isoString) else { return "—" }

        let elapsed = currentTime.timeIntervalSince(date)
        let minutes = Int(elapsed / 60)
        let hours = Int(elapsed / 3600)
        let days = Int(elapsed / 86400)

        if minutes < 1 { return L.t("time_ago.just_now", language) }
        if minutes < 60 { return String(format: L.t("time_ago.minutes", language), minutes) }
        if hours < 24 { return String(format: L.t("time_ago.hours", language), hours) }
        return String(format: L.t("time_ago.days", language), days)
    }

    private func shouldHighlightAge(_ isoString: String) -> Bool {
        guard let date = parseISO(isoString) else { return false }
        return currentTime.timeIntervalSince(date) > 7200
    }
}

struct ErrorView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let language = appState.config?.language ?? "cs"
        return VStack(spacing: 12) {
            Text(L.t("error.data_unavailable", language))
                .font(.system(size: 12, weight: .semibold))
            Text(appState.error ?? L.t("error.unknown", language))
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Button(L.t("error.run_collect", language)) {
                appState.runCollectScript()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    appState.loadData()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(width: 300)
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: String = "login"

    var body: some View {
        let language = appState.config?.language ?? "cs"
        return NavigationSplitView {
            List(selection: $selectedTab) {
                Label(L.t("settings.login", language), systemImage: "person.crop.circle").tag("login")
                Label(L.t("settings.section.general", language), systemImage: "square.fill").tag("general")
                Label(L.t("settings.language", language), systemImage: "globe").tag("language")
                Label(L.t("settings.history", language), systemImage: "chart.bar.fill").tag("history")
                Label(L.t("settings.notifications", language), systemImage: "bell").tag("notifications")
            }
            .listStyle(.sidebar)
        } detail: {
            switch selectedTab {
            case "login":
                LoginSectionView(appState: appState)
            case "general":
                BarSettingsSectionView(appState: appState)
            case "language":
                LanguageSectionView(appState: appState)
            case "history":
                HistorySectionView(appState: appState)
            case "notifications":
                NotificationsSectionView(appState: appState)
            default:
                Text(L.t("settings.general_title", language))
            }
        }
        .navigationTitle(L.t("settings.general_title", language))
        .frame(minWidth: 700, minHeight: 500)
    }
}

struct LoginSectionView: View {
    @ObservedObject var appState: AppState
    @State private var showLogoutConfirm = false
    @State private var logoutError: String?
    @State private var isLoggingIn = false

    func runLoginScript() {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/aipulse/login.py")

        let process = Process()
        process.executableURL = scriptPath
        try? process.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            appState.loadData()
        }
    }

    var body: some View {
        let language = appState.config?.language ?? "cs"
        let activeProvider = appState.config?.activeProvider ?? "claude"
        let currentAuth = activeProvider == "claude"
            ? appState.data?.auth.claude
            : appState.data?.auth.codex

        return VStack(alignment: .leading, spacing: 16) {
            Text(L.t("login.title", language))
                .font(.system(size: 14, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("login.provider_label", language))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    providerTile(label: L.t("login.provider_claude", language), isSelected: activeProvider == "claude") {
                        if var config = appState.config {
                            config.activeProvider = "claude"
                            appState.saveConfig(config)
                        }
                    }

                    providerTile(label: L.t("login.provider_codex", language), isSelected: activeProvider == "codex") {
                        if var config = appState.config {
                            config.activeProvider = "codex"
                            appState.saveConfig(config)
                        }
                    }

                    Spacer()
                }
            }

            Divider()

            if let auth = currentAuth {
                HStack(spacing: 8) {
                    Circle()
                        .fill(auth.loggedIn ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(auth.loggedIn ? L.t("login.logged_in", language) : L.t("login.logged_out", language))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }

                if activeProvider == "claude" {
                    if auth.loggedIn, let email = auth.email {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L.t("login.email_label", language))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(email)
                                .font(.system(size: 11, design: .monospaced))

                            if let subType = auth.subscriptionType {
                                Text(L.t("login.subscription_label", language))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 8)
                                Text(subType)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }

                        Button(L.t("login.logout_button", language), role: .destructive) {
                            showLogoutConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)

                        if let error = logoutError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(4)
                        }
                    } else {
                        Button(L.t("login.login_button", language)) {
                            runLoginScript()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    if auth.loggedIn {
                        VStack(alignment: .leading, spacing: 4) {
                            if let method = auth.method {
                                Text(L.t("login.codex_method", language))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Text(method)
                                    .font(.system(size: 11, design: .monospaced))
                            }

                            if let account = auth.account {
                                Text(L.t("login.codex_account", language))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(.top, auth.method == nil ? 0 : 8)
                                Text(account)
                                    .font(.system(size: 11, design: .monospaced))
                            }
                        }

                        Button(L.t("login.logout_button", language), role: .destructive) {
                            showLogoutConfirm = true
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)

                        if let error = logoutError {
                            Text(error)
                                .font(.system(size: 10))
                                .foregroundColor(.red)
                                .padding(8)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(4)
                        }
                    } else {
                        if isLoggingIn {
                            Text(L.t("login.in_progress", language))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        } else {
                            Button(L.t("login.login_button", language)) {
                                isLoggingIn = true
                                appState.codexLogin { success, error in
                                    isLoggingIn = false
                                    if !success, let error = error {
                                        logoutError = error
                                    } else {
                                        logoutError = nil
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(isLoggingIn)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .alert(L.t("login.logout_confirm_title", language), isPresented: $showLogoutConfirm) {
            Button(L.t("login.logout_button", language), role: .destructive) {
                if activeProvider == "claude" {
                    appState.logout { success, error in
                        if !success, let error = error {
                            logoutError = error
                        } else {
                            logoutError = nil
                        }
                    }
                } else {
                    appState.codexLogout { success, error in
                        if !success, let error = error {
                            logoutError = error
                        } else {
                            logoutError = nil
                        }
                    }
                }
            }
            Button(L.t("login.logout_cancel", language), role: .cancel) { }
        } message: {
            Text(L.t("login.logout_confirm_message", language))
        }
    }

    @ViewBuilder
    private func providerTile(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.blue : Color.clear)
            .border(Color(isSelected ? .blue : .gray), width: 1.5)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

struct HistorySectionView: View {
    @ObservedObject var appState: AppState

    var selectedPeriod: String {
        appState.config?.historyPeriod ?? "week"
    }

    var historyData: [Any] {
        let period = selectedPeriod
        if period == "day", let claude = appState.data?.claude, let daily = claude.dailyData {
            return Array(daily.suffix(30))
        } else if period == "month", let monthly = appState.data?.aggregations.monthlyHistory {
            return monthly
        } else {
            return appState.data?.aggregations.weeklyHistory ?? []
        }
    }

    var body: some View {
        let language = appState.config?.language ?? "cs"
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(L.t("history.title", language))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 4) {
                    ForEach(["day", "week", "month"], id: \.self) { period in
                        let label = period == "day" ? L.t("history.period_days", language) : (period == "week" ? L.t("history.period_weeks", language) : L.t("history.period_months", language))
                        Button(label) {
                            if var config = appState.config {
                                config.historyPeriod = period
                                appState.saveConfig(config)
                            }
                                                    }
                        .font(.system(size: 11, weight: selectedPeriod == period ? .semibold : .regular))
                        .foregroundColor(selectedPeriod == period ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(selectedPeriod == period ? Color.blue : Color.gray.opacity(0.2))
                        .cornerRadius(4)
                    }
                }
            }

            if !historyData.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if selectedPeriod == "day" {
                        renderDayChart()
                    } else if selectedPeriod == "month" {
                        renderMonthChart()
                    } else {
                        renderWeekChart()
                    }

                    Divider()

                    renderTable()
                }
            } else {
                Text(L.t("history.no_data", language))
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
            }

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func renderDayChart() -> some View {
        let language = appState.config?.language ?? "cs"
        if let days = historyData as? [PeriodRow] {
            let sortedDays = Array(days.sorted { (a, b) in
                guard let ap = a.period, let bp = b.period, let aDate = parseISO(ap), let bDate = parseISO(bp) else { return false }
                return aDate < bDate
            }.suffix(30))

            Chart {
                ForEach(sortedDays, id: \.period) { item in
                    BarMark(
                        x: .value(L.t("history.day_header", language), appState.getDayLabel(item.period ?? "")),
                        y: .value(L.t("history.tokens_header", language), item.totalTokens)
                    )
                    .foregroundStyle(Color.blue.opacity(0.7))
                }
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray.opacity(0.2))
                    AxisTick(length: 4)
                    if let intValue = value.as(Int.self) {
                        AxisValueLabel {
                            Text(appState.formatYAxisLabel(intValue))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renderWeekChart() -> some View {
        let language = appState.config?.language ?? "cs"
        if let weeks = historyData as? [WeekData] {
            let sortedWeeks = Array(weeks.reversed().prefix(12))

            Chart {
                ForEach(sortedWeeks, id: \.week) { item in
                    BarMark(
                        x: .value(L.t("history.week_header", language), String(item.week.split(separator: "-").last ?? "")),
                        y: .value(L.t("history.tokens_header", language), item.tokens)
                    )
                    .foregroundStyle(Color.blue.opacity(0.7))
                }
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray.opacity(0.2))
                    AxisTick(length: 4)
                    if let intValue = value.as(Int.self) {
                        AxisValueLabel {
                            Text(appState.formatYAxisLabel(intValue))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renderMonthChart() -> some View {
        let language = appState.config?.language ?? "cs"
        if let months = historyData as? [MonthData] {
            Chart {
                ForEach(months, id: \.month) { item in
                    BarMark(
                        x: .value(L.t("history.month_header", language), appState.formatMonthLabel(item.month)),
                        y: .value(L.t("history.tokens_header", language), item.tokens)
                    )
                    .foregroundStyle(Color.blue.opacity(0.7))
                }
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.gray.opacity(0.2))
                    AxisTick(length: 4)
                    if let intValue = value.as(Int.self) {
                        AxisValueLabel {
                            Text(appState.formatYAxisLabel(intValue))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func renderTable() -> some View {
        let language = appState.config?.language ?? "cs"
        VStack(alignment: .leading, spacing: 8) {
            let period = selectedPeriod
            HStack {
                if period == "day" {
                    Text(L.t("history.day_header", language)).font(.system(size: 11, weight: .semibold))
                } else if period == "month" {
                    Text(L.t("history.month_header", language)).font(.system(size: 11, weight: .semibold))
                } else {
                    Text(L.t("history.week_header", language)).font(.system(size: 11, weight: .semibold))
                }
                Spacer()
                Text(L.t("history.tokens_header", language)).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(L.t("history.price_header", language)).font(.system(size: 11, weight: .semibold))
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.bottom, 4)

            if let days = historyData as? [PeriodRow] {
                let locale = language == "en" ? Locale(identifier: "en_US") : Locale(identifier: "cs_CZ")
                ForEach(Array(days.suffix(30).reversed()), id: \.period) { item in
                    HStack {
                        Text(appState.getDayLabel(item.period ?? ""))
                            .font(.system(size: 10))
                        Spacer()
                        Text(String(format: "%.0f M", locale: locale, Double(item.totalTokens) / 1_000_000))
                            .font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text(appState.formatCostInDollars(item.totalCost))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            } else if let weeks = historyData as? [WeekData] {
                let locale = language == "en" ? Locale(identifier: "en_US") : Locale(identifier: "cs_CZ")
                ForEach(Array(weeks.reversed().prefix(12)), id: \.week) { item in
                    HStack {
                        Text(String(item.week.split(separator: "-").last ?? "")).font(.system(size: 10))
                        Spacer()
                        Text(String(format: "%.0f M", locale: locale, Double(item.tokens) / 1_000_000))
                            .font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text(appState.formatCostInDollars(item.cost))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            } else if let months = historyData as? [MonthData] {
                let locale = language == "en" ? Locale(identifier: "en_US") : Locale(identifier: "cs_CZ")
                ForEach(months, id: \.month) { item in
                    HStack {
                        Text(appState.formatMonthLabel(item.month)).font(.system(size: 10))
                        Spacer()
                        Text(String(format: "%.0f M", locale: locale, Double(item.tokens) / 1_000_000))
                            .font(.system(size: 10, design: .monospaced))
                        Spacer()
                        Text(appState.formatCostInDollars(item.cost))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 70, alignment: .trailing)
                    }
                }
            }
        }
    }
}

struct BarSettingsSectionView: View {
    @ObservedObject var appState: AppState

    let styles = ["percentage", "compact", "progressBar", "batteryClassic", "iconWithBar"]
    var styleLabels: [String] {
        let language = appState.config?.language ?? "cs"
        return ["bar.style.percentage", "bar.style.compact", "bar.style.progressBar", "bar.style.battery", "bar.style.iconWithBar"].map { L.t($0, language) }
    }

    var currentValue: String {
        guard let config = appState.config else { return "—" }
        let metric = config.barMetric
        var displayValue = "42%"

        if metric == "tokens" {
            displayValue = "123M"
        }

        return displayValue
    }

    var currentPercent: Int {
        guard let config = appState.config else { return 0 }
        let metric = config.barMetric

        if metric == "weekly", let limits = appState.data?.limits, let weekly = limits.weekly {
            return weekly.percent
        } else if metric == "session", let limits = appState.data?.limits, let session = limits.session {
            return session.percent
        }
        return 0
    }

    var currentColor: NSColor {
        appState.colorForPercent(currentPercent)
    }

    func previewText(_ style: String) -> String {
        switch style {
        case "compact", "progressBar": return ""
        default: return currentValue
        }
    }

    func previewImage(_ style: String) -> NSImage? {
        switch style {
        case "compact":
            return AppState.makeIndicator(percent: currentPercent, color: currentColor, style: .dot)
        case "progressBar", "iconWithBar":
            return AppState.makeIndicator(percent: currentPercent, color: currentColor, style: .bar)
        case "batteryClassic":
            return AppState.makeIndicator(percent: currentPercent, color: currentColor, style: .battery)
        default:
            return nil
        }
    }

    var body: some View {
        let language = appState.config?.language ?? "cs"
        let styleLabelsLoc = [
            L.t("bar_appearance.style_percentage", language),
            L.t("bar_appearance.style_compact", language),
            L.t("bar_appearance.style_progress", language),
            L.t("bar_appearance.style_battery", language),
            L.t("bar_appearance.style_icon_bar", language)
        ]

        return VStack(alignment: .leading, spacing: 20) {
            // Group 1: Appearance
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("settings.group.appearance", language))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { idx in
                            if idx < styles.count {
                                stylePreviewTile(style: styles[idx], label: styleLabelsLoc[idx])
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        ForEach(3..<styles.count, id: \.self) { idx in
                            stylePreviewTile(style: styles[idx], label: styleLabelsLoc[idx])
                        }
                        Spacer()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L.t("bar_appearance.metric_label", language))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appState.config?.barMetric ?? "weekly" },
                            set: { newValue in
                                if var config = appState.config {
                                    config.barMetric = newValue
                                    appState.saveConfig(config)
                                }
                                                            }
                        )) {
                            Text(L.t("bar_appearance.metric_weekly", language)).tag("weekly")
                            Text(L.t("bar_appearance.metric_session", language)).tag("session")
                            Text(L.t("bar_appearance.metric_tokens", language)).tag("tokens")
                        }
                        .frame(width: 120)
                    }
                }

                // Color Legend
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("bar_appearance.color_legend", language))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        colorLegendRow(color: appState.colorForPercent(25), text: L.t("bar_appearance.color_under_50", language))
                        colorLegendRow(color: appState.colorForPercent(62), text: L.t("bar_appearance.color_50_74", language))
                        colorLegendRow(color: appState.colorForPercent(82), text: L.t("bar_appearance.color_75_89", language))
                        colorLegendRow(color: appState.colorForPercent(95), text: L.t("bar_appearance.color_over_90", language))
                    }
                }
            }

            Divider()

            // Group 2: Behavior
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("settings.group.behavior", language))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(L.t("general.work_days", language))
                        Spacer()
                        HStack(spacing: 8) {
                            Text("\(appState.config?.workDays ?? 5)")
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 30, alignment: .trailing)
                            Stepper("", value: Binding(
                                get: { appState.config?.workDays ?? 5 },
                                set: { newValue in
                                    if var config = appState.config {
                                        config.workDays = min(max(newValue, 1), 7)
                                        appState.saveConfig(config)
                                    }
                                                                    }
                            ), in: 1...7)
                        }
                    }

                    HStack {
                        Text(L.t("general.refresh_interval", language))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appState.config?.refreshMinutes ?? 5 },
                            set: { newValue in
                                if var config = appState.config {
                                    config.refreshMinutes = newValue
                                    appState.saveConfig(config)
                                    appState.updateLaunchInterval(newValue)
                                }
                                }
                        )) {
                            Text(L.t("general.refresh_5min", language)).tag(5)
                            Text(L.t("general.refresh_10min", language)).tag(10)
                            Text(L.t("general.refresh_15min", language)).tag(15)
                            Text(L.t("general.refresh_30min", language)).tag(30)
                            Text(L.t("general.refresh_60min", language)).tag(60)
                        }
                        .frame(width: 110)
                    }

                    HStack {
                        Text(L.t("general.startup", language))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: {
                                SMAppService.mainApp.status == .enabled
                            },
                            set: { newValue in
                                do {
                                    if newValue {
                                        try SMAppService.mainApp.register()
                                    } else {
                                        try SMAppService.mainApp.unregister()
                                    }
                                } catch {
                                    appState.collectError = String(format: L.t("general.error_startup", language), error.localizedDescription)
                                }
                            }
                        ))
                    }
                }
            }

            Divider()

            // Group 3: Actions
            VStack(alignment: .leading, spacing: 12) {
                Text(L.t("settings.group.actions", language))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                Button(action: {
                    appState.runCollectScriptAsync()
                }) {
                    HStack {
                        if appState.isCollecting {
                            ProgressView()
                                .scaleEffect(0.8, anchor: .center)
                        }
                        Text(appState.isCollecting ? L.t("general.updating", language) : L.t("general.update_button", language))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.isCollecting)

                if let error = appState.collectError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(4)
                }
            }

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func stylePreviewTile(style: String, label: String) -> some View {
        let isSelected = appState.config?.barStyle == style
        let borderColor = isSelected ? Color(currentColor) : Color.gray.opacity(0.3)
        let borderWidth = isSelected ? 2.0 : 1.0

        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(borderColor, lineWidth: borderWidth)
                    )

                HStack(spacing: 4) {
                    if let image = previewImage(style) {
                        Image(nsImage: image)
                    }
                    let text = previewText(style)
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(currentColor))
                    }
                }
            }
            .frame(height: 40)

            Text(label)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .onTapGesture {
            if var config = appState.config {
                config.barStyle = style
                appState.saveConfig(config)
            }
        }
    }

    @ViewBuilder
    private func colorLegendRow(color: NSColor, text: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(color))
                .frame(width: 12, height: 12)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

struct LanguageSectionView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        let language = appState.config?.language ?? "cs"
        let currentLanguage = appState.config?.language ?? "cs"

        return VStack(alignment: .leading, spacing: 16) {
            Text(L.t("language.title", language))
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 12) {
                languageButton(flag: "🇨🇿", label: "Čeština", isSelected: currentLanguage == "cs") {
                    if var config = appState.config {
                        config.language = "cs"
                        appState.saveConfig(config)
                    }
                                    }

                languageButton(flag: "🇬🇧", label: "English", isSelected: currentLanguage == "en") {
                    if var config = appState.config {
                        config.language = "en"
                        appState.saveConfig(config)
                    }
                                    }

                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("language.note", language))
                    .font(.system(size: 11, weight: .semibold))
                Text(L.t("language.note_text", language))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.yellow.opacity(0.1))
            .cornerRadius(4)

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func languageButton(flag: String, label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(flag)
                    .font(.system(size: 28))

                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.blue : Color.clear)
            .border(Color(isSelected ? .blue : .gray), width: 1.5)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }
}

struct NotificationsSectionView: View {
    @ObservedObject var appState: AppState
    @State private var selectedProvider: String = "anthropic"

    var anthropicEnabledCount: Int {
        guard let config = appState.config else { return 0 }
        return config.notifyServices.filter { $0.hasPrefix("anthropic:") }.count
    }

    var openaiEnabledCount: Int {
        guard let config = appState.config else { return 0 }
        return config.notifyServices.filter { $0.hasPrefix("openai:") }.count
    }

    var body: some View {
        let language = appState.config?.language ?? "cs"
        let hasAnthropicComponents = appState.data?.services.anthropic.components?.isEmpty == false
        let hasOpenAIComponents = appState.data?.services.openai.components?.isEmpty == false

        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L.t("notifications.title", language))
                    .font(.system(size: 14, weight: .semibold))
                Text(L.t("notifications.hint", language))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if let data = appState.data, hasAnthropicComponents || hasOpenAIComponents {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("", selection: $selectedProvider) {
                        Text(providerLabel("anthropic", language, anthropicEnabledCount))
                            .tag("anthropic")
                        Text(providerLabel("openai", language, openaiEnabledCount))
                            .tag("openai")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Spacer()
                        Button(action: { selectAllForProvider(selectedProvider, language: language) }) {
                            Text(L.t("notifications.select_all", language))
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.link)

                        Button(action: { clearAllForProvider(selectedProvider, language: language) }) {
                            Text(L.t("notifications.select_none", language))
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.link)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if selectedProvider == "anthropic" {
                                if let components = data.services.anthropic.components, !components.isEmpty {
                                    ForEach(components, id: \.id) { component in
                                        componentToggleRow(component: component, provider: "anthropic", appState: appState, language: language)
                                    }
                                } else {
                                    Text(L.t("notifications.empty", language))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .padding(.vertical, 16)
                                }
                            } else {
                                if let components = data.services.openai.components, !components.isEmpty {
                                    ForEach(components, id: \.id) { component in
                                        componentToggleRow(component: component, provider: "openai", appState: appState, language: language)
                                    }
                                } else {
                                    Text(L.t("notifications.empty", language))
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .padding(.vertical, 16)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(maxHeight: 300)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.t("notifications.empty", language))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding()
        .onAppear {
            if let provider = appState.config?.activeProvider {
                selectedProvider = provider == "codex" ? "openai" : "anthropic"
            }
        }
    }

    private func providerLabel(_ provider: String, _ language: String, _ count: Int) -> String {
        let key = provider == "anthropic" ? "login.provider_claude" : "login.provider_codex"
        let name = L.t(key, language)
        return count > 0 ? "\(name) (\(count))" : name
    }

    private func selectAllForProvider(_ provider: String, language: String) {
        guard var config = appState.config else { return }
        let components = provider == "anthropic"
            ? appState.data?.services.anthropic.components ?? []
            : appState.data?.services.openai.components ?? []

        for component in components {
            let key = "\(provider):\(component.id)"
            if !config.notifyServices.contains(key) {
                config.notifyServices.append(key)
            }
        }
        appState.saveConfig(config)
    }

    private func clearAllForProvider(_ provider: String, language: String) {
        guard var config = appState.config else { return }
        config.notifyServices.removeAll { $0.hasPrefix("\(provider):") }
        appState.saveConfig(config)
    }

    /// A status the status page invents later would otherwise render as the raw
    /// key, which is worse than admitting it is unknown.
    private func localizedStatus(_ status: String, _ language: String) -> String {
        let key = "status.\(status)"
        let text = L.t(key, language)
        return text == key ? L.t("status.unknown", language) : text
    }

    @ViewBuilder
    private func componentToggleRow(component: ServiceComponent, provider: String, appState: AppState, language: String) -> some View {
        let key = "\(provider):\(component.id)"
        let isSelected = appState.config?.notifyServices.contains(key) ?? false
        let statusColor = component.status == "operational" ? Color.green : Color.red

        HStack(spacing: 12) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    if var config = appState.config {
                        if newValue {
                            if !config.notifyServices.contains(key) {
                                config.notifyServices.append(key)
                            }
                        } else {
                            config.notifyServices.removeAll { $0 == key }
                        }
                        appState.saveConfig(config)
                    }
                }
            ))

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(component.name)
                .font(.system(size: 11))

            Spacer()

            if component.status != "operational" {
                Text(localizedStatus(component.status, language))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }
}

final class SettingsWindowHolder {
    static let shared = SettingsWindowHolder()
    var window: NSWindow?
}
