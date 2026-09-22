import Foundation

/// How sensitive an item is judged to be, which decides whether it is persisted,
/// concealed in the UI, and when it self-destructs.
public enum Sensitivity: String, Codable, Sendable {
    /// Nothing special detected.
    case normal
    /// Matched a secret rule (2FA code, card number, API key …). Persisted only in memory
    /// and removed once ``ClipItem/expiresAt`` passes.
    case secret
    /// Came from an excluded app or a concealed pasteboard type: never stored at all.
    /// Present as a case so the capture pipeline can report *why* it dropped something.
    case excluded
}

/// The app a clip came from, resolved at capture time. Resolving later is unreliable —
/// the frontmost app has usually changed by then.
public struct SourceApp: Codable, Sendable, Hashable {
    public let bundleIdentifier: String?
    public let localizedName: String?
    public let processIdentifier: Int32?

    public init(bundleIdentifier: String?, localizedName: String?, processIdentifier: Int32? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.processIdentifier = processIdentifier
    }
}

/// Metadata fetched for a copied link: title, site name and favicon bytes.
public struct LinkMetadata: Codable, Sendable, Hashable {
    public var title: String?
    public var siteName: String?
    public var faviconData: Data?
    public var fetchedAt: Date?

    public init(title: String? = nil, siteName: String? = nil, faviconData: Data? = nil, fetchedAt: Date? = nil) {
        self.title = title
        self.siteName = siteName
        self.faviconData = faviconData
        self.fetchedAt = fetchedAt
    }
}

/// Everything the app knows about one entry in the clipboard history.
///
/// `id` identifies the row; ``contentHash`` identifies the *content* and is what
/// deduplication keys on — copying the same string twice promotes the existing row
/// instead of inserting a second one.
public struct ClipItem: Identifiable, Sendable, Hashable, Codable {
    public let id: UUID
    public var payload: ClipPayload
    public var contentHash: ContentHash
    public var source: SourceApp?
    public var createdAt: Date
    public var lastUsedAt: Date
    public var useCount: Int
    public var isPinned: Bool
    /// Position within the pinned group. Pins hold the place the user put them in, so
    /// they cannot be sorted by recency like the rest of history.
    public var pinOrder: Int?
    public var sensitivity: Sensitivity
    /// Set for secrets; the reaper deletes the item once this passes.
    public var expiresAt: Date?
    /// AI-assigned tags such as `code`, `receipt`, `link`.
    public var tags: Set<String>
    /// One-sentence AI preview for long text.
    public var summary: String?
    /// Text recognised inside a copied image.
    public var ocrText: String?
    public var link: LinkMetadata?
    /// Shortcode for snippet expansion, e.g. `:sig`.
    public var snippetCode: String?
    /// Identifiers of the secret rules that fired at capture, e.g. `otp`, `credit-card`.
    ///
    /// Kept so a warning can say *what* was detected. A caution the user cannot check is
    /// a caution they learn to ignore.
    public var detectedRules: [String]

    public var kind: ClipKind { payload.kind }

    public init(
        id: UUID = UUID(),
        payload: ClipPayload,
        contentHash: ContentHash,
        source: SourceApp? = nil,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil,
        useCount: Int = 0,
        isPinned: Bool = false,
        pinOrder: Int? = nil,
        sensitivity: Sensitivity = .normal,
        expiresAt: Date? = nil,
        tags: Set<String> = [],
        summary: String? = nil,
        ocrText: String? = nil,
        link: LinkMetadata? = nil,
        snippetCode: String? = nil,
        detectedRules: [String] = []
    ) {
        self.id = id
        self.payload = payload
        self.contentHash = contentHash
        self.source = source
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.useCount = useCount
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.sensitivity = sensitivity
        self.expiresAt = expiresAt
        self.tags = tags
        self.summary = summary
        self.ocrText = ocrText
        self.link = link
        self.snippetCode = snippetCode
        self.detectedRules = detectedRules
    }

    /// Text the search index should cover: the payload plus anything AI or OCR added.
    public var indexableText: String {
        [payload.searchableText, ocrText, summary, link?.title]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    /// The text this clip can be compared against another one with.
    ///
    /// Not ``indexableText``: that folds in the summary and a link's title so search can
    /// find a clip by them, and diffing those against each other would report changes to
    /// text nobody copied. A screenshot compares by what was read out of it, which makes
    /// two versions of the same document diffable even as pictures.
    ///
    /// `nil` for a clip with no text at all — an image with no recognised words, a colour
    /// is a value not a document — which is what ``isComparable`` answers.
    public var comparableText: String? {
        if let text = payload.searchableText, !text.isEmpty { return text }
        if let ocrText, !ocrText.isEmpty { return ocrText }
        return nil
    }

    /// Whether this clip can take part in a comparison.
    ///
    /// Secrets cannot: a diff would print the parts of a credential that did not change,
    /// which is most of it, in a window that is not treated as sensitive.
    public var isComparable: Bool {
        sensitivity != .secret && comparableText != nil
    }

    public func hasExpired(asOf now: Date = .now) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public extension ClipItem {
    /// Tolerant decoding: a row sealed before a field existed must still open, or one
    /// added property costs the user their history.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            payload: try container.decode(ClipPayload.self, forKey: .payload),
            contentHash: try container.decode(ContentHash.self, forKey: .contentHash),
            source: try container.decodeIfPresent(SourceApp.self, forKey: .source),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            lastUsedAt: try container.decodeIfPresent(Date.self, forKey: .lastUsedAt),
            useCount: try container.decodeIfPresent(Int.self, forKey: .useCount) ?? 0,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            pinOrder: try container.decodeIfPresent(Int.self, forKey: .pinOrder),
            sensitivity: try container.decodeIfPresent(Sensitivity.self, forKey: .sensitivity) ?? .normal,
            expiresAt: try container.decodeIfPresent(Date.self, forKey: .expiresAt),
            tags: try container.decodeIfPresent(Set<String>.self, forKey: .tags) ?? [],
            summary: try container.decodeIfPresent(String.self, forKey: .summary),
            ocrText: try container.decodeIfPresent(String.self, forKey: .ocrText),
            link: try container.decodeIfPresent(LinkMetadata.self, forKey: .link),
            snippetCode: try container.decodeIfPresent(String.self, forKey: .snippetCode),
            detectedRules: try container.decodeIfPresent([String].self, forKey: .detectedRules) ?? []
        )
    }
}
