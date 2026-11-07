import CryptoKit
import Foundation
import Security

public enum KeyStorage: String, Equatable {
    case secureEnclave = "Secure Enclave"
    case keychain = "Keychain"
}

public struct DeviceIdentity {
    public let deviceId: String
    public let signer: EnvelopeSigner
    public let signingPublicKey: P256.Signing.PublicKey
    public let keyAgreementKey: P256.KeyAgreement.PrivateKey
    public let storage: KeyStorage

    public var signingPublicKeyBase64URL: String {
        Base64URL.encode(signingPublicKey.x963Representation)
    }

    public var keyAgreementPublicKeyBase64URL: String {
        Base64URL.encode(keyAgreementKey.publicKey.x963Representation)
    }
}

public enum SecurityFailure: Error, Equatable {
    case keychain(OSStatus)
    case secureEnclaveUnavailable
    case keyMaterialInvalid(String)
}

/// Owns the device's long-lived key material.
///
/// - Signing key: Secure Enclave when available (non-exportable), otherwise a
///   Keychain-stored P-256 key. The storage choice is recorded and surfaced in the UI
///   rather than silently presenting a software key as hardware-backed.
/// - Key agreement key: Keychain, per Phase 1 (the Secure Enclave key is reserved for
///   signatures so pairing can rely on one stable identity).
public final class SecurityManager {
    private enum Account {
        static let signingKey = "device.signing.key"
        static let signingKeyStorage = "device.signing.storage"
        static let keyAgreementKey = "device.keyagreement.key"
    }

    private let keychain: KeychainManager
    private let logger: LoggingManager
    private let preferSecureEnclave: Bool
    private let lock = NSLock()
    private var cachedIdentity: DeviceIdentity?

    /// - Parameter preferSecureEnclave: set `false` to force the Keychain-backed key path
    ///   (used by tests so they do not leave Secure Enclave keys behind).
    public init(
        keychain: KeychainManager = KeychainManager(),
        logger: LoggingManager = .shared,
        preferSecureEnclave: Bool = false
    ) {
        self.keychain = keychain
        self.logger = logger
        self.preferSecureEnclave = preferSecureEnclave
    }

    public func loadOrCreateIdentity() throws -> DeviceIdentity {
        lock.lock()
        defer { lock.unlock() }

        if let cachedIdentity { return cachedIdentity }

        let signer = try loadOrCreateSigningKey()
        let keyAgreement = try loadOrCreateKeyAgreementKey()
        let identity = DeviceIdentity(
            deviceId: DeviceIdentifier.derive(from: signer.publicKey),
            signer: signer.signer,
            signingPublicKey: signer.publicKey,
            keyAgreementKey: keyAgreement,
            storage: signer.storage
        )
        cachedIdentity = identity
        logger.info("Identity ready: device \(identity.deviceId, privacy: .public), signing key in \(identity.storage.rawValue, privacy: .public)")
        return identity
    }

    /// Deletes every key this app owns. The next launch generates a new identity and
    /// therefore a new device id — this is the documented "reset" path.
    public func destroyIdentity() throws {
        lock.lock()
        defer { lock.unlock() }
        cachedIdentity = nil
        try keychain.delete(KeychainManager.Item(account: Account.signingKey))
        try keychain.delete(KeychainManager.Item(account: Account.signingKeyStorage))
        try keychain.delete(KeychainManager.Item(account: Account.keyAgreementKey))
        logger.notice("Device identity destroyed")
    }

    // MARK: - Signing key

    private struct LoadedSigner {
        let signer: EnvelopeSigner
        let publicKey: P256.Signing.PublicKey
        let storage: KeyStorage
    }

    private func loadOrCreateSigningKey() throws -> LoadedSigner {
        if let data = try keychain.read(KeychainManager.Item(account: Account.signingKey)),
           let storageRaw = try keychain.read(KeychainManager.Item(account: Account.signingKeyStorage)),
           let storageText = String(data: storageRaw, encoding: .utf8),
           let storage = KeyStorage(rawValue: storageText) {
            if storage == .secureEnclave {
                if let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data) {
                    return LoadedSigner(signer: key, publicKey: key.publicKey, storage: .secureEnclave)
                }
                logger.warning("Stored Secure Enclave key could not be reconstructed; falling back to a new software key")
            } else if let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
                return LoadedSigner(signer: key, publicKey: key.publicKey, storage: .keychain)
            }
        }

        return try createSigningKey()
    }

    private func createSigningKey() throws -> LoadedSigner {
        if preferSecureEnclave, SecureEnclave.isAvailable, let secureKey = try? makeSecureEnclaveKey() {
            try keychain.save(secureKey.dataRepresentation, for: KeychainManager.Item(account: Account.signingKey))
            try keychain.save(Data(KeyStorage.secureEnclave.rawValue.utf8), for: KeychainManager.Item(account: Account.signingKeyStorage))
            logger.notice("Generated new P-256 signing key in the Secure Enclave")
            return LoadedSigner(signer: secureKey, publicKey: secureKey.publicKey, storage: .secureEnclave)
        }

        let softwareKey = P256.Signing.PrivateKey()
        try keychain.save(softwareKey.rawRepresentation, for: KeychainManager.Item(account: Account.signingKey))
        try keychain.save(Data(KeyStorage.keychain.rawValue.utf8), for: KeychainManager.Item(account: Account.signingKeyStorage))
        logger.warning("Generated new P-256 signing key in the Keychain (Secure Enclave unavailable)")
        return LoadedSigner(signer: softwareKey, publicKey: softwareKey.publicKey, storage: .keychain)
    }

    private func makeSecureEnclaveKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw SecurityFailure.keyMaterialInvalid("access control")
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: accessControl)
    }

    // MARK: - Key agreement key

    private func loadOrCreateKeyAgreementKey() throws -> P256.KeyAgreement.PrivateKey {
        if let data = try keychain.read(KeychainManager.Item(account: Account.keyAgreementKey)) {
            do {
                return try P256.KeyAgreement.PrivateKey(rawRepresentation: data)
            } catch {
                logger.warning("Stored key agreement key is unusable; generating a replacement")
            }
        }
        let key = P256.KeyAgreement.PrivateKey()
        try keychain.save(key.rawRepresentation, for: KeychainManager.Item(account: Account.keyAgreementKey))
        logger.notice("Generated new P-256 key agreement key")
        return key
    }
}
