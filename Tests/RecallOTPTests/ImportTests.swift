import Foundation
import Testing
@testable import RecallOTP

@Suite("otpauth:// URIs")
struct OTPURITests {
    @Test("A standard setup link parses")
    func parsesStandardURI() throws {
        let account = try OTPURI.parse(
            "otpauth://totp/GitHub:alex@example.com?secret=GEZDGNBVGY3TQOJQ&issuer=GitHub&algorithm=SHA256&digits=8&period=60"
        )
        #expect(account.issuer == "GitHub")
        #expect(account.account == "alex@example.com")
        #expect(account.secret == Data("1234567890".utf8))
        #expect(account.algorithm == .sha256)
        #expect(account.digits == 8)
        #expect(account.period == 60)
        #expect(account.kind == .totp)
    }

    @Test("Defaults are filled in when the link omits them")
    func appliesDefaults() throws {
        let account = try OTPURI.parse("otpauth://totp/alex@example.com?secret=GEZDGNBVGY3TQOJQ")
        #expect(account.algorithm == .sha1)
        #expect(account.digits == 6)
        #expect(account.period == 30)
        #expect(account.issuer.isEmpty)
        #expect(account.account == "alex@example.com")
    }

    @Test("The issuer parameter wins over the label, since services disagree")
    func issuerParameterWins() throws {
        let account = try OTPURI.parse("otpauth://totp/Old:alex?secret=GEZDGNBVGY3TQOJQ&issuer=New")
        #expect(account.issuer == "New")
        #expect(account.account == "alex")
    }

    @Test("Counter-based links are supported")
    func parsesHOTP() throws {
        let account = try OTPURI.parse("otpauth://hotp/Bank:alex?secret=GEZDGNBVGY3TQOJQ&counter=42")
        #expect(account.kind == .hotp)
        #expect(account.counter == 42)
    }

    @Test("Bad links are rejected with a reason, not silently accepted", arguments: [
        "https://example.com",
        "otpauth://totp/alex",
        "otpauth://totp/alex?secret=!!!!",
        "otpauth://sms/alex?secret=GEZDGNBVGY3TQOJQ",
    ])
    func rejectsBadURIs(uri: String) {
        #expect(throws: OTPURI.Failure.self) {
            try OTPURI.parse(uri)
        }
    }

    @Test("Export round-trips back through the parser")
    func roundTrips() throws {
        let original = OTPAccount(
            issuer: "GitHub",
            account: "alex@example.com",
            secret: Data("1234567890".utf8),
            algorithm: .sha512,
            digits: 8,
            period: 60
        )

        let restored = try OTPURI.parse(OTPURI.string(for: original))
        #expect(restored.issuer == original.issuer)
        #expect(restored.account == original.account)
        #expect(restored.secret == original.secret)
        #expect(restored.algorithm == original.algorithm)
        #expect(restored.digits == original.digits)
        #expect(restored.period == original.period)
    }

    @Test("Recognises what it can handle before trying")
    func recognisesURIs() {
        #expect(OTPURI.isOTPURI("otpauth://totp/x?secret=A"))
        #expect(OTPURI.isOTPURI("OTPAUTH://TOTP/x?secret=A"))
        #expect(!OTPURI.isOTPURI("https://example.com"))
    }
}

/// Builds protobuf wire-format bytes from the published schema, independently of the
/// reader under test — encoding with the same code that decodes would prove nothing.
private struct ProtobufWriter {
    private(set) var data = Data()

    mutating func varint(field: Int, value: UInt64) {
        key(field: field, wireType: 0)
        appendVarint(value)
    }

    mutating func bytes(field: Int, value: Data) {
        key(field: field, wireType: 2)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func string(field: Int, value: String) {
        bytes(field: field, value: Data(value.utf8))
    }

    private mutating func key(field: Int, wireType: UInt64) {
        appendVarint(UInt64(field) << 3 | wireType)
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}

private func migrationURI(containing parameters: [Data]) -> String {
    var payload = ProtobufWriter()
    for entry in parameters {
        payload.bytes(field: 1, value: entry)
    }
    payload.varint(field: 2, value: 1) // version
    payload.varint(field: 3, value: 1) // batch_size

    let base64 = payload.data.base64EncodedString()
    var components = URLComponents()
    components.scheme = "otpauth-migration"
    components.host = "offline"
    components.queryItems = [URLQueryItem(name: "data", value: base64)]
    return components.string ?? ""
}

@Suite("Google Authenticator import")
struct GoogleAuthenticatorImportTests {
    private func parameters(
        secret: Data = Data("1234567890".utf8),
        name: String = "GitHub:alex@example.com",
        issuer: String = "GitHub",
        algorithm: UInt64 = 1,
        digits: UInt64 = 1,
        type: UInt64 = 2,
        counter: UInt64? = nil
    ) -> Data {
        var writer = ProtobufWriter()
        writer.bytes(field: 1, value: secret)
        writer.string(field: 2, value: name)
        writer.string(field: 3, value: issuer)
        writer.varint(field: 4, value: algorithm)
        writer.varint(field: 5, value: digits)
        writer.varint(field: 6, value: type)
        if let counter { writer.varint(field: 7, value: counter) }
        return writer.data
    }

    @Test("An exported account comes back intact")
    func importsOneAccount() throws {
        let accounts = try GoogleAuthenticatorImport.parse(migrationURI(containing: [parameters()]))

        #expect(accounts.count == 1)
        let account = try #require(accounts.first)
        #expect(account.issuer == "GitHub")
        #expect(account.account == "alex@example.com")
        #expect(account.secret == Data("1234567890".utf8))
        #expect(account.algorithm == .sha1)
        #expect(account.digits == 6)
        #expect(account.kind == .totp)
    }

    @Test("A batch of accounts all come through")
    func importsSeveralAccounts() throws {
        let uri = migrationURI(containing: [
            parameters(name: "GitHub:alex", issuer: "GitHub"),
            parameters(secret: Data("0987654321".utf8), name: "AWS:root", issuer: "AWS", algorithm: 2, digits: 2),
            parameters(secret: Data("abcdefghij".utf8), name: "Bank:alex", issuer: "Bank", type: 1, counter: 7),
        ])

        let accounts = try GoogleAuthenticatorImport.parse(uri)
        #expect(accounts.count == 3)
        #expect(accounts[1].algorithm == .sha256)
        #expect(accounts[1].digits == 8)
        #expect(accounts[2].kind == .hotp)
        #expect(accounts[2].counter == 7)
    }

    @Test("An account exported without a separate issuer still gets one from its name")
    func splitsIssuerFromName() throws {
        let uri = migrationURI(containing: [parameters(name: "Dropbox:alex@example.com", issuer: "")])
        let account = try #require(try GoogleAuthenticatorImport.parse(uri).first)
        #expect(account.issuer == "Dropbox")
        #expect(account.account == "alex@example.com")
    }

    @Test("The generated codes match what the seed should produce")
    func importedSeedsWork() throws {
        // The RFC 6238 seed, imported through the migration path, must still produce the
        // published code — the point of the import is that it survives the round trip.
        let uri = migrationURI(containing: [parameters(secret: Data("12345678901234567890".utf8))])
        let account = try #require(try GoogleAuthenticatorImport.parse(uri).first)

        let code = OneTimePassword.totp(
            secret: account.secret,
            at: Date(timeIntervalSince1970: 59),
            digits: 8
        )
        #expect(code == "94287082")
    }

    @Test("Malformed exports are rejected", arguments: [
        "otpauth://totp/x?secret=GEZDGNBVGY3TQOJQ",
        "otpauth-migration://offline?data=!!!not-base64!!!",
        "otpauth-migration://offline",
    ])
    func rejectsBadExports(uri: String) {
        #expect(throws: (any Error).self) {
            try GoogleAuthenticatorImport.parse(uri)
        }
    }

    @Test("Recognises an export link")
    func recognisesMigrationURIs() {
        #expect(GoogleAuthenticatorImport.isMigrationURI("otpauth-migration://offline?data=AA"))
        #expect(!GoogleAuthenticatorImport.isMigrationURI("otpauth://totp/x"))
    }
}

/// A link with a bare account label and no "Issuer:" prefix in the path — the shape most
/// services actually emit. The secret here is the public test vector, not anyone's.
@Suite("Bare-label setup links")
struct BareLabelURITests {
    private let uri = "otpauth://totp/someone%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=ExampleCo&algorithm=SHA1&digits=6&period=30"

    @Test("Parses, with the issuer coming from the query and the account from the path")
    func parsesBareLabel() throws {
        let account = try OTPURI.parse(uri)
        #expect(account.issuer == "ExampleCo")
        #expect(account.account == "someone@example.com")
        #expect(account.digits == 6)
        #expect(account.period == 30)
        #expect(account.algorithm == .sha1)
        #expect(account.kind == .totp)
        #expect(!account.secret.isEmpty)
    }

    @Test("A percent-encoded label is decoded, not left as %40")
    func decodesPercentEncoding() throws {
        #expect(try OTPURI.parse(uri).account.contains("@"))
        #expect(try !OTPURI.parse(uri).account.contains("%40"))
    }
}

/// The app and the helper each check the other's code signature. They are *different*
/// identifiers, and conflating them meant the helper demanded its caller be itself —
/// which no app can satisfy, so every connection was refused and two-factor never worked.
@Suite("Code-signing requirements")
struct CodeSigningRequirementTests {
    @Test("The app checks for the helper, and the helper checks for the app")
    func requirementsNameDifferentIdentifiers() {
        let helperSide = OTPService.callerCodeSigningRequirement(teamIdentifier: nil)
        let appSide = OTPService.codeSigningRequirement(teamIdentifier: nil)

        #expect(appSide.contains(OTPService.bundleIdentifier))
        #expect(!appSide.contains(OTPService.appBundleIdentifier))

        #expect(helperSide.contains(OTPService.appBundleIdentifier))
        #expect(helperSide != appSide, "each side must check the other, not itself")
    }

    @Test("A team identifier tightens both sides to that team")
    func teamIdentifierIsApplied() {
        let team = "ABCDE12345"
        for requirement in [
            OTPService.codeSigningRequirement(teamIdentifier: team),
            OTPService.callerCodeSigningRequirement(teamIdentifier: team),
        ] {
            #expect(requirement.contains("anchor apple generic"))
            #expect(requirement.contains(team))
        }
    }

    @Test("Ad-hoc builds check the identifier only — there is no team to check")
    func adHocChecksIdentifierOnly() {
        for requirement in [
            OTPService.codeSigningRequirement(teamIdentifier: nil),
            OTPService.callerCodeSigningRequirement(teamIdentifier: ""),
        ] {
            #expect(!requirement.contains("anchor apple generic"))
            #expect(requirement.hasPrefix("identifier "))
        }
    }
}
