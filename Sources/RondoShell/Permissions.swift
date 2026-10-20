import AppKit
import ApplicationServices
import RondoKit
import ServiceManagement

/// Read-only permission checks + System Settings deep links. The user grants; code never changes settings.
public enum Permissions {
    public static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    /// Accessibility (global key monitor for arrows/Enter during drags). Never prompts.
    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    public static func openAccessibilitySettings() { NSWorkspace.shared.open(accessibilitySettingsURL) }
    public static func openAutomationSettings() { NSWorkspace.shared.open(automationSettingsURL) }

    public enum AutomationStatus: Equatable, Sendable {
        case notChecked, allowed, denied, finderNotRunning
        case error(String)

        public var title: String {
            switch self {
            case .notChecked: "Not checked"
            case .allowed: "Allowed"
            case .denied: "Not allowed"
            case .finderNotRunning: "Finder isn't running"
            case .error(let m): m
            }
        }
    }

    /// Sends Finder a harmless Apple Event (`get name`). Call only from an explicit user click:
    /// the first attempt shows macOS's own consent prompt, where the user decides.
    @MainActor
    public static func checkAutomation() -> AutomationStatus {
        switch AppleScriptRunner.run("tell application \"Finder\" to get name") {
        case .success: .allowed
        case .failure(.notPermitted): .denied
        case .failure(.finderNotRunning): .finderNotRunning
        case .failure(let e): .error(e.localizedDescription)
        }
    }
}

/// `SMAppService.mainApp` wrapper. Only changes registration when the user flips the toggle.
public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "On"
        case .requiresApproval: "Needs approval in System Settings › General › Login Items"
        case .notRegistered: "Off"
        case .notFound: "Unavailable (run the bundled Rondo.app)"
        @unknown default: "Unknown"
        }
    }

    public static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    public static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
