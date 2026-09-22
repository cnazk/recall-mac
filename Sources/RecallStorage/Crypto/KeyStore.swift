import CryptoKit
import Foundation
import RecallCore
import Security

/// Supplies the symmetric key the history database is sealed with.
///
/// The protocol exists so nothing in the test suite ever touches the real Keychain:
/// tests use ``EphemeralKeyStore``, the app uses ``KeychainKeyStore``.
public protocol KeyStoring: Sendable {
    /// Returns the existing key, creating one on first use.
    func key() throws -> SymmetricKey
}

public enum KeyStoreError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case unexpectedKeySize(Int)
    case timedOut

    public var description: String {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
            return "keychain error \(status): \(message)"
        case .unexpectedKeySize(let size):
            return "stored key has the wrong size (\(size) bytes)"
        case .timedOut:
            return """
            Recall is waiting for permission to use the encryption key in your keychain. \
            Approve the dialog macOS is showing (choose "Always Allow"), then reopen \
            Recall. This happens after a rebuild, because the key is tied to the app's \
            code signature.
            """
        }
    }
}

/// The real key store: a 256-bit key in the login Keychain.
///
/// `ThisDeviceOnly` keeps the key out of iCloud Keychain and out of encrypted backups —
/// a clipboard history that silently syncs its key to another Mac is not what anyone
/// means by local-first.
public struct KeychainKeyStore: KeyStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.recall.app", account: String = "history-encryption-key") {
        self.service = service
        self.account = account
    }

    /// How long to wait on the Keychain before giving up.
    ///
    /// A rebuilt binary has a new signature, so the legacy keychain shows an ACL dialog
    /// that can sit unanswered indefinitely. Hanging there forever is not an option: the
    /// app must be able to say what it is waiting for.
    public static let timeout: TimeInterval = 20

    public func key() throws -> SymmetricKey {
        // The data-protection keychain is tried first: access there is decided by the
        // app's signature and entitlements, with no interactive ACL prompt. The legacy
        // file keychain prompts whenever the calling binary's signature changes — which
        // is every rebuild during development, and that prompt blocks an agent app that
        // has no window to show it in.
        for useDataProtection in [true, false] {
            if let existing = try load(useDataProtection: useDataProtection) {
                return existing
            }
        }

        let fresh = SymmetricKey(size: .bits256)
        do {
            try store(fresh, useDataProtection: true)
        } catch {
            try store(fresh, useDataProtection: false)
        }
        return fresh
    }

    /// Removes the key, which makes every sealed row permanently unreadable.
    /// This *is* the implementation of "erase my history irrecoverably".
    public func destroy() throws {
        for useDataProtection in [true, false] {
            let status = SecItemDelete(baseQuery(useDataProtection: useDataProtection) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound
                    || status == errSecMissingEntitlement || status == errSecParam else {
                throw KeyStoreError.keychain(status)
            }
        }
    }

    private func baseQuery(useDataProtection: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func load(useDataProtection: Bool) throws -> SymmetricKey? {
        var query = baseQuery(useDataProtection: useDataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            guard data.count == 32 else { throw KeyStoreError.unexpectedKeySize(data.count) }
            return SymmetricKey(data: data)
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement, errSecNoSuchKeychain, errSecParam:
            // This keychain is not usable by this build; let the caller try the other.
            return nil
        default:
            throw KeyStoreError.keychain(status)
        }
    }

    private func store(_ key: SymmetricKey, useDataProtection: Bool) throws {
        var query = baseQuery(useDataProtection: useDataProtection)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status) }
    }
}

/// A key that exists only for the lifetime of the process.
///
/// Used by the tests, and by In-Memory Mode's temporary database if it ever needs one.
public struct EphemeralKeyStore: KeyStoring {
    private let value: SymmetricKey

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.value = key
    }

    public func key() throws -> SymmetricKey { value }
}
