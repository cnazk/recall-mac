import Foundation

/// RFC 4648 base32, which is how every `otpauth://` URI carries its secret.
public enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func decode(_ string: String) -> Data? {
        // Padding and casing vary between services; both are noise here.
        let cleaned = string
            .uppercased()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !cleaned.isEmpty else { return nil }

        var lookup: [Character: UInt8] = [:]
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }

        var bits = 0
        var accumulator: UInt32 = 0
        var bytes: [UInt8] = []

        for character in cleaned {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
            }
        }

        return Data(bytes)
    }

    public static func encode(_ data: Data) -> String {
        var result = ""
        var bits = 0
        var accumulator: UInt32 = 0

        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((accumulator >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            result.append(alphabet[Int((accumulator << UInt32(5 - bits)) & 0x1F)])
        }
        return result
    }
}
