import Foundation

/// A request for a slice of history.
///
/// `text` is matched by the storage layer's literal/FTS search; semantic ranking is layered
/// on top by the intelligence module rather than being expressed here.
public struct HistoryQuery: Sendable, Equatable {
    public var text: String?
    public var kinds: Set<ClipKind>?
    public var tags: Set<String>
    /// Localized name or bundle identifier of the app a clip came from.
    public var sourceApp: String?
    /// Only items copied at or after this moment.
    public var since: Date?
    public var pinnedOnly: Bool
    public var limit: Int
    public var offset: Int

    public init(
        text: String? = nil,
        kinds: Set<ClipKind>? = nil,
        tags: Set<String> = [],
        sourceApp: String? = nil,
        since: Date? = nil,
        pinnedOnly: Bool = false,
        limit: Int = 200,
        offset: Int = 0
    ) {
        self.text = text
        self.kinds = kinds
        self.tags = tags
        self.sourceApp = sourceApp
        self.since = since
        self.pinnedOnly = pinnedOnly
        self.limit = limit
        self.offset = offset
    }

    public static let recent = HistoryQuery()
}

/// What happened when a captured clip was handed to the store.
public enum CaptureOutcome: Sendable, Equatable {
    /// A new row was created.
    case inserted(ClipItem)
    /// The content was already in history; that row moved to the top.
    case promoted(ClipItem)
    /// Deliberately not stored (excluded app, concealed pasteboard type, empty content).
    case ignored(reason: IgnoreReason)
}

public enum IgnoreReason: String, Sendable, Equatable, Error {
    case excludedApp
    case concealedPasteboard
    case emptyContent
    case unsupportedType
    case ownPaste
    /// A two-factor setup or export link. These are seeds, not clips: they are offered to
    /// the helper for import and never written to history.
    case twoFactorSecret
}
