import Foundation

/// The single wire format for every message, from SECURITY_ARCHITECTURE.md §4.
/// Binary fields are base64url without padding.
public struct Envelope: Codable, Equatable, Sendable {
    public var v: Int
    /// Message type, e.g. `cmd.lock`, `lock.result`.
    public var t: String
    /// Recipient device id.
    public var d: String
    /// Pairing epoch.
    public var e: Int
    /// Message id (ULID).
    public var id: String
    /// Monotonic per-sender sequence.
    public var seq: Int
    /// Sender Unix time in seconds.
    public var ts: Int
    /// 96-bit AES-GCM nonce, base64url.
    public var n: String
    /// Ephemeral P-256 public key (X9.63), base64url.
    public var eph: String
    /// Ciphertext ‖ GCM tag, base64url. The nonce is NOT included; it travels in `n`.
    /// This is exactly what WebCrypto's AES-GCM `encrypt` returns, so the Mac and the PWA
    /// share one layout.
    public var ct: String
    /// ECDSA P-256 signature (DER), base64url.
    public var sig: String

    public init(
        v: Int = EnvelopeCoding.protocolVersion,
        t: String,
        d: String,
        e: Int,
        id: String,
        seq: Int,
        ts: Int,
        n: String,
        eph: String,
        ct: String,
        sig: String
    ) {
        self.v = v
        self.t = t
        self.d = d
        self.e = e
        self.id = id
        self.seq = seq
        self.ts = ts
        self.n = n
        self.eph = eph
        self.ct = ct
        self.sig = sig
    }

    enum CodingKeys: String, CodingKey {
        case v, t, d, e, id, seq, ts, n, eph, ct, sig
    }
}

/// Canonical byte layout shared by the Mac and (in Phase 3) the PWA.
/// Newline-delimited fields avoid JSON canonicalisation problems entirely.
public enum EnvelopeCoding {
    public static let protocolVersion = 1
    public static let versionTag = "distee/v1\n"

    /// AAD for AES-GCM: version tag and every header field through the nonce.
    public static func headerBytes(t: String, d: String, e: Int, id: String, seq: Int, ts: Int, n: String) -> Data {
        var bytes = Data(versionTag.utf8)
        bytes.append(contentsOf: t.utf8); bytes.append(0x0A)
        bytes.append(contentsOf: d.utf8); bytes.append(0x0A)
        bytes.append(contentsOf: String(e).utf8); bytes.append(0x0A)
        bytes.append(contentsOf: id.utf8); bytes.append(0x0A)
        bytes.append(contentsOf: String(seq).utf8); bytes.append(0x0A)
        bytes.append(contentsOf: String(ts).utf8); bytes.append(0x0A)
        bytes.append(contentsOf: n.utf8)
        return bytes
    }

    /// Signature input: header ‖ eph ‖ SHA-256(ciphertext). The header is length-free but
    /// newline-delimited, and `ct` is covered by a fixed-width digest.
    public static func signingInput(header: Data, eph: String, ciphertext: Data) -> Data {
        var bytes = header
        bytes.append(0x0A)
        bytes.append(contentsOf: eph.utf8)
        bytes.append(0x0A)
        bytes.append(contentsOf: SHA256Digest.bytes(of: ciphertext))
        return bytes
    }

    public static func signingInput(for envelope: Envelope) throws -> Data {
        let ct = try Base64URL.decode(envelope.ct)
        let header = headerBytes(t: envelope.t, d: envelope.d, e: envelope.e, id: envelope.id, seq: envelope.seq, ts: envelope.ts, n: envelope.n)
        return signingInput(header: header, eph: envelope.eph, ciphertext: ct)
    }

    /// Signature input for Mac → phone result frames (`lock.ack`, `lock.failed`,
    /// `unpair.ack`). Binds the frame type, the Mac's device id, the pairing epoch, the id of
    /// the command being answered, the outcome status and the timestamp, so a relay cannot
    /// forge a success or replay one against a different command.
    public static let ackTag = "distee/v1/ack"

    public static func ackSigningInput(t: String, d: String, e: Int, id: String, status: String, ts: Int) -> Data {
        Data("\(ackTag)\n\(t)\n\(d)\n\(e)\n\(id)\n\(status)\n\(ts)".utf8)
    }

    public static func headerBytes(for envelope: Envelope) -> Data {
        headerBytes(t: envelope.t, d: envelope.d, e: envelope.e, id: envelope.id, seq: envelope.seq, ts: envelope.ts, n: envelope.n)
    }
}
