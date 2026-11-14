import AppKit
import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var requiresApproval: Bool = false
    @Published public private(set) var lastError: String?

    private init() {
        refreshStatus()
    }

    public func refreshStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = (status == .enabled)
        requiresApproval = (status == .requiresApproval)
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()
            return true
        } catch {
            lastError = error.localizedDescription
            refreshStatus()
            return false
        }
    }

    public func toggle() {
        setEnabled(!isEnabled)
    }

    public func openSystemLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
