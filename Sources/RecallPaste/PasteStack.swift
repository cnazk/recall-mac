import Foundation
import RecallCore

/// A queue of items to paste one after another.
///
/// The shape is deliberate, and each choice avoids a specific failure:
///
/// - **Explicit adds.** Only what the user sends here goes on the stack, so a stray copy
///   never displaces what they queued.
/// - **First in, first out.** Collect three things, place three things, in that order.
/// - **Pasting drains.** An item leaves when it is used, so the next paste is always the
///   next thing, and an empty stack behaves exactly like no stack at all.
/// - **It expires.** A stack that fires a paste from twenty minutes ago is worse than no
///   stack, so it clears itself after an idle period.
///
/// Pure value semantics: no pasteboard, no timers, no UI — all of which makes the parts
/// that are easy to get wrong testable.
public struct PasteStack: Sendable, Equatable {
    /// How long the stack survives without being touched.
    public static let idleTimeout: TimeInterval = 600

    /// Beyond this, the user has lost track of what is queued anyway.
    public static let capacity = 24

    public private(set) var itemIDs: [UUID] = []
    /// When the stack was last added to or drawn from.
    public private(set) var lastTouched: Date?

    public init() {}

    public var isEmpty: Bool { itemIDs.isEmpty }
    public var count: Int { itemIDs.count }
    public var next: UUID? { itemIDs.first }

    /// Queues an item. Re-adding one already queued moves it to the back rather than
    /// duplicating it — a stack with the same clip twice is almost always a mis-press.
    public mutating func add(_ id: UUID, at date: Date = .now) {
        expireIfStale(at: date)
        itemIDs.removeAll { $0 == id }
        itemIDs.append(id)
        if itemIDs.count > Self.capacity {
            itemIDs.removeFirst(itemIDs.count - Self.capacity)
        }
        lastTouched = date
    }

    /// Takes the next item, removing it.
    public mutating func takeNext(at date: Date = .now) -> UUID? {
        expireIfStale(at: date)
        guard !itemIDs.isEmpty else { return nil }
        let id = itemIDs.removeFirst()
        lastTouched = itemIDs.isEmpty ? nil : date
        return id
    }

    public mutating func remove(_ id: UUID) {
        itemIDs.removeAll { $0 == id }
        if itemIDs.isEmpty { lastTouched = nil }
    }

    public mutating func clear() {
        itemIDs.removeAll()
        lastTouched = nil
    }

    /// Drops everything if the stack has gone stale. Called on every access, so a stale
    /// stack can never be used by accident — it is not enough to have a timer running,
    /// because the timer may not have fired yet when the paste arrives.
    public mutating func expireIfStale(at date: Date = .now) {
        guard let lastTouched, date.timeIntervalSince(lastTouched) >= Self.idleTimeout else { return }
        clear()
    }

    /// Seconds until the stack clears itself, for the HUD's countdown.
    public func secondsUntilExpiry(at date: Date = .now) -> TimeInterval? {
        guard let lastTouched else { return nil }
        return max(0, Self.idleTimeout - date.timeIntervalSince(lastTouched))
    }
}
