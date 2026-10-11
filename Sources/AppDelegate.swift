import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 关键修复：菜单栏 App 默认没有主菜单，导致 Cmd+Q（退出）和
        // Cmd+C / Cmd+V / Cmd+X / Cmd+A（编辑）等系统快捷键全部失效。
        // 这里手动构建主菜单（App 菜单 + 编辑菜单），让快捷键生效。
        // 退出项统一指向本 delegate 的 quitApp()，比直接指向
        // NSApplication.terminate: 更可靠。
        NSApplication.shared.mainMenu = Self.buildMainMenu(delegate: self)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusImage(running: false)
            // 左键弹面板、右键弹菜单（含退出）
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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

    // 退出前清理：杀掉内嵌的 mihomo 子进程，避免残留代理进程。
    func applicationWillTerminate(_ notification: Notification) {
        appState.stop()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        // 右键 → 弹出含「退出」的菜单
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        // 左键：先激活 App，使 Cmd+Q 与编辑快捷键能正确路由到本 App，
        // 否则 .accessory 模式下键盘事件会被最前面的 App 吃掉。
        NSApp.activate(ignoringOtherApps: true)

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let quit = NSMenuItem(
            title: "退出 ClashVPN",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// 统一的退出入口：先停核心，再终止 App。
    @objc func quitApp() {
        appState.stop()
        NSApp.terminate(nil)
    }

    /// 构建主菜单：App 菜单（含退出）+ 编辑菜单（复制/粘贴等系统快捷键）
    private static func buildMainMenu(delegate: AppDelegate) -> NSMenu {
        let main = NSMenu()

        // App 菜单
        let appMenu = NSMenu()
        let appItem = NSMenuItem(title: "ClashVPN", action: nil, keyEquivalent: "")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let quit = NSMenuItem(
            title: "退出 ClashVPN",
            action: #selector(AppDelegate.quitApp),
            keyEquivalent: "q"
        )
        quit.target = delegate
        appMenu.addItem(quit)

        // 编辑菜单：提供 Cmd+Z / Cmd+X / Cmd+C / Cmd+V / Cmd+A 等快捷键
        let editMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let items: [(String, Selector, String)] = [
            ("Undo", Selector("undo:"), "z"),
            ("Redo", Selector("redo:"), "Z"),
            ("Cut", Selector("cut:"), "x"),
            ("Copy", Selector("copy:"), "c"),
            ("Paste", Selector("paste:"), "v"),
            ("Select All", Selector("selectAll:"), "a"),
        ]
        for (title, sel, key) in items {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = nil // 交给第一响应者（当前聚焦的输入框）处理
            editMenu.addItem(mi)
        }
        return main
    }

    private static func statusImage(running: Bool) -> NSImage? {
        let name = running ? "network.badge.shield.half.filled" : "network"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "network", accessibilityDescription: nil)
        img?.size = NSSize(width: 18, height: 18)
        return img
    }
}
