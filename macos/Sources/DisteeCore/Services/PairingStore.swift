import Foundation

/// The Mac's single pairing record (Phase 1: one Mac ⇄ exactly one phone).
/// Phase 2 creates, reads and deletes this record; Phase 3 fills it during pairing.
public struct PairingRecord: Codable, Equatable {
    public var phoneLabel: String
    public var phoneSigningPublicKey: String
    public var phoneKeyAgreementPublicKey: String
    public var epoch: Int
    public var pairedAt: Date
    public var lastSequence: Int
    public var recentNonces: [String]

    public init(
        phoneLabel: String,
        phoneSigningPublicKey: String,
        phoneKeyAgreementPublicKey: String,
        epoch: Int,
        pairedAt: Date = Date(),
        lastSequence: Int = 0,
        recentNonces: [String] = []
    ) {
        self.phoneLabel = phoneLabel
        self.phoneSigningPublicKey = phoneSigningPublicKey
        self.phoneKeyAgreementPublicKey = phoneKeyAgreementPublicKey
        self.epoch = epoch
        self.pairedAt = pairedAt
        self.lastSequence = lastSequence
        self.recentNonces = recentNonces
    }
}

public enum PairingSummary: Equatable {
    case notPaired
    case paired(label: String, epoch: Int, pairedAt: Date)
}

/// Keychain-backed pairing storage. The record contains public keys and counters only —
/// no shared secret exists in the design.
public final class PairingStore {
    private let keychain: KeychainManager
    private let logger: LoggingManager
    private static let account = "pairing.record"

    public init(keychain: KeychainManager = KeychainManager(), logger: LoggingManager = .shared) {
        self.keychain = keychain
        self.logger = logger
    }

    public func load() -> PairingRecord? {
        guard let data = try? keychain.read(KeychainManager.Item(account: Self.account)) else { return nil }
        return try? JSONDecoder().decode(PairingRecord.self, from: data)
    }

    public func save(_ record: PairingRecord) throws {
        let data = try JSONEncoder().encode(record)
        try keychain.save(data, for: KeychainManager.Item(account: Self.account))
        logger.notice("Pairing record stored for epoch \(record.epoch)")
    }

    /// Unpair: removes the record and rewrites the epoch so old signatures fail.
    public func clear() throws {
        let nextEpoch = (load()?.epoch ?? 0) + 1
        try keychain.delete(KeychainManager.Item(account: Self.account))
        try keychain.save(Data("\(nextEpoch)".utf8), for: KeychainManager.Item(account: "pairing.epoch"))
        logger.notice("Pairing record cleared; epoch advanced to \(nextEpoch)")
    }

    public var currentEpoch: Int {
        if let record = load() { return record.epoch }
        if let data = try? keychain.read(KeychainManager.Item(account: "pairing.epoch")),
           let text = String(data: data, encoding: .utf8),
           let value = Int(text) {
            return value
        }
        return 0
    }
}
