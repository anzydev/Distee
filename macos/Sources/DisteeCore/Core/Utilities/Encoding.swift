import Foundation

/// base64url without padding, as required by the Phase 1 envelope format.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        var string = data.base64EncodedString()
        string = string
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while string.hasSuffix("=") { string.removeLast() }
        return string
    }

    public static func decode(_ string: String) throws -> Data {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else {
            throw Base64URLFailure.invalidInput
        }
        return data
    }

    public enum Base64URLFailure: Error, Equatable {
        case invalidInput
    }
}

/// RFC 4648 base32, lowercased, unpadded. Used only to derive the 80-bit device id.
public enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    public static func encodeLowercased(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bits = 0

        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                let index = Int((buffer >> UInt32(bits - 5)) & 0x1F)
                output.append(alphabet[index])
                bits -= 5
            }
        }
        if bits > 0 {
            let index = Int((buffer << UInt32(5 - bits)) & 0x1F)
            output.append(alphabet[index])
        }
        return output
    }
}
