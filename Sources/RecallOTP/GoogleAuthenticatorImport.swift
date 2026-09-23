import Foundation

/// Decodes Google Authenticator's `otpauth-migration://offline?data=…` export.
///
/// The payload is a protobuf. The reader below handles only the handful of wire types
/// this one message uses — deliberately, because pulling in a protobuf library would put
/// third-party code in the process that handles 2FA seeds, which is the whole thing this
/// design is avoiding.
///
/// Schema (from the exported message):
/// ```
/// message Payload {
///   repeated OtpParameters otp_parameters = 1;
///   int32 version = 2; int32 batch_size = 3; int32 batch_index = 4; int32 batch_id = 5;
/// }
/// message OtpParameters {
///   bytes secret = 1; string name = 2; string issuer = 3;
///   Algorithm algorithm = 4; DigitCount digits = 5; OtpType type = 6; int64 counter = 7;
/// }
/// ```
public enum GoogleAuthenticatorImport {
    public enum Failure: Error, CustomStringConvertible {
        case notAMigrationURI
        case malformedPayload
        case noAccounts

        public var description: String {
            switch self {
            case .notAMigrationURI: String(localized: "That is not a Google Authenticator export link.")
            case .malformedPayload: String(localized: "That export could not be read.")
            case .noAccounts: String(localized: "That export contained no accounts.")
            }
        }
    }

    public static func isMigrationURI(_ string: String) -> Bool {
        string.lowercased().hasPrefix("otpauth-migration://")
    }

    /// One QR code from the export carries a batch of accounts; a large library is
    /// exported as several, which the caller imports one at a time.
    public static func parse(_ string: String) throws -> [OTPAccount] {
        guard isMigrationURI(string),
              let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let encoded = components.queryItems?.first(where: { $0.name.lowercased() == "data" })?.value
        else { throw Failure.notAMigrationURI }

        // The payload is base64 inside a URL, so it arrives percent-decoded already but
        // may still use the URL-safe alphabet.
        let normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = normalized.padding(
            toLength: normalized.count + (4 - normalized.count % 4) % 4,
            withPad: "=",
            startingAt: 0
        )

        guard let data = Data(base64Encoded: padded) else { throw Failure.malformedPayload }

        let accounts = try decodePayload(data)
        guard !accounts.isEmpty else { throw Failure.noAccounts }
        return accounts
    }

    // MARK: - Minimal protobuf

    private static func decodePayload(_ data: Data) throws -> [OTPAccount] {
        var accounts: [OTPAccount] = []
        var reader = ProtobufReader(data: data)

        while let field = try reader.nextField() {
            switch field {
            case (1, .lengthDelimited(let bytes)):
                accounts.append(try decodeParameters(bytes))
            default:
                continue
            }
        }
        return accounts
    }

    private static func decodeParameters(_ data: Data) throws -> OTPAccount {
        var secret = Data()
        var name = ""
        var issuer = ""
        var algorithm = OTPAlgorithm.sha1
        var digits = 6
        var kind = OTPKind.totp
        var counter: UInt64 = 0

        var reader = ProtobufReader(data: data)
        while let field = try reader.nextField() {
            switch field {
            case (1, .lengthDelimited(let bytes)):
                secret = bytes
            case (2, .lengthDelimited(let bytes)):
                name = String(decoding: bytes, as: UTF8.self)
            case (3, .lengthDelimited(let bytes)):
                issuer = String(decoding: bytes, as: UTF8.self)
            case (4, .varint(let value)):
                // 1 = SHA1, 2 = SHA256, 3 = SHA512, 4 = MD5 (unsupported, treated as SHA1)
                algorithm = switch value {
                case 2: .sha256
                case 3: .sha512
                default: .sha1
                }
            case (5, .varint(let value)):
                // 1 = six digits, 2 = eight.
                digits = value == 2 ? 8 : 6
            case (6, .varint(let value)):
                // 1 = HOTP, 2 = TOTP.
                kind = value == 1 ? .hotp : .totp
            case (7, .varint(let value)):
                counter = value
            default:
                continue
            }
        }

        guard !secret.isEmpty else { throw Failure.malformedPayload }

        // The name is often "Issuer:account" even when issuer is also set.
        var account = name
        if issuer.isEmpty || name.hasPrefix("\(issuer):") {
            let parts = name.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                if issuer.isEmpty { issuer = parts[0] }
                account = parts[1]
            }
        }

        return OTPAccount(
            issuer: issuer,
            account: account,
            secret: secret,
            algorithm: algorithm,
            digits: digits,
            period: 30,
            counter: counter,
            kind: kind
        )
    }
}

/// Just enough protobuf to read one known message.
struct ProtobufReader {
    enum Value {
        case varint(UInt64)
        case lengthDelimited(Data)
        case fixed64(UInt64)
        case fixed32(UInt32)
    }

    enum Failure: Error {
        case truncated
        case unsupportedWireType(Int)
    }

    let data: Data
    private var index: Data.Index

    init(data: Data) {
        self.data = data
        self.index = data.startIndex
    }

    mutating func nextField() throws -> (Int, Value)? {
        guard index < data.endIndex else { return nil }

        let key = try readVarint()
        let fieldNumber = Int(key >> 3)
        let wireType = Int(key & 0x07)

        switch wireType {
        case 0:
            return (fieldNumber, .varint(try readVarint()))
        case 1:
            return (fieldNumber, .fixed64(try readFixed(8)))
        case 2:
            let length = Int(try readVarint())
            guard length >= 0, data.distance(from: index, to: data.endIndex) >= length else {
                throw Failure.truncated
            }
            let end = data.index(index, offsetBy: length)
            let bytes = Data(data[index..<end])
            index = end
            return (fieldNumber, .lengthDelimited(bytes))
        case 5:
            return (fieldNumber, .fixed32(UInt32(truncatingIfNeeded: try readFixed(4))))
        default:
            throw Failure.unsupportedWireType(wireType)
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while index < data.endIndex {
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw Failure.truncated }
        }
        throw Failure.truncated
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        guard data.distance(from: index, to: data.endIndex) >= count else { throw Failure.truncated }
        var result: UInt64 = 0
        for offset in 0..<count {
            result |= UInt64(data[data.index(index, offsetBy: offset)]) << (8 * UInt64(offset))
        }
        index = data.index(index, offsetBy: count)
        return result
    }
}
