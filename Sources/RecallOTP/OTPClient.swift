import Foundation

/// Recall's side of the connection to the seed helper.
///
/// Every method here returns codes or summaries. There is deliberately no call that
/// returns a secret, because the app has no business holding one.
public actor OTPClient {
    public enum Failure: Error, CustomStringConvertible {
        case unavailable(String)
        case service(String)

        public var description: String {
            switch self {
            case .unavailable(let detail): String(localized: "The two-factor helper is not available: \(detail)")
            case .service(let message): message
            }
        }
    }

    private var connection: NSXPCConnection?
    private let teamIdentifier: String?

    public init(teamIdentifier: String? = nil) {
        self.teamIdentifier = teamIdentifier
    }

    /// Makes one call to the helper, and resumes exactly once however it ends.
    ///
    /// The error handler used to be `{ _ in }`. XPC calls it *instead of* the reply block
    /// when a call cannot be delivered — a dropped connection, a code-signing mismatch, a
    /// helper that died — so an empty one meant the continuation was never resumed and
    /// the `await` hung forever. Every failure looked like a button that did nothing:
    /// no error, no log, no timeout, just a task parked for the life of the process.
    ///
    /// The reply and the error handler are both live at once, so the resume is guarded —
    /// resuming a checked continuation twice traps.
    private func call<T>(
        _ invoke: @escaping @Sendable (any OTPServiceProtocol, @escaping @Sendable (sending Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        do {
            return try await attempt(invoke)
        } catch let failure as Failure {
            // "Connection init failed at lookup" means launchd has no such service *yet*.
            // Replacing the app bundle unregisters the helper at its old path, and the
            // first call after an install can arrive before XPC has registered the new
            // one. One retry costs a fraction of a second and turns a scary permanent
            // error into nothing at all.
            guard case .unavailable = failure else { throw failure }
            clearConnection()
            try? await Task.sleep(for: .milliseconds(500))
            return try await attempt(invoke)
        }
    }

    private func attempt<T>(
        _ invoke: @escaping @Sendable (any OTPServiceProtocol, @escaping @Sendable (sending Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = liveConnection()

        return try await withCheckedThrowingContinuation { continuation in
            let resume = ResumeOnce(continuation)

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                resume.finish(.failure(Failure.unavailable(String(describing: error))))
            }
            guard let service = proxy as? any OTPServiceProtocol else {
                resume.finish(.failure(Failure.unavailable("the helper did not offer the expected interface")))
                return
            }
            invoke(service) { result in resume.finish(result) }
        }
    }

    private func liveConnection() -> NSXPCConnection {
        if let connection { return connection }

        let new = NSXPCConnection(serviceName: OTPService.bundleIdentifier)
        new.remoteObjectInterface = NSXPCInterface(with: OTPServiceProtocol.self)
        // The app refuses to talk to anything that is not the helper it shipped with.
        new.setCodeSigningRequirement(OTPService.codeSigningRequirement(teamIdentifier: teamIdentifier))
        new.invalidationHandler = { [weak self] in
            Task { await self?.clearConnection() }
        }
        new.interruptionHandler = { [weak self] in
            Task { await self?.clearConnection() }
        }
        new.resume()
        connection = new
        return new
    }

    private func clearConnection() {
        connection = nil
    }

    public func accounts() async throws -> [OTPAccountSummary] {
        let data: Data = try await call { service, finish in
            service.listAccounts { data, error in
                finish(error.map { .failure(Failure.service($0)) } ?? .success(data ?? Data()))
            }
        }
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([OTPAccountSummary].self, from: data)
    }

    /// - Returns: how many accounts were added.
    @discardableResult
    public func importAccounts(fromURI uri: String) async throws -> Int {
        try await call { service, finish in
            service.importAccounts(fromURI: uri) { count, error in
                finish(error.map { .failure(Failure.service($0)) } ?? .success(count))
            }
        }
    }

    /// The current code and the seconds left on it.
    public func code(for id: UUID) async throws -> (code: String, secondsRemaining: Int) {
        let reply: CodeReply = try await call { service, finish in
            service.code(forAccountID: id.uuidString) { code, remaining, error in
                if let error {
                    finish(.failure(Failure.service(error)))
                } else if let code {
                    finish(.success(CodeReply(code: code, secondsRemaining: remaining)))
                } else {
                    finish(.failure(Failure.service(String(localized: "No code was produced."))))
                }
            }
        }
        return (reply.code, reply.secondsRemaining)
    }

    /// A tuple is not `Sendable` enough to cross the call boundary; this is.
    private struct CodeReply: Sendable {
        let code: String
        let secondsRemaining: Int
    }

    public func remove(id: UUID) async throws {
        try await call { (service, finish: @escaping @Sendable (sending Result<Void, any Error>) -> Void) in
            service.removeAccount(id: id.uuidString) { error in
                finish(error.map { .failure(Failure.service($0)) } ?? .success(()))
            }
        }
    }

    public func exportURIs() async throws -> [String] {
        try await call { service, finish in
            service.exportAccounts { uris, error in
                finish(error.map { .failure(Failure.service($0)) } ?? .success(uris ?? []))
            }
        }
    }

    public func setAuthenticationPolicy(_ policy: OTPAuthenticationPolicy) async throws {
        let rawValue = policy.rawValue
        try await call { (service, finish: @escaping @Sendable (sending Result<Void, any Error>) -> Void) in
            service.setAuthenticationPolicy(rawValue) { error in
                finish(error.map { .failure(Failure.service($0)) } ?? .success(()))
            }
        }
    }

    public func authenticationPolicy() async throws -> OTPAuthenticationPolicy {
        let rawValue: String = try await call { service, finish in
            service.authenticationPolicy { finish(.success($0)) }
        }
        // An unreadable answer means asking every time, never skipping.
        return OTPAuthenticationPolicy(rawValue: rawValue) ?? .default
    }

    /// Guards a continuation so it is resumed exactly once.
    ///
    /// The reply block and the error handler are both armed for the same call, and
    /// resuming a checked continuation twice is a runtime trap.
    private final class ResumeOnce<T>: @unchecked Sendable {
        private let continuation: CheckedContinuation<T, any Error>
        private let lock = NSLock()
        private var isDone = false

        init(_ continuation: CheckedContinuation<T, any Error>) {
            self.continuation = continuation
        }

        func finish(_ result: sending Result<T, any Error>) {
            lock.lock()
            let shouldResume = !isDone
            isDone = true
            lock.unlock()

            guard shouldResume else { return }
            continuation.resume(with: result)
        }
    }
}
