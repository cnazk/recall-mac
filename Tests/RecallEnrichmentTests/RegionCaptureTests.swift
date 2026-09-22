import Foundation
import Testing
@testable import RecallCore
@testable import RecallEnrichment

@Suite("Region capture")
struct RegionCaptureTests {
    /// `screencapture` exits 0 and writes nothing when the user presses Escape, so a
    /// stand-in that does the same drives the cancel path exactly.
    @Test("Pressing Escape leaves nothing behind")
    func cancellingCapturesNothing() async {
        let capture = RegionCapture(executable: URL(fileURLWithPath: "/usr/bin/true"))
        await #expect(throws: RegionCapture.Failure.self) {
            _ = try await capture.captureRegion()
        }
    }

    @Test("A failing capture reports the exit code rather than hanging")
    func reportsFailure() async {
        let capture = RegionCapture(executable: URL(fileURLWithPath: "/usr/bin/false"))
        await #expect(throws: RegionCapture.Failure.self) {
            _ = try await capture.captureRegion()
        }
    }
}

@Suite("Link metadata parsing")
struct LinkEnricherParsingTests {
    @Test("Prefers the Open Graph title")
    func prefersOpenGraph() {
        let html = """
        <html><head><title>Fallback</title>
        <meta property="og:title" content="The Real Title">
        </head></html>
        """
        #expect(LinkEnricher.firstMatch(in: html, pattern: "<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)") == "The Real Title")
    }

    @Test("Falls back to the document title and decodes entities")
    func fallsBackToTitle() {
        let html = "<html><head><title>Tom &amp; Jerry</title></head></html>"
        #expect(LinkEnricher.firstMatch(in: html, pattern: "<title[^>]*>([^<]{1,300})</title>") == "Tom & Jerry")
    }

    @Test("Returns nothing rather than guessing when there is no title")
    func handlesMissingTitle() {
        #expect(LinkEnricher.firstMatch(in: "<html></html>", pattern: "<title[^>]*>([^<]{1,300})</title>") == nil)
    }
}

@Suite("Favicon discovery")
struct FaviconTests {
    private let page = URL(string: "https://example.com/docs/page?q=1#top")!

    /// `/favicon.ico` was the only place this ever looked, and in the spec it is the
    /// fallback — plenty of sites declare an icon in the markup and serve nothing at the
    /// root, which showed as the generic link glyph.
    @Test("A declared icon is preferred over the root fallback")
    func prefersDeclaredIcon() {
        let html = #"<link rel="icon" href="/assets/icon.png">"#
        let candidates = LinkEnricher.faviconCandidates(for: page, html: html)
        #expect(candidates.first?.absoluteString == "https://example.com/assets/icon.png")
    }

    /// The query and fragment of the page must not survive into the icon's URL.
    @Test("The root fallback is always offered, and is clean")
    func alwaysOffersTheRoot() {
        let candidates = LinkEnricher.faviconCandidates(for: page, html: "")
        #expect(candidates.map(\.absoluteString) == ["https://example.com/favicon.ico"])
    }

    @Test("A relative href resolves against the page, not the site root")
    func resolvesRelativeHrefs() {
        let html = #"<link rel="icon" href="icon.png">"#
        let candidates = LinkEnricher.faviconCandidates(for: page, html: html)
        #expect(candidates.first?.absoluteString == "https://example.com/docs/icon.png")
    }

    @Test("The same icon declared twice is only fetched once")
    func deduplicates() {
        let html = #"<link rel="icon" href="/i.png"><link rel="shortcut icon" href="/i.png">"#
        let candidates = LinkEnricher.faviconCandidates(for: page, html: html)
        #expect(candidates.count == 2, "the declared icon plus the root fallback")
    }

    @Test("Attributes are read in either order", arguments: [
        #"<link rel="icon" href="/a.png">"#,
        #"<link href="/a.png" rel="icon">"#,
        #"<link REL='ICON' HREF='/a.png'>"#,
    ])
    func readsEitherAttributeOrder(html: String) {
        #expect(LinkEnricher.declaredIconHrefs(in: html) == ["/a.png"])
    }

    @Test("Icon-ish rels count, other links do not")
    func matchesOnlyIconRels() {
        let html = """
        <link rel="stylesheet" href="/site.css">
        <link rel="apple-touch-icon" href="/touch.png">
        <link rel="canonical" href="https://example.com/">
        """
        #expect(LinkEnricher.declaredIconHrefs(in: html) == ["/touch.png"])
    }

    /// A Safari pinned-tab icon is a monochrome template. Drawn in a row it is a black
    /// silhouette, which looks like a rendering bug.
    @Test("A Safari mask icon is not treated as a favicon")
    func ignoresMaskIcons() {
        let html = ##"<link rel="mask-icon" href="/pinned.svg" color="#000">"##
        #expect(LinkEnricher.declaredIconHrefs(in: html).isEmpty)
    }
}

@Suite("Enrichment pipeline")
struct EnrichmentPipelineTests {
    private struct Marker: Enricher {
        let identifier: String
        func canEnrich(_ item: ClipItem) -> Bool { true }
        func enrich(_ item: ClipItem) async throws -> ClipItem? {
            var updated = item
            updated.tags.insert(identifier)
            return updated
        }
    }

    private var item: ClipItem {
        ClipItem(payload: .text("x"), contentHash: ContentHash(.text("x")), createdAt: .now)
    }

    /// The bug this exists for: "Fetch titles and icons for copied links" was wired to
    /// nothing, so the network request went out whatever the user had chosen.
    @Test("A disabled enricher does not run")
    func skipsDisabled() async {
        let pipeline = EnrichmentPipeline(enrichers: [Marker(identifier: "a"), Marker(identifier: "b")])
        let result = await pipeline.enrich(item, disabled: ["a"])
        #expect(result.tags == ["b"])
    }

    @Test("Everything runs when nothing is disabled")
    func runsAllByDefault() async {
        let pipeline = EnrichmentPipeline(enrichers: [Marker(identifier: "a"), Marker(identifier: "b")])
        #expect(await pipeline.enrich(item).tags == ["a", "b"])
    }
}
