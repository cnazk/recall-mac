import Foundation

/// Parses and writes `otpauth://` URIs — the format every service's QR code encodes.
public enum OTPURI {
    public enum Failure: Error, CustomStringConvertible {
        case notAnOTPURI
        case unsupportedKind(String)
        case missingSecret
        case malformedSecret

        public var description: String {
            switch self {
            case .notAnOTPURI: String(localized: "That is not a two-factor setup link.")
            case .unsupportedKind(let kind): String(localized: "Unsupported code type “\(kind)”.")
            case .missingSecret: String(localized: "The link has no secret in it.")
            case .malformedSecret: String(localized: "The secret in that link is not valid base32.")
            }
        }
    }

    public static func isOTPURI(_ string: String) -> Bool {
        string.lowercased().hasPrefix("otpauth://")
    }

    /// `otpauth://totp/Issuer:account?secret=…&issuer=…&digits=6&period=30&algorithm=SHA1`
    public static func parse(_ string: String) throws -> OTPAccount {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "otpauth",
              let host = components.host?.lowercased()
        else { throw Failure.notAnOTPURI }

        guard let kind = OTPKind(rawValue: host) else { throw Failure.unsupportedKind(host) }

        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                item.value.map { (item.name.lowercased(), $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        guard let rawSecret = query["secret"], !rawSecret.isEmpty else { throw Failure.missingSecret }
        guard let secret = Base32.decode(rawSecret), !secret.isEmpty else { throw Failure.malformedSecret }

        // The label is "Issuer:account", but the issuer query parameter wins when both
        // are present — services disagree, and the parameter is the explicit one.
        let label = components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        let labelParts = label.split(separator: ":", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        let issuer = query["issuer"] ?? (labelParts.count > 1 ? labelParts[0] : "")
        let account = labelParts.count > 1 ? labelParts[1] : label

        return OTPAccount(
            issuer: issuer,
            account: account,
            secret: secret,
            algorithm: query["algorithm"].flatMap { OTPAlgorithm(rawValue: $0.uppercased()) } ?? .sha1,
            digits: query["digits"].flatMap(Int.init) ?? 6,
            period: query["period"].flatMap(Int.init) ?? 30,
            counter: query["counter"].flatMap(UInt64.init) ?? 0,
            kind: kind
        )
    }

    /// Writes the URI back out, for export. An authenticator that holds your seeds
    /// hostage is a worse authenticator.
    public static func string(for account: OTPAccount) -> String {
        var components = URLComponents()
        components.scheme = "otpauth"
        components.host = account.kind.rawValue
        components.path = "/" + (account.issuer.isEmpty ? account.account : "\(account.issuer):\(account.account)")

        var items = [
            URLQueryItem(name: "secret", value: Base32.encode(account.secret)),
            URLQueryItem(name: "algorithm", value: account.algorithm.rawValue),
            URLQueryItem(name: "digits", value: String(account.digits)),
        ]
        if !account.issuer.isEmpty {
            items.insert(URLQueryItem(name: "issuer", value: account.issuer), at: 1)
        }
        switch account.kind {
        case .totp: items.append(URLQueryItem(name: "period", value: String(account.period)))
        case .hotp: items.append(URLQueryItem(name: "counter", value: String(account.counter)))
        }

        components.queryItems = items
        return components.string ?? ""
    }
}
