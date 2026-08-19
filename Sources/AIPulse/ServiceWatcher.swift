import Foundation
import AppKit

class ServiceWatcher {
    private let stateFilePath: URL

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".local/share/aipulse")
        self.stateFilePath = dir.appendingPathComponent("notify-state.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func checkAndNotify(data: UsageData, config: Config) {
        var previousStates = loadStates()
        var hasChanges = false

        // Check Anthropic components
        if let components = data.services.anthropic.components {
            for component in components {
                let key = "anthropic:\(component.id)"
                let oldStatus = previousStates[key]
                if oldStatus != component.status {
                    previousStates[key] = component.status
                    hasChanges = true
                }

                // Only notify if we've seen this component before
                if let oldStatus = oldStatus, oldStatus != component.status {
                    if config.notifyServices.contains(key) {
                        sendNotification(componentName: component.name, fromStatus: oldStatus, toStatus: component.status, language: config.language)
                    }
                }
            }
        }

        // Check OpenAI components
        if let components = data.services.openai.components {
            for component in components {
                let key = "openai:\(component.id)"
                let oldStatus = previousStates[key]
                if oldStatus != component.status {
                    previousStates[key] = component.status
                    hasChanges = true
                }

                // Only notify if we've seen this component before
                if let oldStatus = oldStatus, oldStatus != component.status {
                    if config.notifyServices.contains(key) {
                        sendNotification(componentName: component.name, fromStatus: oldStatus, toStatus: component.status, language: config.language)
                    }
                }
            }
        }

        if hasChanges {
            saveStates(previousStates)
        }
    }

    /// Shows both shapes a real alert can take, on whichever service the user
    /// picked first - a sample that says nothing about a service would not tell
    /// them what an actual outage looks like.
    func sendTestNotification(data: UsageData?, config: Config) {
        let language = config.language
        let name = sampleComponentName(data: data, config: config)
            ?? L.t("notifications.test_service", language)

        send(headlineKey: "notifications.down_title", componentName: name,
             status: "major_outage", language: language)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.send(headlineKey: "notifications.up_title", componentName: name,
                       status: "operational", language: language)
        }
    }

    private func sampleComponentName(data: UsageData?, config: Config) -> String? {
        guard let data = data else { return nil }
        let all = (data.services.anthropic.components ?? []).map { ("anthropic:\($0.id)", $0) }
            + (data.services.openai.components ?? []).map { ("openai:\($0.id)", $0) }
        if let picked = all.first(where: { config.notifyServices.contains($0.0) }) {
            return picked.1.name
        }
        return all.first?.1.name
    }

    private func sendNotification(componentName: String, fromStatus: String, toStatus: String, language: String) {
        let key = toStatus == "operational" ? "notifications.up_title" : "notifications.down_title"
        send(headlineKey: key, componentName: componentName, status: toStatus, language: language)
    }

    private func send(headlineKey: String, componentName: String, status: String, language: String) {
        let headline = String(format: L.t(headlineKey, language), componentName as NSString)

        // The status itself is the useful part, so it goes in the body: a partial
        // outage and a full one are worth telling apart at a glance.
        let statusKey = "status.\(status)"
        var statusText = L.t(statusKey, language)
        if statusText == statusKey {
            statusText = L.t("status.unknown", language)
        }

        deliver(title: "AIPulse", subtitle: headline, body: statusText)
    }

    /// Runs the AppleScript in-process instead of shelling out to osascript, so
    /// macOS credits the alert to this bundle and shows its icon rather than
    /// whatever binary ran the script. Must stay on the main thread.
    private func deliver(title: String, subtitle: String, body: String) {
        var script = "display notification \"\(escapeApplescript(body))\""
        script += " with title \"\(escapeApplescript(title))\""
        if !subtitle.isEmpty {
            script += " subtitle \"\(escapeApplescript(subtitle))\""
        }

        let run = {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error = error {
                fputs("notification failed: \(error)\n", stderr)
            }
        }

        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    private func escapeApplescript(_ text: String) -> String {
        var result = ""
        for char in text {
            if char == "\\" {
                result.append("\\\\")
            } else if char == "\"" {
                result.append("\\\"")
            } else {
                result.append(char)
            }
        }
        return result
    }

    private func loadStates() -> [String: String] {
        guard FileManager.default.fileExists(atPath: stateFilePath.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: stateFilePath)
            if let decoded = try JSONDecoder().decode([String: String].self, from: data) as [String: String]? {
                return decoded
            }
        } catch {
            fputs("Failed to load service state: \(error)\n", stderr)
        }

        return [:]
    }

    private func saveStates(_ states: [String: String]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(states)
            try encoded.write(to: stateFilePath)
        } catch {
            fputs("Failed to save service state: \(error)\n", stderr)
        }
    }
}
