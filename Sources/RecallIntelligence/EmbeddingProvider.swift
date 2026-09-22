import Foundation
import NaturalLanguage
import RecallCore

/// Produces a vector for a piece of text, on device.
///
/// Every implementation must run locally — there is no network-backed provider, by design.
public protocol EmbeddingProvider: Sendable {
    /// Identifies the model that produced a vector, so vectors from an old model can be
    /// discarded rather than silently compared against new ones.
    var modelIdentifier: String { get }
    var dimensions: Int { get }
    func embed(_ text: String) throws -> [Float]
}

/// Embeddings from Apple's built-in sentence embedding model.
///
/// This is the zero-setup default: no model to download, available offline, and good
/// enough for "find the CSS snippet I copied". A Core ML text encoder can be swapped in
/// behind the same protocol when quality matters more than footprint.
/// `NLEmbedding` is not `Sendable`, so the model is kept behind a lock and never handed
/// out. Embedding is CPU-bound and short; contention here is not a concern in practice.
public final class NLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    public enum Failure: Error {
        case modelUnavailable(String)
        case textNotEmbeddable
    }

    private let embedding: NLEmbedding
    private let lock = NSLock()
    public let modelIdentifier: String

    public init(language: NLLanguage = .english) throws {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            throw Failure.modelUnavailable(language.rawValue)
        }
        self.embedding = embedding
        self.modelIdentifier = "nl.sentence.\(language.rawValue).v1"
    }

    public var dimensions: Int { embedding.dimension }

    public func embed(_ text: String) throws -> [Float] {
        // The sentence model has an input ceiling; clipping beats failing on long clips.
        let clipped = String(text.prefix(2_000))
        lock.lock()
        defer { lock.unlock() }
        guard let vector = embedding.vector(for: clipped) else {
            throw Failure.textNotEmbeddable
        }
        return Vector.normalized(vector.map(Float.init))
    }
}

public enum Vector {
    /// Unit-normalises so cosine similarity is a plain dot product.
    public static func normalized(_ vector: [Float]) -> [Float] {
        let magnitude = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return vector }
        return vector.map { $0 / magnitude }
    }

    /// Cosine similarity of two unit vectors.
    public static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return 0 }
        return zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
