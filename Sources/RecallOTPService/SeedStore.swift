import CryptoKit
import Foundation
import LocalAuthentication
import RecallOTP
import Security

/// Holds the 2FA seeds, in this process and nowhere else.
///
/// Sealed in a file inside the helper's own sandbox container, rather than in the
/// Keychain. The Keychain was the obvious home and it does not work here:
///
/// - The **data-protection keychain** decides access by entitlement, which is exactly
///   what a helper like this wants. It needs `keychain-access-groups`, which needs a real
///   team identifier, which an ad-hoc development build does not have. It answers
///   `errSecMissingEntitlement`.
/// - The **file keychain** decides access by an ACL tied to the calling code's signature.
///   The helper's signature changes with every build, so the ACL never matches and the
///   Keychain wants to ask the user. An XPC service has no UI to ask with, so the call
///   fails with `errSecInteractionNotAllowed` — which is what made two-factor
///   unusable. It only ever worked when the helper was run by hand from a terminal,
///   which is why `--selftest` passed while the real thing did not.
///
/// So: AES-GCM over the whole document, with the key in a sibling file. What protects it
/// is the sandbox container plus POSIX permissions — the directory is `0700` and both
/// files `0600`, and no other sandboxed application can reach into this container. That
/// is weaker than a data-protection keychain item and stronger than plaintext, and it is
/// the best available without a signing identity. Once Recall has one (Phase 7), the
/// data-protection keychain becomes available and ``migrateIfNeeded()`` is where the move
/// back belongs.
struct SeedStore {
    enum Failure: Error, CustomStringConvertible {
        case notFound
        case biometricsFailed(String)
        case vault(String)

        var description: String {
            switch self {
            case .notFound:
                String(localized: "That account is no longer stored.")
            case .biometricsFailed(let reason):
                reason
            case .vault(let detail):
                String(localized: "The two-factor store could not be read: \(detail)")
            }
        }
    }

    /// Everything the helper persists, as one document.
    ///
    /// One file rather than an item per account: the whole thing is rewritten on every
    /// change, which for a handful of accounts costs nothing and removes any chance of a
    /// half-written set.
    private struct Vault: Codable {
        var accounts: [OTPAccount] = []
        /// Authentication is **required by default**: the safe answer is the one a user
        /// who never opens settings gets.
        var policy: OTPAuthenticationPolicy?
        /// What the policy used to be, before there were three of them. Read once so an
        /// existing vault keeps the choice its owner made, then left alone.
        var requiresBiometrics: Bool?

        var resolvedPolicy: OTPAuthenticationPolicy {
            if let policy { return policy }
            if requiresBiometrics == false { return .never }
            return .default
        }
    }

    /// When authentication last succeeded, for ``OTPAuthenticationPolicy/afterGrace``.
    ///
    /// Deliberately in memory and not in the vault: a grace period that survived a
    /// restart would be a grace period nobody chose. `SeedStore` is a struct created per
    /// call, so the clock has to live outside it — there is one helper process, and this
    /// is its one clock.
    private final class AuthenticationClock: @unchecked Sendable {
        static let shared = AuthenticationClock()
        private let lock = NSLock()
        private var lastSucceeded: Date?

        var last: Date? {
            lock.lock(); defer { lock.unlock() }
            return lastSucceeded
        }

        func recordSuccess(at date: Date = .now) {
            lock.lock(); lastSucceeded = date; lock.unlock()
        }

        /// Forgets the grace period — used when the policy changes, so tightening it
        /// takes effect at once rather than after the old window runs out.
        func reset() {
            lock.lock(); lastSucceeded = nil; lock.unlock()
        }
    }

    // MARK: - Accounts

    func add(_ account: OTPAccount) throws {
        try mutate { vault in
            vault.accounts.removeAll { $0.id == account.id }
            vault.accounts.append(account)
        }
    }

    func all() throws -> [OTPAccount] {
        try load().accounts
    }

    func account(id: UUID) throws -> OTPAccount {
        guard let match = try all().first(where: { $0.id == id }) else { throw Failure.notFound }
        return match
    }

    func remove(id: UUID) throws {
        try mutate { vault in
            vault.accounts.removeAll { $0.id == id }
        }
    }

    // MARK: - Settings

    func authenticationPolicy() -> OTPAuthenticationPolicy {
        // A store that cannot be read must not answer "no authentication needed".
        (try? load().resolvedPolicy) ?? .default
    }

    func setAuthenticationPolicy(_ policy: OTPAuthenticationPolicy) throws {
        try mutate {
            $0.policy = policy
            $0.requiresBiometrics = nil
        }
        // Changing the rules restarts the clock, so a shortened grace period does not
        // keep honouring the longer one it replaced.
        AuthenticationClock.shared.reset()
    }

    // MARK: - Biometrics

    /// Asks for Touch ID (falling back to the login password) before handing over a code.
    func authenticate(reason: String) async throws {
        let policy = authenticationPolicy()
        guard !policy.allowsWithoutAuthenticating(lastAuthenticated: AuthenticationClock.shared.last) else {
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        // `deviceOwnerAuthentication` rather than `…WithBiometrics`: a Mac without Touch
        // ID should ask for the login password, not refuse outright.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw Failure.biometricsFailed(error?.localizedDescription ?? "Authentication is unavailable.")
        }

        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            AuthenticationClock.shared.recordSuccess()
        } catch {
            throw Failure.biometricsFailed(error.localizedDescription)
        }
    }

    // MARK: - Storage

    private func mutate(_ change: (inout Vault) throws -> Void) throws {
        var vault = try load()
        try change(&vault)
        try save(vault)
    }

    private func load() throws -> Vault {
        let url = try Self.vaultURL()
        guard let sealed = try? Data(contentsOf: url) else {
            // No vault yet. Anything a previous build left in the Keychain comes across
            // now, if it can still be read.
            let migrated = Self.migrateIfNeeded()
            if !migrated.accounts.isEmpty { try save(migrated) }
            return migrated
        }

        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            let plaintext = try AES.GCM.open(box, using: try Self.key())
            return try JSONDecoder().decode(Vault.self, from: plaintext)
        } catch {
            throw Failure.vault(String(describing: error))
        }
    }

    private func save(_ vault: Vault) throws {
        do {
            let plaintext = try JSONEncoder().encode(vault)
            let sealed = try AES.GCM.seal(plaintext, using: try Self.key()).combined ?? Data()
            let url = try Self.vaultURL()
            try sealed.write(to: url, options: [.atomic])
            try Self.restrict(url)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.vault(String(describing: error))
        }
    }

    /// The helper's own Application Support directory. Inside the sandbox this resolves
    /// into the container, which is the whole point.
    private static func directory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("TwoFactor", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func vaultURL() throws -> URL {
        try directory().appendingPathComponent("seeds.dat")
    }

    /// The key, generated once and kept beside the vault.
    ///
    /// A key next to the thing it encrypts is not a secret from anyone who can read the
    /// directory — it is protection against everything that cannot, which inside a sandbox
    /// container is every other application on the machine.
    private static func key() throws -> SymmetricKey {
        let url = try directory().appendingPathComponent("vault.key")

        if let existing = try? Data(contentsOf: url), existing.count == 32 {
            return SymmetricKey(data: existing)
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.vault("could not generate a key")
        }
        let data = Data(bytes)
        do {
            try data.write(to: url, options: [.atomic])
            try restrict(url)
        } catch {
            throw Failure.vault("could not store the key: \(error)")
        }
        return SymmetricKey(data: data)
    }

    /// `.atomic` writes through a temporary file, which does not inherit the directory's
    /// permissions — so the mode is set afterwards, every time.
    private static func restrict(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads anything an earlier build stored in the Keychain, and clears it out.
    ///
    /// Best effort by design: the usual reason there is nothing to migrate is that the
    /// Keychain refuses to talk to this process at all, which is the bug that prompted
    /// the move. A failure here must not stop the helper starting.
    private static func migrateIfNeeded() -> Vault {
        var vault = Vault()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.recall.otp.seeds",
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let entries = items as? [[String: Any]]
        else { return vault }

        let decoder = JSONDecoder()
        for entry in entries {
            guard let data = entry[kSecValueData as String] as? Data,
                  let account = try? decoder.decode(OTPAccount.self, from: data)
            else { continue }
            vault.accounts.append(account)
        }

        if !vault.accounts.isEmpty {
            SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.recall.otp.seeds",
            ] as CFDictionary)
        }
        return vault
    }

    /// Where this build keeps its seeds, for the self-test to report.
    static var storageDescription: String {
        (try? directory().path) ?? "unavailable"
    }
}
