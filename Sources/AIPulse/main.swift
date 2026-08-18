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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
            self?.updateStatusBarView()
        }
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let statusItem = statusItem, let button = statusItem.button else { return }

        appState?.loadData()

        if let popover = popover, popover.isShown {
            popover.performClose(sender)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
