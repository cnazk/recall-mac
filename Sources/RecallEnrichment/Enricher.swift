import Foundation
import RecallCore

/// A post-capture step that adds metadata to an item.
///
/// Enrichment runs off the capture path: capture must stay fast and must never block on
/// the network or on Vision. Each enricher returns an updated item, or nil when it has
/// nothing to add.
public protocol Enricher: Sendable {
    var identifier: String { get }
    func canEnrich(_ item: ClipItem) -> Bool
    func enrich(_ item: ClipItem) async throws -> ClipItem?
}

/// The identifiers of the enrichers Recall ships.
///
/// Named in one place because the settings that switch them off live somewhere else
/// entirely, and matching identifiers by hand-written string in two files is how a
/// preference quietly stops working.
public enum EnricherID {
    public static let link = "link-metadata"
    public static let imageText = "image-ocr"
}

/// Runs the registered enrichers in order, feeding each one the previous result.
public struct EnrichmentPipeline: Sendable {
    private let enrichers: [any Enricher]

    public init(enrichers: [any Enricher]) {
        self.enrichers = enrichers
    }

    /// - Parameter disabled: identifiers to skip, from the user's settings. Checked here
    ///   rather than inside an enricher so that turning a preference off takes effect on
    ///   the next capture, not on the next launch.
    public func enrich(_ item: ClipItem, disabled: Set<String> = []) async -> ClipItem {
        var current = item
        for enricher in enrichers where !disabled.contains(enricher.identifier) && enricher.canEnrich(current) {
            do {
                if let updated = try await enricher.enrich(current) {
                    current = updated
                }
            } catch {
                Log.capture.error("Enricher \(enricher.identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return current
    }
}
