import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusImage(running: false)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 384, height: 620)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ContentView().environmentObject(appState)
        )

        appState.onStatusChange = { [weak self] running in
            DispatchQueue.main.async {
                self?.statusItem.button?.image = Self.statusImage(running: running)
            }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private static func statusImage(running: Bool) -> NSImage? {
        let name = running ? "network.badge.shield.half.filled" : "network"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        img?.size = NSSize(width: 18, height: 18)
        return img
    }
}
