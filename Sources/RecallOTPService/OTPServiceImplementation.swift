import Foundation
import OSLog
import RecallOTP

/// The helper's implementation of the protocol Recall talks to.
///
/// Everything sensitive happens on this side of the boundary: seeds are read, codes are
/// computed, and only the digits go back. A compromise of Recall itself yields, at most,
/// the codes the user asked for — never the seeds that mint them.
/// `@unchecked Sendable` because its only stored properties are a stateless store and a
/// logger; XPC calls arrive on arbitrary queues and each request is independent.
final class OTPServiceImplementation: NSObject, OTPServiceProtocol, @unchecked Sendable {
    private let store = SeedStore()
    private let log = Logger(subsystem: "com.recall.otp", category: "service")

    func listAccounts(reply: @escaping (Data?, String?) -> Void) {
        do {
            let summaries = try store.all().map(OTPAccountSummary.init)
            reply(try JSONEncoder().encode(summaries), nil)
        } catch {
            reply(nil, String(describing: error))
        }
    }

    func importAccounts(fromURI uri: String, reply: @escaping (Int, String?) -> Void) {
        do {
            let accounts: [OTPAccount]
            if GoogleAuthenticatorImport.isMigrationURI(uri) {
                accounts = try GoogleAuthenticatorImport.parse(uri)
            } else if OTPURI.isOTPURI(uri) {
                accounts = [try OTPURI.parse(uri)]
            } else {
                reply(0, "That is not a two-factor setup or export link.")
                return
            }

            for account in accounts {
                try store.add(account)
            }
            log.info("Imported \(accounts.count, privacy: .public) account(s)")
            reply(accounts.count, nil)
        } catch {
            reply(0, String(describing: error))
        }
    }

    func code(forAccountID id: String, reply: @escaping (String?, Int, String?) -> Void) {
        guard let uuid = UUID(uuidString: id) else {
            reply(nil, 0, "Unknown account.")
            return
        }

        // XPC reply blocks are not `Sendable` in the generated interface, but the runtime
        // guarantees each is called exactly once; the box carries it into the task.
        let reply = UncheckedSendableBox(reply)
        let store = store

        Task {
            do {
                let account = try store.account(id: uuid)
                try await store.authenticate(reason: "show the code for \(account.label)")

                let code = OneTimePassword.code(for: account)
                let remaining = account.kind == .totp
                    ? OneTimePassword.secondsRemaining(period: account.period)
                    : account.period

                // A counter-based code is single-use, so using it advances the counter.
                if account.kind == .hotp {
                    var advanced = account
                    advanced.counter += 1
                    try store.add(advanced)
                }

                reply.value(code, remaining, nil)
            } catch {
                reply.value(nil, 0, String(describing: error))
            }
        }
    }

    func removeAccount(id: String, reply: @escaping (String?) -> Void) {
        guard let uuid = UUID(uuidString: id) else {
            reply("Unknown account.")
            return
        }
        do {
            try store.remove(id: uuid)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func exportAccounts(reply: @escaping ([String]?, String?) -> Void) {
        let reply = UncheckedSendableBox(reply)

        Task {
            do {
                // Export is the one call that hands over secrets, so it authenticates
                // every time regardless of the biometrics setting.
                try await store.authenticate(reason: "export your two-factor accounts")
                reply.value(try store.all().map(OTPURI.string(for:)), nil)
            } catch {
                reply.value(nil, String(describing: error))
            }
        }
    }

    func setAuthenticationPolicy(_ rawValue: String, reply: @escaping (String?) -> Void) {
        guard let policy = OTPAuthenticationPolicy(rawValue: rawValue) else {
            reply("“\(rawValue)” is not an authentication policy.")
            return
        }
        do {
            try store.setAuthenticationPolicy(policy)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func authenticationPolicy(reply: @escaping (String) -> Void) {
        reply(store.authenticationPolicy().rawValue)
    }
}

/// Carries a non-`Sendable` XPC reply block into a task.
///
/// Safe because XPC calls each reply exactly once, from one place, and the value is never
/// read concurrently — but the compiler cannot see that through an `@objc` interface.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
