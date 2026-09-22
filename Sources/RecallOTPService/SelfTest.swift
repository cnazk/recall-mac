import Foundation
import RecallOTP

/// Proves the parts of the helper that only work when it is signed, sandboxed and run as
/// itself: the Keychain access group, the data-protection keychain, and code generation
/// end to end. Run from the built bundle, not from the test suite.
enum SelfTest {
    static func run() {
        let store = SeedStore()
        var failures = 0

        func check(_ name: String, _ body: () throws -> Void) {
            do {
                try body()
                print("  ok    \(name)")
            } catch {
                failures += 1
                print("  FAIL  \(name): \(error)")
            }
        }

        print("Recall two-factor helper self-test")
        print("  sandboxed: \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)")
        print("  storage:   \(SeedStore.storageDescription)")

        let account = OTPAccount(
            issuer: "SelfTest",
            account: "probe",
            secret: Data("12345678901234567890".utf8)
        )

        check("write a seed to the vault") {
            try store.add(account)
        }

        check("read it back") {
            let stored = try store.account(id: account.id)
            guard stored.secret == account.secret else {
                throw NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret did not round-trip"])
            }
        }

        check("generate the RFC 6238 code from it") {
            let code = OneTimePassword.totp(
                secret: try store.account(id: account.id).secret,
                at: Date(timeIntervalSince1970: 59),
                digits: 8
            )
            guard code == "94287082" else {
                throw NSError(domain: "SelfTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "got \(code)"])
            }
        }

        check("authentication defaults to every time") {
            let policy = store.authenticationPolicy()
            guard policy == .always else {
                throw NSError(
                    domain: "SelfTest",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "defaulted to \(policy.rawValue)"]
                )
            }
        }

        check("clean up") {
            try store.remove(id: account.id)
        }

        print(failures == 0 ? "PASS" : "FAIL (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
