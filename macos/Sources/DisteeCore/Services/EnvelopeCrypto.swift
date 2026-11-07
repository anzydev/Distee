import CryptoKit
import Foundation

public enum SHA256Digest {
    public static func bytes(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Signing is abstracted so a Secure Enclave key and a software key are interchangeable.
public protocol EnvelopeSigner {
    var publicKey: P256.Signing.PublicKey { get }
    func signature(for data: Data) throws -> P256.Signing.ECDSASignature
}

extension P256.Signing.PrivateKey: EnvelopeSigner {}

extension SecureEnclave.P256.Signing.PrivateKey: EnvelopeSigner {}

public enum EnvelopeError: Error, Equatable {
    case unsupportedVersion(Int)
    case malformedField(String)
    case badSignature
    case decryptionFailed
}

/// Per-message ECIES: fresh ephemeral P-256 key agreement, HKDF-SHA-256, AES-256-GCM
/// with the envelope header as additional authenticated data.
public enum EnvelopeCrypto {
    public static let keyDerivationTag = "distee/v1/enc"
    public static let nonceLength = 12
    public static let tagLength = 16

    public static func freshNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<nonceLength).map { _ in UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    public static func derivedKey(
        sharedSecret: SharedSecret,
        nonce: Data,
        deviceId: String,
        epoch: Int
    ) -> SymmetricKey {
        let info = Data("\(keyDerivationTag)\n\(deviceId)\n\(epoch)".utf8)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: nonce,
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    /// Seal `plaintext` to the recipient and sign the result.
    public static func seal(
        _ plaintext: Data,
        type: String,
        deviceId: String,
        epoch: Int,
        messageId: String,
        seq: Int,
        timestamp: Int,
        recipient: P256.KeyAgreement.PublicKey,
        signer: EnvelopeSigner,
        nonce: Data? = nil
    ) throws -> Envelope {
        let nonce = nonce ?? freshNonce()
        guard nonce.count == nonceLength else {
            throw EnvelopeError.malformedField("n")
        }

        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = derivedKey(sharedSecret: shared, nonce: nonce, deviceId: deviceId, epoch: epoch)

        let nonceString = Base64URL.encode(nonce)
        let header = EnvelopeCoding.headerBytes(
            t: type, d: deviceId, e: epoch, id: messageId, seq: seq, ts: timestamp, n: nonceString
        )
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: header
        )
        // Wire layout is ciphertext ‖ tag (nonce travels separately in `n`), matching
        // WebCrypto. `SealedBox.combined` would prepend the nonce and break interoperability.
        let combined = sealed.ciphertext + sealed.tag
        let ephemeralString = Base64URL.encode(ephemeral.publicKey.x963Representation)
        let signingInput = EnvelopeCoding.signingInput(header: header, eph: ephemeralString, ciphertext: combined)
        let signature = try signer.signature(for: signingInput)

        return Envelope(
            t: type,
            d: deviceId,
            e: epoch,
            id: messageId,
            seq: seq,
            ts: timestamp,
            n: nonceString,
            eph: ephemeralString,
            ct: Base64URL.encode(combined),
            sig: Base64URL.encode(signature.derRepresentation)
        )
    }

    /// Verify signature, then decrypt. Order matters: never decrypt unauthenticated input.
    public static func open(
        _ envelope: Envelope,
        recipientKey: P256.KeyAgreement.PrivateKey,
        senderSigningKey: P256.Signing.PublicKey,
        expectedDeviceId: String
    ) throws -> Data {
        guard envelope.v == EnvelopeCoding.protocolVersion else {
            throw EnvelopeError.unsupportedVersion(envelope.v)
        }
        guard envelope.d == expectedDeviceId else {
            throw EnvelopeError.malformedField("d")
        }

        let signatureData = try Base64URL.decode(envelope.sig)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        let signingInput = try EnvelopeCoding.signingInput(for: envelope)
        guard senderSigningKey.isValidSignature(signature, for: signingInput) else {
            throw EnvelopeError.badSignature
        }

        let ciphertext = try Base64URL.decode(envelope.ct)
        let nonce = try Base64URL.decode(envelope.n)
        guard nonce.count == nonceLength else { throw EnvelopeError.malformedField("n") }
        guard let ephemeralData = try? Base64URL.decode(envelope.eph) else {
            throw EnvelopeError.malformedField("eph")
        }
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
        let shared = try recipientKey.sharedSecretFromKeyAgreement(with: ephemeral)
        let key = derivedKey(sharedSecret: shared, nonce: nonce, deviceId: envelope.d, epoch: envelope.e)

        guard ciphertext.count >= Self.tagLength else { throw EnvelopeError.malformedField("ct") }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext.dropLast(Self.tagLength),
                tag: ciphertext.suffix(Self.tagLength)
            )
        } catch {
            throw EnvelopeError.malformedField("ct")
        }
        let header = EnvelopeCoding.headerBytes(for: envelope)
        do {
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw EnvelopeError.decryptionFailed
        }
    }

    /// Verify a signature without decrypting. Used to reject forged frames cheaply.
    public static func verifySignature(_ envelope: Envelope, senderSigningKey: P256.Signing.PublicKey) throws -> Bool {
        let signatureData = try Base64URL.decode(envelope.sig)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        let signingInput = try EnvelopeCoding.signingInput(for: envelope)
        return senderSigningKey.isValidSignature(signature, for: signingInput)
    }
}
