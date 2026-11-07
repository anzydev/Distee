import CryptoKit
import Foundation

/// `deviceId = base32(SHA-256(macSignPubKey))[0..<16]` — 80 bits, as specified in Phase 1.
public enum DeviceIdentifier {
    public static let length = 16

    public static func derive(from signingKey: P256.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: signingKey.x963Representation)
        return String(Base32.encodeLowercased(Data(digest)).prefix(length))
    }
}
