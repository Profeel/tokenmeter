import AppKit
import SwiftUI
import TokenMeterCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?
    private let viewModel = DashboardViewModel()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 560)
        popover.behavior = .transient

        let contentView = DashboardView(viewModel: viewModel, onQuit: {
            NSApp.terminate(nil)
        })
        popover.contentViewController = NSHostingController(rootView: contentView)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.title = "⚡ …"
        }

        viewModel.onMenuTitleChange = { [weak self] newTitle in
            self?.statusItem.button?.title = newTitle
        }

        viewModel.refreshAll()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.viewModel.refreshUsage()
            }
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            if popover.isShown {
                popover.performClose(sender)
            } else {
                viewModel.refreshUsage()
                popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let snap = viewModel.snapshot
        let header = NSMenuItem(
            title: "今日: \(Formatters.compactTokens(snap.totalUsage.totalTokens)) · \(Formatters.usd(snap.totalEstimatedCostUSD))",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "立即刷新数据与端点探针", action: #selector(contextRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let openCfg = NSMenuItem(title: "打开配置文件 (~/.tokenmeter)", action: #selector(openConfigFolder), keyEquivalent: ",")
        openCfg.target = self
        menu.addItem(openCfg)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出 TokenMeter", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func contextRefresh() {
        viewModel.refreshAll()
    }

    @objc private func openConfigFolder() {
        let cfg = TokenMeterConfig.load()
        if !FileManager.default.fileExists(atPath: TokenMeterConfig.configFileURL.path) {
            cfg.save()
        }
        NSWorkspace.shared.open(TokenMeterConfig.configDirectoryURL)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
