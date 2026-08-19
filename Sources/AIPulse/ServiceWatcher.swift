import Foundation

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

    func sendTestNotification(language: String) {
        let body = L.t("notifications.test_body", language)
        sendNotificationViaOsascript(title: "AIPulse", subtitle: "", body: body)
    }

    private func sendNotification(componentName: String, fromStatus: String, toStatus: String, language: String) {
        let isRecovering = toStatus == "operational"
        let titleKey = isRecovering ? "notifications.up_title" : "notifications.down_title"
        let headline = String(format: L.t(titleKey, language), componentName as NSString)

        // The status itself is the useful part, so it goes in the body: a partial
        // outage and a full one are worth telling apart at a glance.
        let statusKey = "status.\(toStatus)"
        var statusText = L.t(statusKey, language)
        if statusText == statusKey {
            statusText = L.t("status.unknown", language)
        }

        sendNotificationViaOsascript(title: "AIPulse", subtitle: headline, body: statusText)
    }

    private func sendNotificationViaOsascript(title: String, subtitle: String, body: String) {
        let escapedBody = escapeApplescript(body)
        let escapedSubtitle = escapeApplescript(subtitle)

        var script = "display notification \"\(escapedBody)\" with title \"\(escapeApplescript(title))\""
        if !subtitle.isEmpty {
            script += " subtitle \"\(escapedSubtitle)\""
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                if let errorText = String(data: errorData, encoding: .utf8), !errorText.isEmpty {
                    fputs("osascript error: \(errorText)", stderr)
                }
            }
        } catch {
            fputs("Failed to run osascript: \(error)\n", stderr)
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
