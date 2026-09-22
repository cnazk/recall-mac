import Foundation

/// How often the helper asks for Touch ID before handing over a code.
///
/// The choice lives in the helper, not in Recall's settings, for the same reason the old
/// on/off switch did: a security default the app could flip on its own is not a default.
public enum OTPAuthenticationPolicy: Equatable, Sendable, Codable {
    /// Every code, every time.
    case always
    /// Once, then not again until `minutes` have passed without authenticating.
    ///
    /// The clock is kept in memory only, so quitting Recall — or the helper being
    /// restarted for any reason — starts the next code locked. A grace period that
    /// survived a restart would be a grace period nobody chose.
    case afterGrace(minutes: Int)
    /// Never. Anyone at the keyboard can read every code.
    case never

    public static let `default` = OTPAuthenticationPolicy.always

    /// Grace periods offered in Settings. Anything longer stops being a convenience and
    /// starts being ``never`` with extra steps.
    public static let graceOptions = [1, 5, 15, 30, 60]

    /// The longest grace period that can be set, in minutes.
    public static let maximumGraceMinutes = 60

    // MARK: - Wire format

    /// XPC carries property-list types, so the policy crosses as a string.
    public var rawValue: String {
        switch self {
        case .always: "always"
        case .never: "never"
        case .afterGrace(let minutes): "grace:\(minutes)"
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "always":
            self = .always
        case "never":
            self = .never
        default:
            guard rawValue.hasPrefix("grace:"),
                  let minutes = Int(rawValue.dropFirst("grace:".count)),
                  minutes > 0
            else { return nil }
            // Clamped rather than rejected: a value from an older or newer build should
            // land somewhere sensible, not fall back to `always` and look like a bug.
            self = .afterGrace(minutes: min(minutes, Self.maximumGraceMinutes))
        }
    }

    // MARK: - Decisions

    /// Whether a code may be handed over without asking, given when authentication last
    /// succeeded.
    ///
    /// - Parameter lastAuthenticated: nil when nothing has been authenticated yet this
    ///   run, which is the state a fresh helper starts in.
    public func allowsWithoutAuthenticating(lastAuthenticated: Date?, now: Date = .now) -> Bool {
        switch self {
        case .always:
            return false
        case .never:
            return true
        case .afterGrace(let minutes):
            guard let lastAuthenticated else { return false }
            let elapsed = now.timeIntervalSince(lastAuthenticated)
            // A clock that jumped backwards must not extend the grace period.
            guard elapsed >= 0 else { return false }
            return elapsed < Double(minutes) * 60
        }
    }

    /// What Settings shows for this choice.
    public var summary: String {
        switch self {
        case .always:
            "Every code asks for Touch ID."
        case .never:
            "Codes are shown to anyone at this Mac. Recall will not ask."
        case .afterGrace(let minutes):
            "Asks once, then not again for \(minutes) minute\(minutes == 1 ? "" : "s"). Quitting Recall resets it."
        }
    }
}
