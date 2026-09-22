import AppKit
import Observation
import RecallCore
import SwiftUI

/// Which page of Settings is showing.
public enum SettingsTab: String, Hashable, Sendable, CaseIterable {
    case general
    case privacy
    case intelligence
    case collections
    case snippets
    case twoFactor
}

/// Opens Settings on a particular page.
///
/// Settings is a SwiftUI `Settings` scene, so there is no window object to hand a tab to.
/// The request is parked here, `SettingsView` observes it, and it works whether the window
/// was already open or is about to be.
@MainActor
@Observable
public final class SettingsNavigator {
    public static let shared = SettingsNavigator()

    /// The page to show. Cleared once ``SettingsView`` has honoured it, so reopening
    /// Settings later lands wherever the user last left it.
    public internal(set) var requestedTab: SettingsTab?

    private init() {}

    /// Supplied by the app: shows the Settings window. See ``SettingsWindowController``
    /// for why this is not `NSApp.sendAction(showSettingsWindow:)`.
    public var presenter: (@MainActor (SettingsTab?) -> Void)?

    /// Brings Settings forward, on `tab` when one is given and otherwise wherever the
    /// user last left it.
    public func open(_ tab: SettingsTab? = nil) {
        guard let presenter else {
            Log.ui.error("Settings asked for before the window was wired up")
            return
        }
        presenter(tab)
    }

    func consumeRequest() -> SettingsTab? {
        defer { requestedTab = nil }
        return requestedTab
    }
}
