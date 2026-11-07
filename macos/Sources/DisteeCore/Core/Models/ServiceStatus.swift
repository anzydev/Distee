import Foundation

/// Everything the UI needs, in one immutable snapshot. Produced by `BackgroundService`.
public struct ServiceStatus: Equatable {
    public var isRunning: Bool
    public var connection: ConnectionState
    public var deviceId: String?
    public var keyStorage: KeyStorage?
    public var pairing: PairingSummary
    public var lastLockAt: Date?
    public var lastLockStatus: LockStatus?
    public var relayEndpoint: String?
    public var isDevelopmentRelay: Bool
    public var launchAtLoginEnabled: Bool
    public var loginItemMechanism: LoginItemManager.Mechanism
    public var lastError: String?
    public var startedAt: Date?

    public init(
        isRunning: Bool = false,
        connection: ConnectionState = .disconnected,
        deviceId: String? = nil,
        keyStorage: KeyStorage? = nil,
        pairing: PairingSummary = .notPaired,
        lastLockAt: Date? = nil,
        lastLockStatus: LockStatus? = nil,
        relayEndpoint: String? = nil,
        isDevelopmentRelay: Bool = false,
        launchAtLoginEnabled: Bool = false,
        loginItemMechanism: LoginItemManager.Mechanism = .none,
        lastError: String? = nil,
        startedAt: Date? = nil
    ) {
        self.isRunning = isRunning
        self.connection = connection
        self.deviceId = deviceId
        self.keyStorage = keyStorage
        self.pairing = pairing
        self.lastLockAt = lastLockAt
        self.lastLockStatus = lastLockStatus
        self.relayEndpoint = relayEndpoint
        self.isDevelopmentRelay = isDevelopmentRelay
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.loginItemMechanism = loginItemMechanism
        self.lastError = lastError
        self.startedAt = startedAt
    }

    public static let initial = ServiceStatus()

    public var isPaired: Bool {
        if case .paired = pairing { return true }
        return false
    }

    public var pairingLabel: String {
        switch pairing {
        case .notPaired: return "Not paired"
        case let .paired(label, epoch, _): return "\(label) · epoch \(epoch)"
        }
    }
}
