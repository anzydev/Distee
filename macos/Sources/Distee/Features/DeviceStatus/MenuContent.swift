import AppKit
import CryptoKit
import DisteeCore
import Foundation
import SwiftUI

/// Menu-bar menu. Every item here is an action the agent can genuinely perform today;
/// pairing actions appear in Phase 3.
@MainActor
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Distee — \(model.status.connection.displayName)")
        Text(pairingLine)

        Divider()

        Button("Open Distee") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        if !model.status.isPaired {
            Button("Pair Phone…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "pair")
            }
        } else {
            Button("Unpair Phone") {
                try? model.service.pairingManager.unpair()
            }
        }

        Button("Lock Now") {
            model.lockNow()
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { model.status.launchAtLoginEnabled },
            set: { model.setLaunchAtLogin($0) }
        ))

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }

        Divider()

        Button("Quit Distee") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var pairingLine: String {
        model.status.isPaired ? model.status.pairingLabel : "Not paired"
    }
}

/// Development-only diagnostics printed by `Distee.app/Contents/MacOS/Distee --diagnose`.
enum DiagnosticsReporter {
    static func run() {
        let configuration = AppConfiguration.resolve()
        let screen = SystemScreenState()
        let identity = try? SecurityManager().loadOrCreateIdentity()
        let login = LoginItemManager().status()

        print("Distee diagnostics")
        print("  macOS:                 \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  device id:             \(identity?.deviceId ?? "unavailable")")
        print("  signing key storage:   \(identity?.storage.rawValue ?? "unavailable")")
        print("  secure enclave:        \(SecureEnclave.isAvailable ? "available" : "unavailable")")
        print("  screen locked:         \(screen.isLocked)")
        print("  accessibility:         \(screen.isAccessibilityTrusted ? "granted" : "not granted")")
        print("  lock on display sleep: \(screen.locksImmediatelyOnDisplaySleep ? "yes (password immediate)" : "no")")
        print("  relay:                 \(configuration.relayURL?.absoluteString ?? "not configured")")
        print("  relay environment:     \(configuration.environment.rawValue)")
        print("  login item:            \(login.enabled ? login.mechanism.rawValue : "disabled")")
        print("  bundle path:           \(Bundle.main.bundlePath)")
    }

    static func format(outcome: LockOutcome) -> String {
        "DISTEE_LOCK_RESULT status=\(outcome.status.rawValue) mechanism=\(outcome.mechanism.rawValue) durationMs=\(outcome.durationMilliseconds) detail=\(outcome.detail ?? "-")"
    }
}
