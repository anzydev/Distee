import Foundation
import ServiceManagement

/// Login-item management. `SMAppService.mainApp` is the supported API on macOS 13+.
/// Because the app is ad-hoc signed (Phase 1, ADR-013) registration can be refused; in that
/// case a per-user `LaunchAgent` plist is written instead, and the active mechanism is
/// reported rather than silently assumed.
public final class LoginItemManager {
    public enum Mechanism: String, Equatable {
        case smAppService = "SMAppService"
        case launchAgent = "LaunchAgent"
        case none = "None"
    }

    public struct Status: Equatable {
        public let enabled: Bool
        public let mechanism: Mechanism
        public let detail: String?
    }

    public static let launchAgentLabel = "com.distee.agent"

    private let logger: LoggingManager
    private let fileManager: FileManager

    public init(logger: LoggingManager = .shared, fileManager: FileManager = .default) {
        self.logger = logger
        self.fileManager = fileManager
    }

    public var launchAgentURL: URL? {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist")
    }

    public func status() -> Status {
        let service = SMAppService.mainApp
        if service.status == .enabled {
            return Status(enabled: true, mechanism: .smAppService, detail: nil)
        }
        if let url = launchAgentURL, fileManager.fileExists(atPath: url.path) {
            return Status(enabled: true, mechanism: .launchAgent, detail: "LaunchAgent plist present")
        }
        return Status(enabled: false, mechanism: .none, detail: statusDescription(service.status))
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            do {
                try SMAppService.mainApp.register()
                logger.notice("Registered login item with SMAppService")
                removeLaunchAgent()
                return
            } catch {
                logger.warning("SMAppService registration failed (\(error.localizedDescription, privacy: .public)); using LaunchAgent fallback")
                try installLaunchAgent()
                return
            }
        }

        if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
            logger.notice("Unregistered login item from SMAppService")
        }
        removeLaunchAgent()
    }

    // MARK: - LaunchAgent fallback

    private func installLaunchAgent() throws {
        guard let url = launchAgentURL else {
            throw NSError(domain: "com.distee.loginitem", code: 1, userInfo: [NSLocalizedDescriptionKey: "No home directory"])
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": Self.launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        logger.notice("Installed LaunchAgent at \(url.path, privacy: .public)")
    }

    private func removeLaunchAgent() {
        guard let url = launchAgentURL, fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
        logger.notice("Removed LaunchAgent")
    }

    private func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Enabled"
        case .notRegistered: return "Not registered"
        case .notFound: return "Service not found"
        case .requiresApproval: return "Requires approval in System Settings"
        @unknown default: return "Unknown"
        }
    }
}
