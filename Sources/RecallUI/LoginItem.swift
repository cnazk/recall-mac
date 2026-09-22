import Foundation
import RecallCore
import ServiceManagement

/// Registers Recall to open at login.
///
/// A clipboard manager records only while it is running, so an app that does not come
/// back after a reboot quietly stops being a clipboard manager. This is closer to a
/// requirement than a preference — but it is still the user's machine, so it is a switch,
/// offered during onboarding rather than assumed.
///
/// `SMAppService` is the source of truth. Mirroring the state into settings would create
/// two answers to the same question, and the one macOS believes is the one that matters:
/// the user can revoke this in System Settings › General › Login Items at any time, and
/// Recall has to reflect that rather than argue with it.
@MainActor
public enum LoginItem {
    public enum State: Equatable, Sendable {
        case enabled
        case disabled
        /// Registered, but the user has not approved it in System Settings yet.
        case awaitingApproval
        case unavailable

        public var isOn: Bool { self == .enabled || self == .awaitingApproval }
    }

    public static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .notRegistered: .disabled
        case .requiresApproval: .awaitingApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    /// - Returns: the state afterwards, which may be ``State/awaitingApproval``.
    @discardableResult
    public static func setEnabled(_ isEnabled: Bool) -> State {
        do {
            if isEnabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for ordinary reasons — an unsigned build, or an app run
            // from a quarantined download — and none of them are worth an alert.
            Log.ui.error("Login item change failed: \(String(describing: error), privacy: .public)")
        }
        return state
    }

    /// Opens the pane where macOS lets the user approve or revoke it.
    public static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
