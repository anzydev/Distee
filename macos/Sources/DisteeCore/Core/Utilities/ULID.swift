import Foundation
import Security

/// ULID (Crockford base32) — 48-bit millisecond timestamp + 80-bit randomness.
/// Monotonic within a process: two ids generated in the same millisecond are ordered.
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let lock = NSLock()
    private static var lastMilliseconds: UInt64 = 0
    private static var lastRandom = [UInt8](repeating: 0, count: 10)

    public static func generate(at date: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }

        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        if milliseconds == lastMilliseconds {
            increment(&lastRandom)
        } else {
            lastMilliseconds = milliseconds
            var random = [UInt8](repeating: 0, count: 10)
            if SecRandomCopyBytes(kSecRandomDefault, random.count, &random) != errSecSuccess {
                random = (0..<10).map { _ in UInt8.random(in: 0...255) }
            }
            lastRandom = random
        }
        return encodeTime(milliseconds) + encodeRandom(lastRandom)
    }

    private static func encodeTime(_ milliseconds: UInt64) -> String {
        var characters = [Character](repeating: "0", count: 10)
        var value = milliseconds
        var index = 9
        while index >= 0 {
            characters[index] = alphabet[Int(value & 0x1F)]
            value >>= 5
            index -= 1
        }
        return String(characters)
    }

    private static func encodeRandom(_ bytes: [UInt8]) -> String {
        var output = String()
        output.reserveCapacity(16)
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in bytes {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[Int((accumulator >> UInt32(bits - 5)) & 0x1F)])
                bits -= 5
            }
        }
        return output
    }

    /// Big-endian increment of the 80-bit random component.
    private static func increment(_ bytes: inout [UInt8]) {
        var index = bytes.count - 1
        while index >= 0 {
            if bytes[index] == 0xFF {
                bytes[index] = 0
                index -= 1
            } else {
                bytes[index] &+= 1
                return
            }
        }
    }
}
