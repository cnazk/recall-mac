import Foundation
import RecallCore

/// An on-device language model.
///
/// There is deliberately no remote implementation of this protocol. If the on-device
/// model is unavailable, the affected features are hidden — they are never quietly
/// served from a server.
public protocol LanguageModelProviding: Sendable {
    var isAvailable: Bool { get }
    /// - Parameter instructions: the system-level framing for the request.
    func respond(to prompt: String, instructions: String) async throws -> String

    /// Incremental output, for transforms the user is watching.
    ///
    /// Each element is the *whole* response so far, not a delta, which is what the UI
    /// wants to render and what the underlying framework produces.
    func stream(prompt: String, instructions: String) -> AsyncThrowingStream<String, any Error>
}

public extension LanguageModelProviding {
    /// Providers that cannot stream still satisfy the protocol: one element, at the end.
    func stream(prompt: String, instructions: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await respond(to: prompt, instructions: instructions))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

public enum LanguageModelUnavailable: Error, CustomStringConvertible {
    case notSupportedOnThisMac
    case appleIntelligenceDisabled
    case modelNotReady

    public var description: String {
        switch self {
        case .notSupportedOnThisMac: String(localized: "This Mac does not support on-device language models.")
        case .appleIntelligenceDisabled: String(localized: "Turn on Apple Intelligence in System Settings to use AI actions.")
        case .modelNotReady: String(localized: "The on-device model is still downloading.")
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// Apple's on-device model, via the Foundation Models framework.
@available(macOS 26.0, *)
public struct SystemLanguageModelProvider: LanguageModelProviding {
    public init() {}

    public var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    public func respond(to prompt: String, instructions: String) async throws -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw LanguageModelUnavailable.notSupportedOnThisMac
        case .unavailable(.appleIntelligenceNotEnabled):
            throw LanguageModelUnavailable.appleIntelligenceDisabled
        case .unavailable:
            throw LanguageModelUnavailable.modelNotReady
        @unknown default:
            throw LanguageModelUnavailable.modelNotReady
        }

        // A fresh session per request: clipboard items are unrelated to each other, and
        // carrying context between them would leak one clip's content into another's result.
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt).content
    }

    public func stream(prompt: String, instructions: String) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard isAvailable else {
                    continuation.finish(throwing: LanguageModelUnavailable.notSupportedOnThisMac)
                    return
                }
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
#endif

/// Stands in when no model is available, and in tests.
public struct UnavailableLanguageModel: LanguageModelProviding {
    public init() {}
    public var isAvailable: Bool { false }
    public func respond(to prompt: String, instructions: String) async throws -> String {
        throw LanguageModelUnavailable.notSupportedOnThisMac
    }
}

public enum LanguageModelFactory {
    /// The best provider this Mac can offer.
    public static func makeDefault() -> any LanguageModelProviding {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let provider = SystemLanguageModelProvider()
            if provider.isAvailable { return provider }
        }
        #endif
        return UnavailableLanguageModel()
    }
}
