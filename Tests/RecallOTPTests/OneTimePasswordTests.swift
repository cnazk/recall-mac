import Foundation
import Testing
@testable import RecallOTP

/// The seeds from the RFCs. SHA-256 and SHA-512 repeat the ASCII digits to fill their
/// key length, exactly as RFC 6238 Appendix B specifies.
private let sha1Seed = Data("12345678901234567890".utf8)
private let sha256Seed = Data("12345678901234567890123456789012".utf8)
private let sha512Seed = Data("1234567890123456789012345678901234567890123456789012345678901234".utf8)

@Suite("HOTP — RFC 4226 test vectors")
struct HOTPVectorTests {
    /// Appendix D, the full published table.
    @Test("Published vectors", arguments: [
        (0, "755224"), (1, "287082"), (2, "359152"), (3, "969429"), (4, "338314"),
        (5, "254676"), (6, "287922"), (7, "162583"), (8, "399871"), (9, "520489"),
    ])
    func matchesPublishedVectors(counter: UInt64, expected: String) {
        #expect(OneTimePassword.hotp(secret: sha1Seed, counter: counter) == expected)
    }
}

@Suite("TOTP — RFC 6238 test vectors")
struct TOTPVectorTests {
    /// Appendix B. Eight digits, as the table specifies.
    @Test("SHA-1", arguments: [
        (59.0, "94287082"),
        (1_111_111_109.0, "07081804"),
        (1_111_111_111.0, "14050471"),
        (1_234_567_890.0, "89005924"),
        (2_000_000_000.0, "69279037"),
        (20_000_000_000.0, "65353130"),
    ])
    func sha1Vectors(time: Double, expected: String) {
        let code = OneTimePassword.totp(
            secret: sha1Seed,
            at: Date(timeIntervalSince1970: time),
            digits: 8,
            algorithm: .sha1
        )
        #expect(code == expected)
    }

    @Test("SHA-256", arguments: [
        (59.0, "46119246"),
        (1_111_111_109.0, "68084774"),
        (1_234_567_890.0, "91819424"),
        (20_000_000_000.0, "77737706"),
    ])
    func sha256Vectors(time: Double, expected: String) {
        let code = OneTimePassword.totp(
            secret: sha256Seed,
            at: Date(timeIntervalSince1970: time),
            digits: 8,
            algorithm: .sha256
        )
        #expect(code == expected)
    }

    @Test("SHA-512", arguments: [
        (59.0, "90693936"),
        (1_111_111_109.0, "25091201"),
        (1_234_567_890.0, "93441116"),
        (20_000_000_000.0, "47863826"),
    ])
    func sha512Vectors(time: Double, expected: String) {
        let code = OneTimePassword.totp(
            secret: sha512Seed,
            at: Date(timeIntervalSince1970: time),
            digits: 8,
            algorithm: .sha512
        )
        #expect(code == expected)
    }
}

@Suite("Code timing")
struct TOTPTimingTests {
    /// A real step boundary: 1,699,999,980 is divisible by both 30 and 60. Picking a
    /// round-looking number instead is how this test was wrong the first time.
    private static let boundary = 1_699_999_980.0

    @Test("The code is stable within a period and changes at the boundary")
    func rotatesOnTheBoundary() {
        let secret = sha1Seed
        let inPeriod = Date(timeIntervalSince1970: Self.boundary)
        let sameStep = Date(timeIntervalSince1970: Self.boundary + 29)
        let nextStep = Date(timeIntervalSince1970: Self.boundary + 30)

        let first = OneTimePassword.totp(secret: secret, at: inPeriod)
        #expect(OneTimePassword.totp(secret: secret, at: sameStep) == first)
        #expect(OneTimePassword.totp(secret: secret, at: nextStep) != first)
    }

    @Test("Seconds remaining counts down to the boundary")
    func countsDown() {
        #expect(OneTimePassword.secondsRemaining(at: Date(timeIntervalSince1970: Self.boundary), period: 30) == 30)
        #expect(OneTimePassword.secondsRemaining(at: Date(timeIntervalSince1970: Self.boundary + 1), period: 30) == 29)
        #expect(OneTimePassword.secondsRemaining(at: Date(timeIntervalSince1970: Self.boundary + 29), period: 30) == 1)
    }

    @Test("A non-standard period is honoured")
    func customPeriod() {
        let secret = sha1Seed
        let a = OneTimePassword.totp(secret: secret, at: Date(timeIntervalSince1970: Self.boundary), period: 60)
        let b = OneTimePassword.totp(secret: secret, at: Date(timeIntervalSince1970: Self.boundary + 59), period: 60)
        #expect(a == b)
    }

    @Test("Digit counts other than six are respected")
    func digitCounts() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(OneTimePassword.totp(secret: sha1Seed, at: date, digits: 6).count == 6)
        #expect(OneTimePassword.totp(secret: sha1Seed, at: date, digits: 7).count == 7)
        #expect(OneTimePassword.totp(secret: sha1Seed, at: date, digits: 8).count == 8)
    }

    @Test("Codes keep their leading zeros")
    func padsLeadingZeros() {
        // RFC 6238's own 07081804 vector is the case that catches naive formatting.
        let code = OneTimePassword.totp(
            secret: sha1Seed,
            at: Date(timeIntervalSince1970: 1_111_111_109),
            digits: 8
        )
        #expect(code.hasPrefix("0"))
        #expect(code.count == 8)
    }
}

@Suite("Base32")
struct Base32Tests {
    @Test("Round-trips the RFC 6238 seed")
    func roundTrips() {
        let encoded = Base32.encode(sha1Seed)
        #expect(encoded == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        #expect(Base32.decode(encoded) == sha1Seed)
    }

    @Test("Tolerates padding, spacing and lower case, as services print them")
    func tolerantOfFormatting() {
        let canonical = Base32.decode("GEZDGNBVGY3TQOJQ")
        #expect(Base32.decode("gezd gnbv gy3t qojq") == canonical)
        #expect(Base32.decode("GEZDGNBVGY3TQOJQ======") == canonical)
        #expect(Base32.decode("GEZD-GNBV-GY3T-QOJQ") == canonical)
    }

    @Test("Rejects characters outside the alphabet")
    func rejectsGarbage() {
        #expect(Base32.decode("not base32!") == nil)
        #expect(Base32.decode("") == nil)
        #expect(Base32.decode("01890") == nil, "0, 1, 8 and 9 are not in the alphabet")
    }
}
