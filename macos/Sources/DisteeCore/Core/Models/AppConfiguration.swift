import Foundation

/// Runtime configuration. There is no hardcoded relay: the deployed host is chosen in
/// Phase 3, and until then the agent reports "relay not configured" rather than pretending
/// to connect.
public struct AppConfiguration {
    public enum Environment: String {
        case production
        case development
    }

    public var relayURL: URL?
    public var environment: Environment
    public var launchArguments: [String]

    public static let relayInfoKey = "DisteeRelayURL"

    public init(relayURL: URL?, environment: Environment = .production, launchArguments: [String] = []) {
        self.relayURL = relayURL
        self.environment = environment
        self.launchArguments = launchArguments
    }

    /// Resolution order:
    /// 1. `--dev-relay ws://…` (development only, logged as a warning)
    /// 2. `DisteeRelayURL` in Info.plist (production host, set at build/deploy time)
    /// 3. none — the app runs, shows "Relay not configured", and never retries in a loop
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> AppConfiguration {
        if let index = arguments.firstIndex(of: "--dev-relay"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            return AppConfiguration(relayURL: url, environment: .development, launchArguments: arguments)
        }

        if let envString = ProcessInfo.processInfo.environment["DISTEE_RELAY_URL"],
           !envString.isEmpty,
           let url = URL(string: envString) {
            return AppConfiguration(relayURL: url, environment: .development, launchArguments: arguments)
        }

        if let string = infoDictionary[relayInfoKey] as? String,
           !string.isEmpty,
           let url = URL(string: string) {
            return AppConfiguration(relayURL: url, environment: .production, launchArguments: arguments)
        }

        return AppConfiguration(relayURL: nil, environment: .production, launchArguments: arguments)
    }

    /// `wss://host/ws/device/<deviceId>` — the device side of the relay path.
    public func deviceURL(deviceId: String) -> URL? {
        guard let relayURL else { return nil }
        return relayURL.appendingPathComponent("ws/device/\(deviceId)")
    }

    public var isDevelopmentRelay: Bool { environment == .development }
}
