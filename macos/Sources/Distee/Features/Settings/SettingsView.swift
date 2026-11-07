import AppKit
import DisteeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showResetConfirmation = false
    @State private var copied = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Distee at login", isOn: Binding(
                    get: { model.status.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Text(loginItemDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background") {
                LabeledContent("Status", value: model.status.isRunning ? "Running" : "Stopped")
                LabeledContent("Mechanism", value: "Menu bar agent (no window required)")
                LabeledContent("Closing the window", value: "Keeps Distee running")
                LabeledContent("Uptime", value: uptime)
            }

            Section("Security") {
                LabeledContent("Signing key", value: model.status.keyStorage?.rawValue ?? "unavailable")
                LabeledContent("Device identifier", value: model.status.deviceId ?? "unavailable")
                LabeledContent("Paired phone", value: model.status.pairingLabel)
            }

            Section("Diagnostics") {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button(copied ? "Copied" : "Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnosticsText, forType: .string)
                        copied = true
                    }
                    Button("Clear log") {
                        LoggingManager.shared.clear()
                        copied = false
                    }
                    Spacer()
                    Button("Reveal log in Console") {
                        openConsole()
                    }
                    .buttonStyle(.link)
                }
            }

            Section {
                LabeledContent("Version", value: AppVersion.display)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                HStack {
                    Spacer()
                    Button("Reset Distee…", role: .destructive) {
                        showResetConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Reset Distee?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                model.reset()
            }
        } message: {
            Text("This deletes this Mac's device key, its pairing record and its launch-at-login item. The Mac will need to be paired again. This cannot be undone.")
        }
    }

    private var loginItemDetail: String {
        let status = model.status
        if status.launchAtLoginEnabled {
            return "Registered via \(status.loginItemMechanism.rawValue)."
        }
        return "Not registered. Distee will not start automatically after you log in."
    }

    private var uptime: String {
        guard let started = model.status.startedAt else { return "—" }
        let seconds = Int(Date().timeIntervalSince(started))
        let minutes = seconds / 60
        if minutes < 1 { return "\(seconds) s" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private var logText: String {
        let text = LoggingManager.shared.formatted()
        return text.isEmpty ? "No events recorded yet." : text
    }

    private var diagnosticsText: String {
        """
        Distee diagnostics
        version: \(AppVersion.display)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        device id: \(model.status.deviceId ?? "unavailable")
        signing key: \(model.status.keyStorage?.rawValue ?? "unavailable")
        connection: \(model.status.connection.displayName)
        pairing: \(model.status.pairingLabel)
        relay: \(model.status.relayEndpoint ?? "not configured")
        login item: \(model.status.launchAtLoginEnabled ? model.status.loginItemMechanism.rawValue : "disabled")
        last error: \(model.status.lastError ?? "none")

        --- log ---
        \(logText)
        """
    }

    private func openConsole() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Console", "--args", "--predicate", "subsystem == \"com.distee.agent\""]
        try? task.run()
    }
}
