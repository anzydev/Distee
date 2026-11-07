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
    @State private var showQRCode: Bool = false

    var body: some View {
        VStack(spacing: 18) {
            if model.status.isPaired {
                pairedView
            } else if let session {
                codeSessionView(session)
            } else {
                startPairingView
            }
        }
        .padding(24)
        .frame(minWidth: 440)
        .onAppear {
            refreshState()
        }
        .onDisappear {
            timer?.invalidate()
        }
        .onChange(of: model.status.isPaired) { isPaired in
            if isPaired {
                timer?.invalidate()
                session = nil
                qrImage = nil
            } else {
                session = nil
                generateSession()
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

    // MARK: - 6-Digit Code & Optional QR View

    private func codeSessionView(_ session: PairingSession) -> some View {
        VStack(spacing: 16) {
            Text("Pair Mobile Device")
                .font(.title2.weight(.semibold))

            Text("Open the Distee web app on your phone and enter this code:")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            // Primary: Big 6-Digit Connection Code
            VStack(spacing: 6) {
                Text(session.formattedCode)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    )

                Text("distee.onrender.com")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            // Timer & Expiration
            if timeRemaining > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(timeRemaining < 30 ? .red : .secondary)
                    Text("Code expires in \(timeRemaining)s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(timeRemaining < 30 ? .red : .secondary)
                }
            } else {
                Text("Code Expired")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
            }

            // Optional QR Code Collapsible Toggle
            VStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showQRCode.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "qrcode")
                        Text(showQRCode ? "Hide QR Code" : "Scan QR Code Instead (Optional)")
                        Image(systemName: showQRCode ? "chevron.up" : "chevron.down")
                    }
                    .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.link)

                if showQRCode {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)

                        if let qrImage {
                            Image(nsImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(12)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: 180, height: 180)
                    .transition(.scale.combined(with: .opacity))
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 14) {
                Button("Generate New Code") {
                    generateSession()
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
            Image(systemName: "number.square")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("Pair with Mobile Phone")
                .font(.title2.weight(.semibold))

            Text("Pair your phone instantly using a 6-digit code or QR code. Distee uses end-to-end encryption with zero accounts or setup.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                generateSession()
            } label: {
                Label("Generate Pairing Code", systemImage: "number")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func refreshState() {
        if !model.status.isPaired && session == nil {
            generateSession()
        }
    }

    private func generateSession() {
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
            generateSession()
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
