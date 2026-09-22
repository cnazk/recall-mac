import Foundation
import RecallCore

/// Deletes expired secrets on a timer.
///
/// Auto-expiring secrets need a guarantee stronger than "the UI hides it": the reaper
/// runs while the app is up, and every store also purges expired rows when it is opened,
/// so a secret cannot survive a restart either.
public actor ExpiryReaper {
    private let store: any HistoryStore
    private let clock: any DateProviding
    private let interval: TimeInterval
    private var task: Task<Void, Never>?

    public init(store: any HistoryStore, clock: any DateProviding = SystemClock(), interval: TimeInterval = 5) {
        self.store = store
        self.clock = clock
        self.interval = interval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sweep()
                try? await Task.sleep(for: .seconds(await self.interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Runs one purge pass. Exposed so tests can drive it without waiting on the timer.
    @discardableResult
    public func sweep() async -> Int {
        do {
            let removed = try await store.purgeExpired(asOf: clock.now)
            if removed > 0 {
                Log.security.info("Purged \(removed, privacy: .public) expired item(s)")
            }
            return removed
        } catch {
            Log.security.error("Expiry sweep failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }
}
