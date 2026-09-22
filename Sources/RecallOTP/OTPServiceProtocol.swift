import Foundation

/// What Recall may ask the seed helper to do.
///
/// Note what is *not* here: there is no way to read a secret back. The helper generates
/// codes and hands over six digits; the seeds never cross the boundary. Export is the one
/// exception, and it is gated on biometric authentication every time.
@objc public protocol OTPServiceProtocol {
    /// Accounts, as JSON-encoded ``OTPAccountSummary`` values — no secrets.
    func listAccounts(reply: @escaping (Data?, String?) -> Void)

    /// Adds accounts from an `otpauth://` or `otpauth-migration://` URI.
    /// Returns the number added.
    func importAccounts(fromURI uri: String, reply: @escaping (Int, String?) -> Void)

    /// The current code for an account, with the seconds left before it rotates.
    /// Requires biometric authentication when the helper is configured to demand it.
    func code(forAccountID id: String, reply: @escaping (String?, Int, String?) -> Void)

    func removeAccount(id: String, reply: @escaping (String?) -> Void)

    /// Every seed back out as `otpauth://` URIs. Always biometric-gated.
    func exportAccounts(reply: @escaping ([String]?, String?) -> Void)

    /// How often a code asks for authentication. Defaults to asking every time.
    ///
    /// The policy crosses as its `rawValue`; XPC carries property-list types only.
    func setAuthenticationPolicy(_ rawValue: String, reply: @escaping (String?) -> Void)
    func authenticationPolicy(reply: @escaping (String) -> Void)
}

/// What the app is allowed to know about an account: everything except the secret.
public struct OTPAccountSummary: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let issuer: String
    public let account: String
    public let digits: Int
    public let period: Int
    public let kind: OTPKind

    public init(id: UUID, issuer: String, account: String, digits: Int, period: Int, kind: OTPKind) {
        self.id = id
        self.issuer = issuer
        self.account = account
        self.digits = digits
        self.period = period
        self.kind = kind
    }

    public init(_ account: OTPAccount) {
        self.init(
            id: account.id,
            issuer: account.issuer,
            account: account.account,
            digits: account.digits,
            period: account.period,
            kind: account.kind
        )
    }

    public var label: String {
        issuer.isEmpty ? account : "\(issuer) (\(account))"
    }
}

public enum OTPService {
    /// The helper's bundle identifier, and the XPC service name.
    public static let bundleIdentifier = "com.recall.otp"

    /// The app's bundle identifier.
    public static let appBundleIdentifier = "com.recall.app"

    /// What the *app* demands of the helper before it will talk to it.
    public static func codeSigningRequirement(teamIdentifier: String?) -> String {
        requirement(identifier: bundleIdentifier, teamIdentifier: teamIdentifier)
    }

    /// What the *helper* demands of a caller before it will answer.
    ///
    /// A different identifier, and getting it wrong was not a small mistake: the helper
    /// demanded that its caller be `com.recall.otp` — itself — which no app can satisfy.
    /// Every connection was refused with `errSecCSReqFailed`, so two-factor never worked
    /// at all. The two requirements are named apart now so they cannot be mistaken for
    /// each other again.
    public static func callerCodeSigningRequirement(teamIdentifier: String?) -> String {
        requirement(identifier: appBundleIdentifier, teamIdentifier: teamIdentifier)
    }

    /// Ad-hoc signatures carry no team identifier, so development builds can only check
    /// the identifier. A Developer ID build tightens this to the team.
    private static func requirement(identifier: String, teamIdentifier: String?) -> String {
        guard let teamIdentifier, !teamIdentifier.isEmpty else {
            return "identifier \"\(identifier)\""
        }
        return """
        identifier "\(identifier)" and anchor apple generic and \
        certificate leaf[subject.OU] = "\(teamIdentifier)"
        """
    }
}
