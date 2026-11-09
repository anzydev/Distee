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
    /// Central relay used for the fleet/emergency "Lock All" panel. Every Mac registers here
    /// in addition to its primary relay, so the panel sees the whole fleet even when agents
    /// are paired/published on different relays.
    public var fleetRelayURL: URL?
    public var environment: Environment
    public var launchArguments: [String]

    public static let relayInfoKey = "DisteeRelayURL"
    public static let fleetRelayInfoKey = "DisteeFleetRelayURL"

    public init(
        relayURL: URL?,
        fleetRelayURL: URL? = nil,
        environment: Environment = .production,
        launchArguments: [String] = []
    ) {
        self.relayURL = relayURL
        self.fleetRelayURL = fleetRelayURL
        self.environment = environment
        self.launchArguments = launchArguments
    }

    /// Resolution order:
    /// 1. `--dev-relay ws://…` (development only, logged as a warning)
    /// 2. `DisteeRelayURL` in Info.plist (production host, set at build/deploy time)
    /// 3. none — the app runs, shows "Relay not configured", and never retries in a loop
    ///
    /// The fleet relay resolves independently (`--fleet-relay`, `DISTEE_FLEET_RELAY`,
    /// `DisteeFleetRelayURL`) so a `--dev-relay` Mac still reports itself to the fleet.
    public static func resolve(
        arguments: [String] = CommandLine.arguments,
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> AppConfiguration {
        let fleetRelayURL = resolveFleetRelay(arguments: arguments, infoDictionary: infoDictionary)

        if let index = arguments.firstIndex(of: "--dev-relay"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            return AppConfiguration(
                relayURL: url,
                fleetRelayURL: fleetRelayURL,
                environment: .development,
                launchArguments: arguments
            )
        }

        if let envString = ProcessInfo.processInfo.environment["DISTEE_RELAY_URL"],
           !envString.isEmpty,
           let url = URL(string: envString) {
            return AppConfiguration(
                relayURL: url,
                fleetRelayURL: fleetRelayURL,
                environment: .development,
                launchArguments: arguments
            )
        }

        if let string = infoDictionary[relayInfoKey] as? String,
           !string.isEmpty,
           let url = URL(string: string) {
            return AppConfiguration(
                relayURL: url,
                fleetRelayURL: fleetRelayURL,
                environment: .production,
                launchArguments: arguments
            )
        }

        return AppConfiguration(
            relayURL: nil,
            fleetRelayURL: fleetRelayURL,
            environment: .production,
            launchArguments: arguments
        )
    }

    private static func resolveFleetRelay(
        arguments: [String],
        infoDictionary: [String: Any]
    ) -> URL? {
        if let index = arguments.firstIndex(of: "--fleet-relay"), index + 1 < arguments.count {
            return URL(string: arguments[index + 1])
        }
        if let envString = ProcessInfo.processInfo.environment["DISTEE_FLEET_RELAY"] {
            if envString == "none" || envString == "off" { return nil }
            if !envString.isEmpty, let url = URL(string: envString) { return url }
        }
        if let string = infoDictionary[fleetRelayInfoKey] as? String,
           !string.isEmpty,
           let url = URL(string: string) {
            return url
        }
        return nil
    }

    /// `wss://host/ws/device/<deviceId>` — the device side of the relay path.
    public func deviceURL(deviceId: String) -> URL? {
        guard let relayURL else { return nil }
        return relayURL.appendingPathComponent("ws/device/\(deviceId)")
    }

    /// `wss://host/ws/device/<deviceId>` for the fleet relay.
    public func fleetDeviceURL(deviceId: String) -> URL? {
        guard let fleetRelayURL else { return nil }
        return fleetRelayURL.appendingPathComponent("ws/device/\(deviceId)")
    }

    public var isDevelopmentRelay: Bool { environment == .development }
}
