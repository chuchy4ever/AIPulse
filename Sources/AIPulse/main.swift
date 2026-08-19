import SwiftUI
import AppKit

@main
struct AIPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var appState: AppState?
    var refreshTimer: Timer?
    var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check for snapshot mode early before any UI setup
        if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--snapshot" {
            if CommandLine.arguments.count > 2 {
                let outputDir = CommandLine.arguments[2]
                runSnapshotMode(outputDir: outputDir)
            } else {
                fputs("Error: --snapshot requires an output directory argument\n", stderr)
            }
            exit(0)
        }

        NSApplication.shared.setActivationPolicy(.accessory)

        appState = AppState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover(_:))
            button.target = self
            updateStatusBarView()
        }

        popover = NSPopover()
        popover?.behavior = .transient
        popover?.delegate = self

        if let appState = appState {
            let popoverView = PopoverView(appState: appState)
            popover?.contentViewController = NSHostingController(rootView: popoverView)
        }

        appState?.loadData()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateStatusBarView),
            name: NSNotification.Name("AppStateDidUpdate"),
            object: nil
        )

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.appState?.loadData()
            self?.updateStatusBarView()
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let statusItem = statusItem, let button = statusItem.button else { return }

        appState?.loadData()

        if let popover = popover, popover.isShown {
            closePopover(sender)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // .transient alone does not dismiss this: as an accessory app we are
            // not active, so a click in another app never reaches AppKit's own
            // dismissal. Watch for it ourselves while the popover is up.
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] _ in
                self?.closePopover(nil)
            }
        }
    }

    func closePopover(_ sender: Any?) {
        popover?.performClose(sender)

        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    @objc func updateStatusBarView() {
        guard let button = statusItem?.button, let appState = appState else { return }

        let color = appState.barColor
        let value = appState.barValue

        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold)
        ]
        button.attributedTitle = NSAttributedString(string: value, attributes: attrs)
        button.image = appState.barImage
        button.imagePosition = value.isEmpty ? .imageOnly : .imageLeading
    }
}

// MARK: - Snapshot Mode

@MainActor
func runSnapshotMode(outputDir: String) {
    let fileManager = FileManager.default

    // Create output directory if it doesn't exist
    let outputURL = URL(fileURLWithPath: outputDir)
    do {
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true, attributes: nil)
    } catch {
        fputs("Error: Failed to create output directory: \(error)\n", stderr)
        exit(1)
    }

    // Initialize AppState and load data
    let appState = AppState()
    appState.loadData()

    // Wait for data to load with timeout
    let deadline = Date().addingTimeInterval(10.0)
    while appState.data == nil && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    guard appState.data != nil else {
        fputs("Error: Failed to load data within timeout\n", stderr)
        exit(1)
    }

    var savedFiles: [String] = []
    var hasError = false

    // Render PopoverView
    let popoverView = PopoverView(appState: appState)
        .frame(width: 376)

    if let popoverPath = renderViewToFile(popoverView, scale: 2.0, name: "popover", outputDir: outputDir) {
        savedFiles.append(popoverPath)
    } else {
        hasError = true
    }

    // The panes, not the whole settings window: NavigationSplitView is
    // AppKit-backed and comes out of the renderer as a placeholder block.
    let historyView = HistorySectionView(appState: appState)
        .frame(width: 720, height: 720)

    if let historyPath = renderViewToFile(historyView, scale: 2.0, name: "history", outputDir: outputDir) {
        savedFiles.append(historyPath)
    } else {
        hasError = true
    }

    let notificationsView = NotificationsSectionView(appState: appState)
        .frame(width: 720, height: 620)

    if let notificationsPath = renderViewToFile(notificationsView, scale: 2.0, name: "notifications", outputDir: outputDir) {
        savedFiles.append(notificationsPath)
    } else {
        hasError = true
    }

    if hasError {
        exit(1)
    }

    // Print results to stdout
    for file in savedFiles {
        print(file)
    }
}

@MainActor
func renderViewToFile<V: View>(_ view: V, scale: CGFloat, name: String, outputDir: String) -> String? {
    // Dark has to come through the SwiftUI environment: an offscreen renderer
    // has no window, so NSApp.appearance never reaches it. The background has to
    // come with it - on screen the window paints it, here nothing would.
    let content = view
        .environment(\.colorScheme, .dark)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
    let renderer = ImageRenderer(content: content)
    renderer.scale = scale

    guard let cgImage = renderer.cgImage else {
        fputs("Error: Failed to render \(name)\n", stderr)
        return nil
    }

    let nsImage = NSImage(cgImage: cgImage, size: NSZeroSize)

    guard let tiffData = nsImage.tiffRepresentation,
          let bitmapImage = NSBitmapImageRep(data: tiffData),
          let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
        fputs("Error: Failed to convert \(name) to PNG\n", stderr)
        return nil
    }

    let fileName = "\(name).png"
    let filePath = URL(fileURLWithPath: outputDir).appendingPathComponent(fileName).path

    do {
        try pngData.write(to: URL(fileURLWithPath: filePath))
        return filePath
    } catch {
        fputs("Error: Failed to write \(name) to file: \(error)\n", stderr)
        return nil
    }
}
