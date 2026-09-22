import Foundation

/// Persists ``RecallSettings``.
///
/// Settings are stored as one JSON blob rather than a key per field: the settings type
/// is the unit that changes, and a half-applied set of preferences after a crash is a
/// worse failure than losing a preference we never wrote.
public final class SettingsStore: @unchecked Sendable {
    public static let defaultsKey = "com.recall.settings.v1"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard, key: String = SettingsStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    /// The stored settings, or the defaults when nothing has been saved or the stored
    /// value no longer decodes — a settings file that has gone stale across a version
    /// should reset, not stop the app from starting.
    public func load() -> RecallSettings {
        lock.lock()
        defer { lock.unlock() }

        guard let data = defaults.data(forKey: key) else { return .default }
        do {
            return try decoder.decode(RecallSettings.self, from: data)
        } catch {
            Log.storage.error("Settings could not be decoded; falling back to defaults")
            return .default
        }
    }

    public func save(_ settings: RecallSettings) {
        lock.lock()
        defer { lock.unlock() }

        do {
            defaults.set(try encoder.encode(settings), forKey: key)
        } catch {
            Log.storage.error("Settings could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}

public extension RecallSettings {
    /// Changes that only take effect the next time Recall launches, because they decide
    /// how the app is composed rather than how it behaves.
    func requiresRestart(comparedTo other: RecallSettings) -> Bool {
        storageMode != other.storageMode
    }
}
