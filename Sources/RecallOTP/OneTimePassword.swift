import CryptoKit
import Foundation

/// Hash used to derive the code.
public enum OTPAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
}

/// Counter-based (HOTP) or time-based (TOTP).
public enum OTPKind: String, Codable, Sendable {
    case totp
    case hotp
}

/// One account's parameters. The `secret` is the only sensitive part and never leaves the
/// helper process that owns it.
public struct OTPAccount: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// The service, e.g. "GitHub".
    public var issuer: String
    /// The account at that service, e.g. "alex@example.com".
    public var account: String
    public var secret: Data
    public var algorithm: OTPAlgorithm
    public var digits: Int
    /// Seconds per code, for TOTP.
    public var period: Int
    /// Current counter, for HOTP.
    public var counter: UInt64
    public var kind: OTPKind

    public init(
        id: UUID = UUID(),
        issuer: String,
        account: String,
        secret: Data,
        algorithm: OTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        counter: UInt64 = 0,
        kind: OTPKind = .totp
    ) {
        self.id = id
        self.issuer = issuer
        self.account = account
        self.secret = secret
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
        self.counter = counter
        self.kind = kind
    }

    public var label: String {
        issuer.isEmpty ? account : "\(issuer) (\(account))"
    }
}

/// RFC 4226 / RFC 6238 code generation.
///
/// Implemented here rather than taken as a dependency for one reason: the published test
/// vectors make it provable, and a dependency in the process that holds 2FA seeds is a
/// dependency that can exfiltrate them.
public enum OneTimePassword {
    /// RFC 4226 HOTP.
    public static func hotp(secret: Data, counter: UInt64, digits: Int = 6, algorithm: OTPAlgorithm = .sha1) -> String {
        var bigEndianCounter = counter.bigEndian
        let counterData = Data(bytes: &bigEndianCounter, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secret)

        let digest: Data = switch algorithm {
        case .sha1: Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        case .sha256: Data(HMAC<SHA256>.authenticationCode(for: counterData, using: key))
        case .sha512: Data(HMAC<SHA512>.authenticationCode(for: counterData, using: key))
        }

        // Dynamic truncation, RFC 4226 §5.3.
        let offset = Int(digest[digest.count - 1] & 0x0F)
        let truncated = (UInt32(digest[offset] & 0x7F) << 24)
            | (UInt32(digest[offset + 1]) << 16)
            | (UInt32(digest[offset + 2]) << 8)
            | UInt32(digest[offset + 3])

        let modulus = UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)u", truncated % modulus)
    }

    /// RFC 6238 TOTP for a moment in time.
    public static func totp(
        secret: Data,
        at date: Date = .now,
        period: Int = 30,
        digits: Int = 6,
        algorithm: OTPAlgorithm = .sha1
    ) -> String {
        hotp(secret: secret, counter: counter(at: date, period: period), digits: digits, algorithm: algorithm)
    }

    public static func code(for account: OTPAccount, at date: Date = .now) -> String {
        switch account.kind {
        case .totp:
            totp(
                secret: account.secret,
                at: date,
                period: account.period,
                digits: account.digits,
                algorithm: account.algorithm
            )
        case .hotp:
            hotp(
                secret: account.secret,
                counter: account.counter,
                digits: account.digits,
                algorithm: account.algorithm
            )
        }
    }

    /// The time step a moment falls in.
    public static func counter(at date: Date, period: Int) -> UInt64 {
        guard period > 0 else { return 0 }
        return UInt64(max(date.timeIntervalSince1970, 0)) / UInt64(period)
    }

    /// Seconds until the current code rotates.
    public static func secondsRemaining(at date: Date = .now, period: Int = 30) -> Int {
        guard period > 0 else { return 0 }
        let elapsed = Int(max(date.timeIntervalSince1970, 0)) % period
        return period - elapsed
    }
}
