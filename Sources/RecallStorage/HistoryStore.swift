import Foundation
import RecallCore

/// The persistence contract the rest of the app codes against.
///
/// Two implementations exist: ``InMemoryHistoryStore`` (In-Memory Mode — nothing ever
/// touches the disk) and ``SQLiteHistoryStore``. Swapping between them is a settings
/// change, not a code change.
public protocol HistoryStore: Actor {
    /// Inserts a clip, or promotes the existing row with the same content hash.
    @discardableResult
    func capture(_ item: ClipItem) throws -> CaptureOutcome

    func items(matching query: HistoryQuery) throws -> [ClipItem]
    func item(id: UUID) throws -> ClipItem?

    /// Records that the item was pasted: bumps `useCount` and `lastUsedAt`.
    func markUsed(id: UUID, at date: Date) throws
    func setPinned(_ pinned: Bool, id: UUID) throws

    /// Rewrites the order of the pinned group. `ids` is the new order, first to last.
    func reorderPins(_ ids: [UUID]) throws

    /// Every item carrying a snippet shortcode.
    func snippets() throws -> [ClipItem]
    func update(_ item: ClipItem) throws

    /// Merges what the background pass produced onto the row as it stands now.
    ///
    /// Not ``update(_:)``. Enrichment holds a copy of the clip from before it started, and
    /// writing that copy back undoes anything the user did while it was working — which is
    /// how pinning a clip you had just copied silently stopped sticking.
    func applyEnrichment(_ enrichment: ClipEnrichment, to id: UUID) throws
    func delete(id: UUID) throws
    func deleteAll() throws

    /// Deletes everything whose `expiresAt` has passed, except pinned items — a pin is
    /// the user saying "keep this", and no automatic path may overrule it.
    @discardableResult
    func purgeExpired(asOf date: Date) throws -> Int

    /// Enforces the history limit and retention window.
    @discardableResult
    func enforceRetention(limit: Int, olderThan cutoff: Date?) throws -> Int

    var count: Int { get throws }

    /// Bytes this store occupies on disk. Zero for In-Memory Mode, which is the point.
    var footprint: Int64 { get throws }
}

/// Constants for the pinned group's ordinals.
public enum PinOrder {
    /// Gap between adjacent pins, so a drag rewrites one row instead of renumbering all
    /// of them. Values are only ever compared, never displayed.
    public static let spacing = 1_000
}
