import Foundation

/// Secret store for every key the agent owns.
///
/// **Zero-Keychain Architecture**:
///
/// Secrets are stored purely in the user-private directory at
/// `~/Library/Application Support/<service>/secrets/`
/// Permissions: Directory 0700 (owner only), each file 0600 (owner read/write only).
///
/// This completely bypasses the macOS Login Keychain, guaranteeing that macOS
/// will NEVER display a keychain password prompt or authorization dialog.
public final class KeychainManager {
    public struct Item {
        public let account: String
        public init(account: String) { self.account = account }
    }

    public enum KeychainFailure: Error, Equatable {
        case unexpectedStatus(Int32)
        case dataCorrupted
    }

    private let service: String

    public init(service: String = "com.distee.agent") {
        self.service = service
    }

    public var serviceName: String { service }

    // MARK: - Private file store

    private var secretsDir: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("\(service)/secrets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return dir
    }

    private func fileURL(for item: Item) -> URL {
        secretsDir.appendingPathComponent("\(item.account).dat")
    }

    // MARK: - Public API

    /// Saves `data` for `item` to user-private store with 0600 permissions.
    public func save(_ data: Data, for item: Item) throws {
        let url = fileURL(for: item)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Reads the secret for `item`, or `nil` if it has never been saved.
    public func read(_ item: Item) throws -> Data? {
        let url = fileURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Deletes the secret for `item`.
    public func delete(_ item: Item) throws {
        let url = fileURL(for: item)
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes every item this service owns (used by "Reset application").
    public func deleteAll() throws {
        try? FileManager.default.removeItem(at: secretsDir)
    }
}
