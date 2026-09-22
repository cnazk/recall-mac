import AppKit
import Foundation
import RecallCore

/// Fetches the title, site name and favicon for a copied link.
///
/// This is the one part of the app that touches the network, and only for URLs the user
/// copied themselves. It is a setting (`enrichLinks`) precisely because some users want
/// a clipboard manager that makes no requests at all.
public struct LinkEnricher: Enricher {
    public let identifier = EnricherID.link
    private let session: URLSession
    private let byteLimit: Int

    public init(session: URLSession? = nil, byteLimit: Int = 256 * 1024) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 8
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: configuration)
        }
        self.byteLimit = byteLimit
    }

    public func canEnrich(_ item: ClipItem) -> Bool {
        guard case .url(let url) = item.payload else { return false }
        guard item.link?.fetchedAt == nil else { return false }
        return url.scheme == "http" || url.scheme == "https"
    }

    public func enrich(_ item: ClipItem) async throws -> ClipItem? {
        guard case .url(let url) = item.payload else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Recall/1.0 (+clipboard preview)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let html = String(decoding: data.prefix(byteLimit), as: UTF8.self)
        // Redirects are followed by the session, so the page that answered is the one to
        // resolve a relative icon path against.
        let resolved = response.url ?? url

        var metadata = LinkMetadata(fetchedAt: .now)
        metadata.title = Self.firstMatch(in: html, pattern: "<meta[^>]+property=[\"']og:title[\"'][^>]+content=[\"']([^\"']+)")
            ?? Self.firstMatch(in: html, pattern: "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:title[\"']")
            ?? Self.firstMatch(in: html, pattern: "<title[^>]*>([^<]{1,300})</title>")
        metadata.siteName = Self.firstMatch(in: html, pattern: "<meta[^>]+property=[\"']og:site_name[\"'][^>]+content=[\"']([^\"']+)")
            ?? url.host

        metadata.faviconData = await favicon(for: resolved, html: html)

        var updated = item
        updated.link = metadata
        return updated
    }

    /// The first candidate that answers with something that is actually an image.
    private func favicon(for url: URL, html: String) async -> Data? {
        for candidate in Self.faviconCandidates(for: url, html: html) {
            guard let (data, response) = try? await session.data(from: candidate),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count < 128 * 1024, !data.isEmpty
            else { continue }
            // A site with no icon often answers `/favicon.ico` with its 200-status HTML
            // error page. Stored unchecked, that is a "favicon" that draws nothing and
            // never retries, so the row shows the generic link glyph forever.
            guard NSImage(data: data) != nil else { continue }
            return data
        }
        return nil
    }

    /// Where to look for an icon, best first.
    ///
    /// `/favicon.ico` alone was the whole strategy, and it is only a fallback in the
    /// spec — plenty of sites declare their icon in the markup and serve nothing at the
    /// root. The declared ones go first, in document order, and the root is tried last.
    static func faviconCandidates(for url: URL, html: String) -> [URL] {
        var candidates: [URL] = []
        var seen = Set<String>()

        func add(_ candidate: URL?) {
            guard let candidate, seen.insert(candidate.absoluteString).inserted else { return }
            candidates.append(candidate)
        }

        for href in declaredIconHrefs(in: html) {
            add(URL(string: href, relativeTo: url)?.absoluteURL)
        }

        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.path = "/favicon.ico"
            components.query = nil
            components.fragment = nil
            add(components.url)
        }
        return candidates
    }

    /// `href`s of every `<link>` whose `rel` mentions an icon, in document order.
    ///
    /// Matched in two passes rather than one pattern, because `rel` and `href` appear in
    /// either order and a single regular expression for both is unreadable and wrong more
    /// often than it is right.
    static func declaredIconHrefs(in html: String) -> [String] {
        guard let tags = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)

        return tags.matches(in: html, options: [], range: range).compactMap { match -> String? in
            guard let tagRange = Range(match.range, in: html) else { return nil }
            let tag = String(html[tagRange])

            guard let rel = firstMatch(in: tag, pattern: "rel=[\"']([^\"']+)[\"']"),
                  rel.lowercased().split(separator: " ").contains(where: { $0.contains("icon") })
            else { return nil }
            // `mask-icon` is a monochrome Safari template, not something to draw in a row.
            guard !rel.lowercased().contains("mask-icon") else { return nil }

            return firstMatch(in: tag, pattern: "href=[\"']([^\"']+)[\"']")
        }
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
