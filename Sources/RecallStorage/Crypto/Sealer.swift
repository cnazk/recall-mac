import CryptoKit
import Foundation
import RecallCore

/// Seals and opens the bytes that go into the database.
///
/// AES-GCM, so every row is authenticated as well as encrypted: a tampered database
/// fails to open rather than yielding altered clipboard content.
public struct Sealer: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case corruptedRecord

        public var description: String {
            "a history row could not be decrypted — the database or the key has changed"
        }
    }

    private let key: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
    }

    public init(keyStore: any KeyStoring) throws {
        self.key = try keyStore.key()
    }

    public func seal(_ data: Data) throws -> Data {
        // `combined` is nonce ‖ ciphertext ‖ tag — one blob, no separate nonce column.
        guard let sealed = try AES.GCM.seal(data, using: key).combined else {
            throw Failure.corruptedRecord
        }
        return sealed
    }

    public func open(_ data: Data) throws -> Data {
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
        } catch {
            throw Failure.corruptedRecord
        }
    }

    /// A keyed digest for values that must stay queryable, such as the dedup hash.
    ///
    /// Storing the bare SHA-256 of the content would let anyone holding the file confirm
    /// a guess — "did they copy *this* string?" — without breaking the encryption at all.
    /// HMAC under the database key removes that, and still compares equal for equal
    /// content, which is all deduplication needs.
    public func blindIndex(_ value: String) -> String {
        var hmac = HMAC<SHA256>(key: key)
        hmac.update(data: Data(value.utf8))
        return hmac.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
