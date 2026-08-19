import Foundation
import SwiftUI

class AppState: ObservableObject {
    static var isSnapshotting = false

    @Published var data: UsageData?
    @Published var config: Config?
    @Published var error: String?
    @Published var barValue: String = "—"
    @Published var barColor: NSColor = .gray
    @Published var barImage: NSImage?
    @Published var isCollecting: Bool = false
    @Published var isRefreshingLimits: Bool = false
    @Published var refreshStartedAt: Date?
    @Published var collectError: String?

    private let dataPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/aipulse/data.json")
    private let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/aipulse/config.json")

    func loadData() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var loadedData: UsageData?
            var loadedConfig: Config?
            var loadError: String?

            var decodeFailure: Error?

            do {
                let raw = try Data(contentsOf: self.dataPath)
                loadedData = try JSONDecoder().decode(UsageData.self, from: raw)
                loadError = nil
            } catch {
                loadedData = nil
                decodeFailure = error
            }

            if let data = try? Data(contentsOf: self.configPath),
               let decoded = try? JSONDecoder().decode(Config.self, from: data) {
                loadedConfig = decoded
            } else {
                loadedConfig = Config(activeProvider: "claude", barMetric: "weekly", workDays: 5, refreshMinutes: 5, barStyle: "percentage", language: "cs", historyPeriod: "week")
            }

            if let failure = decodeFailure {
                let lang = loadedConfig?.language ?? "cs"
                loadError = String(format: L.t("error.data_load_failed", lang), "\(failure)" as NSString)
            }

            DispatchQueue.main.async {
                self.data = loadedData
                self.config = loadedConfig
                self.error = loadError
                self.updateBarDisplay()

                // Not while snapshotting: the watcher writes its state file and can
                // fire a notification, and a screenshot tool must do neither.
                if !AppState.isSnapshotting, let data = loadedData, let config = loadedConfig {
                    let watcher = ServiceWatcher()
                    watcher.checkAndNotify(data: data, config: config)
                }

                NotificationCenter.default.post(name: NSNotification.Name("AppStateDidUpdate"), object: nil)
            }
        }
    }

    func updateBarDisplay() {
        guard let config = config else {
            barValue = "—"
            barColor = .gray
            return
        }

        let metric = config.barMetric
        var displayValue: String = "—"
        var percent: Int = 0

        if metric == "weekly", let limits = data?.limits, let weekly = limits.weekly {
            percent = weekly.percent
            displayValue = "\(percent)%"
        } else if metric == "session", let limits = data?.limits, let session = limits.session {
            percent = session.percent
            displayValue = "\(percent)%"
        } else if metric == "tokens" {
            if config.activeProvider == "claude" {
                let tokens = data?.claude.totals.totalTokens ?? 0
                displayValue = formatTokens(tokens)
            } else if config.activeProvider == "codex" {
                let tokens = data?.codex.totals.totalTokens ?? 0
                displayValue = formatTokens(tokens)
            }
        }

        let barColor = colorForPercent(percent)

        switch config.barStyle {
        case "compact":
            barValue = ""
            barImage = AppState.makeIndicator(percent: percent, color: barColor, style: .dot)
        case "progressBar":
            barValue = ""
            barImage = AppState.makeIndicator(percent: percent, color: barColor, style: .bar)
        case "batteryClassic":
            barValue = displayValue
            barImage = AppState.makeIndicator(percent: percent, color: barColor, style: .battery)
        case "iconWithBar":
            barValue = displayValue
            barImage = AppState.makeIndicator(percent: percent, color: barColor, style: .bar)
        default:
            barValue = displayValue
            barImage = nil
        }

        self.barColor = barColor
    }

    func colorForPercent(_ percent: Int) -> NSColor {
        if percent < 50 {
            return NSColor(red: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
        } else if percent < 75 {
            return NSColor(red: 1.0, green: 0.84, blue: 0.1, alpha: 1.0)
        } else if percent < 90 {
            return NSColor(red: 1.0, green: 0.63, blue: 0.06, alpha: 1.0)
        } else {
            return NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
        }
    }

    func formatTokens(_ tokens: Int) -> String {
        if tokens >= 1_000_000_000 {
            return String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        } else if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        return "\(tokens)"
    }

    func formatYAxisLabel(_ value: Int) -> String {
        let lang = config?.language ?? "cs"
        let d = Double(value)
        if d >= 1e9 {
            let billions = d / 1e9
            let unit = L.t("unit.billion", lang)
            if billions >= 10 {
                return String(format: "%.0f\(unit)", billions)
            } else {
                return String(format: "%.1f\(unit)", billions)
            }
        } else if d >= 1e6 {
            let millions = d / 1e6
            let unit = L.t("unit.million", lang)
            if millions >= 10 {
                return String(format: "%.0f\(unit)", millions)
            } else {
                return String(format: "%.1f\(unit)", millions)
            }
        } else if d >= 1e3 {
            let unit = L.t("unit.thousand", lang)
            return String(format: "%.0f\(unit)", d / 1e3)
        }
        return "\(value)"
    }

    func formatCostInDollars(_ cost: Double) -> String {
        let lang = config?.language ?? "cs"
        let locale = lang == "en" ? Locale(identifier: "en_US") : Locale(identifier: "cs_CZ")
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = lang == "en" ? "," : " "
        formatter.usesGroupingSeparator = true

        let costInt = Int(cost)
        if let formatted = formatter.string(from: NSNumber(value: costInt)) {
            return "$\(formatted)"
        }
        return String(format: "$%.0f", cost)
    }

    func formatMonthLabel(_ month: String) -> String {
        let lang = config?.language ?? "cs"
        let components = month.split(separator: "-").map(String.init)
        if components.count == 2, let monthNum = components.last {
            let key = "month." + monthNum
            let abbr = L.t(key, lang)
            if abbr != key, let year = components.first?.suffix(2) {
                return "\(abbr) \(year)"
            }
        }
        return month
    }

    /// Long forms for the history table, where a column of "srp 26" says less
    /// than it costs in width. The chart keeps the short ones - it has no room.
    func formatMonthLabelLong(_ month: String) -> String {
        let lang = config?.language ?? "cs"
        let components = month.split(separator: "-").map(String.init)
        if components.count == 2, let monthNum = components.last, let year = components.first {
            let key = "month.full." + monthNum
            let name = L.t(key, lang)
            if name != key {
                return "\(name) \(year)"
            }
        }
        return formatMonthLabel(month)
    }

    func getDayLabelLong(_ date: String) -> String {
        guard let isoDate = parseISO(date) else { return date }
        let lang = config?.language ?? "cs"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: lang == "en" ? "en_US" : "cs_CZ")
        formatter.dateFormat = lang == "en" ? "MMM d, yyyy" : "d. M. yyyy"
        return formatter.string(from: isoDate)
    }

    func getDayLabel(_ date: String) -> String {
        if let isoDate = parseISO(date) {
            let lang = config?.language ?? "cs"
            let formatter = DateFormatter()
            formatter.dateFormat = lang == "en" ? "M/d" : "d. M."
            formatter.locale = lang == "en" ? Locale(identifier: "en_US") : Locale(identifier: "cs_CZ")
            return formatter.string(from: isoDate)
        }
        return date
    }

    func saveConfig(_ newConfig: Config) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let encoded = try encoder.encode(newConfig)
            try encoded.write(to: configPath)
            self.config = newConfig
            updateBarDisplay()
            NotificationCenter.default.post(name: NSNotification.Name("AppStateDidUpdate"), object: nil)
        } catch {
            let lang = config?.language ?? "cs"
            self.collectError = String(format: L.t("error.config_save_failed", lang), error.localizedDescription as NSString)
        }
    }

    func runCollectScript() {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/aipulse/collect.sh")

        let process = Process()
        process.executableURL = scriptPath

        do {
            try process.run()
        } catch {
            let lang = config?.language ?? "cs"
            DispatchQueue.main.async {
                self.collectError = String(format: L.t("error.collect_start_failed", lang), "\(error)" as NSString)
            }
        }
    }

    func runCollectScriptAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scriptPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/aipulse/collect.sh")

            let process = Process()
            process.executableURL = scriptPath

            let pipe = Pipe()
            process.standardError = pipe

            DispatchQueue.main.async {
                self?.isCollecting = true
                self?.collectError = nil
            }

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        self?.isCollecting = false
                        self?.collectError = nil
                        self?.loadData()
                    }
                } else {
                    let lang = self?.config?.language ?? "cs"
                    let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorMsg = errorText.isEmpty ? L.t("error.unknown", lang) : errorText

                    DispatchQueue.main.async {
                        self?.isCollecting = false
                        self?.collectError = errorMsg
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    let lang = self?.config?.language ?? "cs"
                    self?.isCollecting = false
                    self?.collectError = String(format: L.t("error.collect_start_failed", lang), "\(error)" as NSString)
                }
            }
        }
    }

    func updateLaunchInterval(_ minutes: Int) {
        let scriptPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/aipulse/set-interval.sh")

        let process = Process()
        process.executableURL = scriptPath
        process.arguments = [String(minutes)]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            let lang = config?.language ?? "cs"
            DispatchQueue.main.async {
                self.collectError = String(format: L.t("error.interval_failed", lang), "\(error)" as NSString)
            }
        }
    }

    func logout(completion: @escaping (Bool, String?) -> Void) {
        let findClaudeProcess = Process()
        findClaudeProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        findClaudeProcess.arguments = ["-lc", "command -v claude"]

        let findPipe = Pipe()
        findClaudeProcess.standardOutput = findPipe
        findClaudeProcess.standardError = Pipe()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try findClaudeProcess.run()
                findClaudeProcess.waitUntilExit()

                let data = findPipe.fileHandleForReading.readDataToEndOfFile()
                let claudePath = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let claudePath = claudePath, !claudePath.isEmpty else {
                    let lang = self.config?.language ?? "cs"
                    let errorMsg = L.t("error.claude_not_found", lang)
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                    return
                }

                let logoutProcess = Process()
                logoutProcess.executableURL = URL(fileURLWithPath: claudePath)
                logoutProcess.arguments = ["auth", "logout"]

                let errorPipe = Pipe()
                logoutProcess.standardError = errorPipe

                try logoutProcess.run()
                logoutProcess.waitUntilExit()

                if logoutProcess.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        self.loadData()
                        completion(true, nil)
                    }
                } else {
                    let lang = self.config?.language ?? "cs"
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorMsg = errorText.isEmpty ? L.t("error.unknown", lang) : errorText
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    func codexLogout(completion: @escaping (Bool, String?) -> Void) {
        let findCodexProcess = Process()
        findCodexProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        findCodexProcess.arguments = ["-lc", "command -v codex"]

        let findPipe = Pipe()
        findCodexProcess.standardOutput = findPipe
        findCodexProcess.standardError = Pipe()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try findCodexProcess.run()
                findCodexProcess.waitUntilExit()

                let data = findPipe.fileHandleForReading.readDataToEndOfFile()
                let codexPath = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let codexPath = codexPath, !codexPath.isEmpty else {
                    let lang = self.config?.language ?? "cs"
                    let errorMsg = L.t("error.codex_not_found", lang)
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                    return
                }

                let logoutProcess = Process()
                logoutProcess.executableURL = URL(fileURLWithPath: codexPath)
                logoutProcess.arguments = ["logout"]

                let errorPipe = Pipe()
                logoutProcess.standardError = errorPipe

                try logoutProcess.run()
                logoutProcess.waitUntilExit()

                if logoutProcess.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        self.loadData()
                        completion(true, nil)
                    }
                } else {
                    let lang = self.config?.language ?? "cs"
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorText = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let errorMsg = errorText.isEmpty ? L.t("error.unknown", lang) : errorText
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    func codexLogin(completion: @escaping (Bool, String?) -> Void) {
        let findCodexProcess = Process()
        findCodexProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        findCodexProcess.arguments = ["-lc", "command -v codex"]

        let findPipe = Pipe()
        findCodexProcess.standardOutput = findPipe
        findCodexProcess.standardError = Pipe()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try findCodexProcess.run()
                findCodexProcess.waitUntilExit()

                let data = findPipe.fileHandleForReading.readDataToEndOfFile()
                let codexPath = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard let codexPath = codexPath, !codexPath.isEmpty else {
                    let lang = self.config?.language ?? "cs"
                    let errorMsg = L.t("error.codex_not_found", lang)
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                    return
                }

                let loginProcess = Process()
                loginProcess.executableURL = URL(fileURLWithPath: codexPath)
                loginProcess.arguments = ["login"]

                // Do not wait for it: codex login stays up serving its local callback
                // until the browser flow finishes, so the polling below is the signal.
                try loginProcess.run()

                let startTime = Date()
                let timeout: TimeInterval = 180

                DispatchQueue.global(qos: .userInitiated).async {
                    var finished = false
                    while Date().timeIntervalSince(startTime) < timeout && !finished {
                        let statusProcess = Process()
                        statusProcess.executableURL = URL(fileURLWithPath: codexPath)
                        statusProcess.arguments = ["login", "status"]

                        // codex login status reports on stderr, so both streams
                        // are merged - reading stdout alone never sees the answer.
                        let outputPipe = Pipe()
                        statusProcess.standardOutput = outputPipe
                        statusProcess.standardError = outputPipe

                        do {
                            try statusProcess.run()
                            statusProcess.waitUntilExit()

                            if statusProcess.terminationStatus == 0 {
                                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                                let outputText = String(data: outputData, encoding: .utf8) ?? ""
                                if outputText.contains("Logged in") {
                                    finished = true
                                    if loginProcess.isRunning {
                                        loginProcess.terminate()
                                    }
                                    DispatchQueue.main.async {
                                        self.loadData()
                                        completion(true, nil)
                                    }
                                    return
                                }
                            }
                        } catch {
                            break
                        }

                        Thread.sleep(forTimeInterval: 2)
                    }

                    if loginProcess.isRunning {
                        loginProcess.terminate()
                    }
                    let lang = self.config?.language ?? "cs"
                    let errorMsg = L.t("login.timed_out", lang)
                    DispatchQueue.main.async {
                        completion(false, errorMsg)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
}

extension AppState {
    enum IndicatorStyle { case dot, bar, battery }

    static func makeIndicator(percent: Int, color: NSColor, style: IndicatorStyle) -> NSImage {
        let fraction = max(0, min(1, CGFloat(percent) / 100))
        let size: NSSize
        switch style {
        case .dot: size = NSSize(width: 10, height: 10)
        case .bar: size = NSSize(width: 26, height: 8)
        case .battery: size = NSSize(width: 30, height: 12)
        }
        let image = NSImage(size: size, flipped: false) { rect in
            switch style {
            case .dot:
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            case .bar:
                let track = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                NSColor.tertiaryLabelColor.setFill(); track.fill()
                var filled = rect; filled.size.width = rect.width * fraction
                color.setFill()
                NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
            case .battery:
                let body = rect.insetBy(dx: 1, dy: 1)
                let shell = NSBezierPath(roundedRect: body, xRadius: 2, yRadius: 2)
                NSColor.secondaryLabelColor.setStroke(); shell.lineWidth = 1; shell.stroke()
                var filled = body.insetBy(dx: 2, dy: 2)
                filled.size.width *= fraction
                color.setFill()
                NSBezierPath(roundedRect: filled, xRadius: 1, yRadius: 1).fill()
                let cap = NSRect(x: rect.maxX - 1, y: rect.midY - 2, width: 1, height: 4)
                NSColor.secondaryLabelColor.setFill(); NSBezierPath(rect: cap).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

extension AppState {
    static let spinDuration: TimeInterval = 1.0

    func refreshLimitsAsync() {
        guard !isRefreshingLimits else { return }
        isRefreshingLimits = true
        collectError = nil

        let started = Date()
        refreshStartedAt = started
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            if self?.isRefreshingLimits == true {
                self?.isRefreshingLimits = false
                let language = self?.config?.language ?? "cs"
                self?.collectError = L.t("error.limits_timeout", language)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let script = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/aipulse/refresh-limits.sh")
            let process = Process()
            process.executableURL = script
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()

            var failure: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let language = self?.config?.language ?? "cs"
                    let raw = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: raw, encoding: .utf8) ?? ""
                    if text.contains("AUTH_EXPIRED") {
                        failure = L.t("error.auth_expired", language)
                    } else {
                        failure = text.isEmpty ? L.t("error.limits_failed", language) : text
                    }
                }
            } catch {
                failure = error.localizedDescription
            }

            let elapsed = Date().timeIntervalSince(started)
            let remaining = max(0, AppState.spinDuration - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
                self?.isRefreshingLimits = false
                self?.collectError = failure
                self?.loadData()
            }
        }
    }
}
