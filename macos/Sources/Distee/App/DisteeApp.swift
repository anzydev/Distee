import SwiftUI
import DisteeCore

@main
struct DisteeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.status.isRunning ? "lock.shield.fill" : "lock.shield")
                .accessibilityLabel("Distee")
        }
        .menuBarExtraStyle(.menu)

        Window("Distee", id: "main") {
            DashboardView(model: model)
                .frame(minWidth: 480, minHeight: 560)
        }
        .defaultSize(width: 520, height: 620)
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView(model: model)
                .frame(width: 480, height: 460)
        }
        .windowResizability(.contentSize)

        Window("Pair Device", id: "pair") {
            PairingView(model: model)
                .frame(width: 440, height: 520)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let arguments = CommandLine.arguments
        if arguments.contains("--diagnose") {
            DiagnosticsReporter.run()
            exit(0)
        }
        if arguments.contains("--lock-now") {
            // Development-only trigger: performs a real lock attempt and exits.
            Task {
                let outcome = await AppModel.shared.service.performLockNow()
                print(DiagnosticsReporter.format(outcome: outcome))
                fflush(stdout)
                exit(outcome.status.isSuccess ? 0 : 2)
            }
            return
        }

        AppModel.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window must not stop the agent.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.service.stopSynchronously()
    }
}

/// Bridges the core service to SwiftUI. `@MainActor` so every published change is a view update.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var status: ServiceStatus = .initial
    @Published private(set) var lastLockOutcome: LockOutcome?

    let service: BackgroundService

    private init() {
        let configuration = AppConfiguration.resolve()
        service = BackgroundService(configuration: configuration)
        service.onStatusChange = { [weak self] snapshot in
            self?.status = snapshot
        }
        status = service.statusSnapshot
    }

    func start() {
        service.start()
        status = service.statusSnapshot
    }

    func lockNow() {
        Task {
            let outcome = await service.performLockNow()
            lastLockOutcome = outcome
            status = service.statusSnapshot
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try service.setLaunchAtLogin(enabled)
        } catch {
            status.lastError = "Could not change login item: \(error.localizedDescription)"
        }
        status = service.statusSnapshot
    }

    func reset() {
        service.resetApplication()
        status = service.statusSnapshot
        lastLockOutcome = nil
    }
}
