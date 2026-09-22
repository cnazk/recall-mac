import Foundation

/// The fields the background pass is allowed to change.
///
/// Enrichment reads a clip at capture, then goes away for as long as a page fetch, an OCR
/// pass and two model calls take — seconds, sometimes the better part of a minute. Writing
/// the whole item back at the end of that means writing a snapshot of *everything* as it
/// was before, and whatever the user did in between is undone: a pin cleared, a shortcode
/// erased, a reorder lost.
///
/// So the pass hands back only what it produced, and the store merges it onto the row as
/// it stands now. Nothing here is something the user can set by hand, which is the test
/// for whether a field belongs in this type.
public struct ClipEnrichment: Sendable, Equatable {
    public var summary: String?
    public var ocrText: String?
    public var link: LinkMetadata?
    public var tags: Set<String>

    public init(summary: String? = nil, ocrText: String? = nil, link: LinkMetadata? = nil, tags: Set<String> = []) {
        self.summary = summary
        self.ocrText = ocrText
        self.link = link
        self.tags = tags
    }

    /// Lifts the enrichment out of an item the pipeline has finished with.
    public init(of item: ClipItem) {
        self.init(summary: item.summary, ocrText: item.ocrText, link: item.link, tags: item.tags)
    }

    /// Merges onto the row as it stands now.
    ///
    /// Each field only fills a gap, rather than overwriting: OCR text the user has since
    /// corrected, or a link title already fetched, is better than a second opinion arriving
    /// late. Tags are unioned for the same reason — the pass adds what it found without
    /// removing anything already there.
    public func applied(to item: ClipItem) -> ClipItem {
        var merged = item
        merged.summary = item.summary ?? summary
        merged.ocrText = item.ocrText ?? ocrText
        merged.link = item.link ?? link
        merged.tags.formUnion(tags)
        return merged
    }

    public var isEmpty: Bool {
        summary == nil && ocrText == nil && link == nil && tags.isEmpty
    }
}
