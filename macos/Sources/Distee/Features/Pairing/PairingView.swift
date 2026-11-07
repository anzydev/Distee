import AppKit
import CoreImage
import DisteeCore
import SwiftUI

@MainActor
struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var qrImage: NSImage?
    @State private var session: PairingSession?
    @State private var timeRemaining: Int = 120
    @State private var timer: Timer?
    @State private var errorMessage: String?
    @State private var customWebURL: String = PairingManager.resolveWebBaseURL()
    @State private var isEditingURL: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            if model.status.isPaired {
                pairedView
            } else if let session {
                qrSessionView(session)
            } else {
                startPairingView
            }
        }
        .padding(24)
        .frame(minWidth: 420)
        .onAppear {
            refreshState()
        }
        .onDisappear {
            timer?.invalidate()
        }
        .onChange(of: model.status.isPaired) { isPaired in
            // Unpairing from the menu bar or from the phone must not leave a stale, already
            // invalid QR on screen; pairing completing must stop the countdown.
            if isPaired {
                timer?.invalidate()
                session = nil
                qrImage = nil
            } else {
                session = nil
                generateQR()
            }
        }
    }

    // MARK: - Paired State View

    private var pairedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("This Mac is Paired")
                .font(.title2.weight(.semibold))

            Text("Authorized Device: \(model.status.pairingLabel)")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("Only this authorized mobile device can send remote lock commands. To authorize another device, you must unpair first.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Divider().padding(.vertical, 8)

            Button(role: .destructive) {
                unpairDevice()
            } label: {
                Label("Unpair Device", systemImage: "xmark.circle")
            }
            .controlSize(.large)
        }
    }

    // MARK: - QR Display View

    private func qrSessionView(_ session: PairingSession) -> some View {
        VStack(spacing: 14) {
            Text("Scan to Pair")
                .font(.title2.weight(.semibold))

            Text("Open the Distee mobile web app on your phone and scan this QR code.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)

                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 260, height: 260)

            // Timer & Expiration
            if timeRemaining > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(timeRemaining < 30 ? .red : .secondary)
                    Text("Expires in \(timeRemaining)s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(timeRemaining < 30 ? .red : .secondary)
                }
            } else {
                Text("QR Code Expired")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            }

            // Target Web URL Display & Configuration
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "network")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(customWebURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button {
                        isEditingURL.toggle()
                    } label: {
                        Image(systemName: isEditingURL ? "chevron.up.circle.fill" : "pencil.circle")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Change base URL (e.g. for tunnel or hosted web app)")
                }

                if isEditingURL {
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            TextField("http://192.168.x.x:8799", text: $customWebURL)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced())

                            Button("Apply") {
                                isEditingURL = false
                                generateQR()
                            }
                            .controlSize(.small)
                        }

                        if let lan = PairingManager.localIPAddress() {
                            HStack {
                                Button("Use Wi-Fi IP (:\(8799))") {
                                    customWebURL = "http://\(lan):8799"
                                    isEditingURL = false
                                    generateQR()
                                }
                                .controlSize(.mini)
                                .buttonStyle(.bordered)

                                Button("Use Vite Dev (:\(5173))") {
                                    customWebURL = "http://\(lan):5173"
                                    isEditingURL = false
                                    generateQR()
                                }
                                .controlSize(.mini)
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }

                Text("Phone and Mac must be on the same Wi-Fi, or use a public URL / tunnel.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 12) {
                Button("Regenerate QR") {
                    generateQR()
                }
                .controlSize(.regular)

                Button("Copy Pairing URL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.qrPayload, forType: .string)
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Start Pairing View

    private var startPairingView: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Pair with Mobile Phone")
                .font(.title2.weight(.semibold))

            Text("Pair your phone using a secure 120-second single-use QR code. Distee uses end-to-end encryption with no accounts or passwords.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                generateQR()
            } label: {
                Label("Generate Pairing QR", systemImage: "qrcode")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func refreshState() {
        if !model.status.isPaired && session == nil {
            generateQR()
        }
    }

    private func generateQR() {
        errorMessage = nil
        timer?.invalidate()
        do {
            let urlToUse = customWebURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSession = try model.service.pairingManager.startPairingSession(
                webBaseURL: urlToUse.isEmpty ? nil : urlToUse
            )
            self.session = newSession
            self.timeRemaining = newSession.secondsRemaining
            self.qrImage = generateQRCodeImage(from: newSession.qrPayload)

            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    if timeRemaining > 0 {
                        timeRemaining -= 1
                    } else {
                        timer?.invalidate()
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unpairDevice() {
        do {
            try model.service.pairingManager.unpair()
            session = nil
            generateQR()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func generateQRCodeImage(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = output.transformed(by: transform)
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }
}

