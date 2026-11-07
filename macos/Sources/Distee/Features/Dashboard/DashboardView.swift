import AppKit
import DisteeCore
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                StatusCard(status: model.status, onPairTapped: {
                    openWindow(id: "pair")
                })
                IdentityCard(status: model.status)
                lockSection
                if let error = model.status.lastError {
                    Banner(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
                }
                footer
            }
            .padding(22)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Distee")
                    .font(.title2.weight(.semibold))
                Text("Remote lock for this Mac")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(
                text: model.status.isRunning ? "Running" : "Stopped",
                color: model.status.isRunning ? .green : .secondary
            )
        }
    }

    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Lock screen")
                    .font(.headline)
                Spacer()
                if model.status.isDevelopmentRelay {
                    Text("DEVELOPMENT")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }

            Text("Locks this Mac immediately. Locking happens locally; it does not require the phone.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    model.lockNow()
                } label: {
                    Label("Lock Now", systemImage: "lock.fill")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .controlSize(.large)

                if let outcome = model.lastLockOutcome {
                    LockOutcomeBadge(outcome: outcome)
                }
            }

            if model.lastLockOutcome?.status == .needsPermission || model.status.lastLockStatus == .needsPermission {
                Button("Open Accessibility Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text("Relay")
                Spacer()
                Text(model.status.relayEndpoint ?? "not configured")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("Signing key")
                Spacer()
                Text(model.status.keyStorage?.rawValue ?? "—")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Version")
                Spacer()
                Text(AppVersion.display)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Settings…") {
                    openWindow(id: "settings")
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct StatusCard: View {
    let status: ServiceStatus
    var onPairTapped: (() -> Void)? = nil

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                StatusRow(label: "Agent", value: status.isRunning ? "Running" : "Stopped",
                          color: status.isRunning ? .green : .secondary)
                Divider().padding(.leading, 8)
                StatusRow(label: "Connection", value: status.connection.displayName,
                          color: connectionColor)
                Divider().padding(.leading, 8)
                HStack {
                    StatusRow(label: "Pairing", value: status.pairingLabel,
                              color: status.isPaired ? .green : .secondary)
                    if !status.isPaired, let onPairTapped {
                        Spacer()
                        Button("Pair Phone…", action: onPairTapped)
                            .buttonStyle(.link)
                    }
                }
                Divider().padding(.leading, 8)
                StatusRow(label: "Last lock", value: lastLockText,
                          color: status.lastLockAt == nil ? .secondary : .primary)
            }
            .padding(.vertical, 2)
        }
    }

    private var connectionColor: Color {
        switch status.connection {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var lastLockText: String {
        guard let date = status.lastLockAt else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct IdentityCard: View {
    let status: ServiceStatus

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Device identifier")
                    .font(.subheadline.weight(.medium))

                HStack(spacing: 8) {
                    Text(status.deviceId ?? "unavailable")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(status.deviceId ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy device identifier")
                    .disabled(status.deviceId == nil)
                }

                Text("Derived from this Mac's public key. It is not a secret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        }
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    var color: Color = .primary

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(value)
                    .foregroundStyle(color == .primary ? Color.primary : color)
            }
        }
        .font(.callout)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

struct LockOutcomeBadge: View {
    let outcome: LockOutcome

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var symbol: String {
        switch outcome.status {
        case .locked: return "checkmark.circle.fill"
        case .alreadyLocked: return "checkmark.circle"
        case .needsPermission: return "lock.badge.clock"
        case .unverified: return "questionmark.circle"
        case .failed: return "xmark.circle"
        }
    }

    private var tint: Color {
        switch outcome.status {
        case .locked, .alreadyLocked: return .green
        case .needsPermission, .unverified: return .orange
        case .failed: return .red
        }
    }

    private var text: String {
        switch outcome.status {
        case .locked: return "Locked · \(outcome.durationMilliseconds) ms"
        case .alreadyLocked: return "Already locked"
        case .needsPermission: return "Accessibility needed"
        case .unverified: return "Unverified"
        case .failed: return "Failed"
        }
    }
}

struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

enum AppVersion {
    static var display: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
