import AppKit
import SwiftUI
import TokenMeterCore

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var refreshTimer: Timer?
    private var probeTickCount = 0
    private let viewModel = DashboardViewModel()

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        NotificationManager.shared.configureAndRequestPermission()
        LaunchAtLoginManager.shared.refreshStatus()

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 580)
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
                guard let self else { return }
                self.probeTickCount += 1
                self.viewModel.refreshUsage()
                self.viewModel.refreshQuotas()
                if self.probeTickCount % 2 == 0 {
                    self.viewModel.refreshProbes()
                }
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
                viewModel.refreshQuotas()
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

        menu.addItem(NSMenuItem.separator())

        LaunchAtLoginManager.shared.refreshStatus()
        let launchItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLoginManager.shared.isEnabled ? .on : .off
        menu.addItem(launchItem)

        let notifyItem = NSMenuItem(title: "额度预警与 429 通知", action: #selector(toggleNotifications), keyEquivalent: "")
        notifyItem.target = self
        notifyItem.state = viewModel.notificationsEnabled ? .on : .off
        menu.addItem(notifyItem)

        let testNotifyItem = NSMenuItem(title: "发送测试通知", action: #selector(sendTestNotification), keyEquivalent: "")
        testNotifyItem.target = self
        menu.addItem(testNotifyItem)

        menu.addItem(NSMenuItem.separator())

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

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLoginManager.shared.toggle()
        if LaunchAtLoginManager.shared.requiresApproval {
            LaunchAtLoginManager.shared.openSystemLoginItemsSettings()
        }
    }

    @objc private func toggleNotifications() {
        viewModel.toggleNotifications()
    }

    @objc private func sendTestNotification() {
        NotificationManager.shared.configureAndRequestPermission()
        NotificationManager.shared.sendTestNotification()
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
