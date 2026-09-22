import Foundation
import Observation
import RecallCore

/// Owns the live settings and writes every change through to disk.
///
/// The UI binds directly to this; there is no "Save" button, because a preferences pane
/// with an unsaved state is a preferences pane that loses your preferences.
@MainActor
@Observable
public final class SettingsController {
    public private(set) var settings: RecallSettings
    /// Settings the user has changed that only take effect after a relaunch.
    public private(set) var needsRestart = false

    private let store: SettingsStore
    private let launchSettings: RecallSettings
    /// Called after every change, so the running app picks it up without a relaunch.
    public var onChange: ((RecallSettings) -> Void)?

    public init(store: SettingsStore = SettingsStore()) {
        self.store = store
        let loaded = store.load()
        self.settings = loaded
        self.launchSettings = loaded
    }

    /// Applies a change and persists it.
    public func update(_ change: (inout RecallSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }

        settings = updated
        store.save(updated)
        needsRestart = updated.requiresRestart(comparedTo: launchSettings)
        onChange?(updated)
    }

    public func resetToDefaults() {
        settings = .default
        store.save(.default)
        needsRestart = RecallSettings.default.requiresRestart(comparedTo: launchSettings)
        onChange?(.default)
    }

    /// True when history is being kept in RAM only — the panel uses this to warn that
    /// pins will not survive a quit.
    public var isInMemoryMode: Bool {
        settings.storageMode == .inMemory
    }
}
