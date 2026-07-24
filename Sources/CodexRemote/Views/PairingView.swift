import AppKit
import SwiftUI

struct PairingView: View {
    @ObservedObject var viewModel: RemoteControlViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var qrImage: CGImage?
    @State private var qrGenerationFailed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Parear novo dispositivo")
                .font(.headline)

            if let pairingCode = viewModel.pairingCode {
                qrCodeSection(for: pairingCode)

                if let manualCode = pairingCode.manualCode {
                    manualCodeSection(manualCode)
                }

                if let expiresAt = pairingCode.expiresAt {
                    expirationLabel(expiresAt)
                }

                actionButtons(manualCode: pairingCode.manualCode)
            } else {
                Text("Este código não está mais disponível.")
                    .foregroundStyle(.secondary)

                Button("Fechar") { close() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 352)
        .padding(24)
        .onAppear {
            updateQRCode(for: viewModel.pairingCode?.qrPayload)
        }
        .onChange(of: viewModel.pairingCode?.qrPayload) { _, payload in
            updateQRCode(for: payload)
        }
        .onChange(of: viewModel.pairingCode?.manualCode) {
            copied = false
        }
        .onDisappear {
            clearQRCode()
            viewModel.dismissPairingCode()
        }
    }

    @ViewBuilder
    private func qrCodeSection(for pairingCode: PairingCode) -> some View {
        if pairingCode.qrPayload != nil, let qrImage {
            VStack(spacing: 10) {
                Text("Escaneie o QR Code com a câmera do celular.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 184, height: 184)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("QR Code de pareamento")
                    .accessibilityHint("Escaneie com a câmera do celular para parear o dispositivo")
            }
        } else if pairingCode.qrPayload == nil || qrGenerationFailed {
            Label(
                "QR indisponível nesta versão do Codex. Use o código manual.",
                systemImage: "qrcode"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            ProgressView("Preparando QR Code…")
                .controlSize(.small)
        }
    }

    private func manualCodeSection(_ manualCode: String) -> some View {
        VStack(spacing: 7) {
            Text("Ou use o código manual")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(manualCode)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .textSelection(.enabled)
                .accessibilityLabel("Código manual")
                .accessibilityValue(manualCode)
        }
    }

    private func expirationLabel(_ expiresAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Group {
                if expiresAt > context.date {
                    Text("Expira \(expiresAt, style: .relative)")
                } else {
                    Text("Código expirado")
                }
            }
            .font(.caption)
            .foregroundStyle(expiresAt > context.date ? Color.secondary : Color.orange)
        }
    }

    private func actionButtons(manualCode: String?) -> some View {
        HStack {
            if let manualCode {
                Button(copied ? "Copiado" : "Copiar código") {
                    copy(manualCode)
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Copia o código manual para a área de transferência")
            }

            Button("Fechar") { close() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
    }

    private func close() {
        clearQRCode()
        viewModel.dismissPairingCode()
        dismiss()
    }

    private func updateQRCode(for payload: String?) {
        clearQRCode()
        guard let payload else { return }

        do {
            qrImage = try PairingQRCodeGenerator().makeImage(for: payload)
        } catch {
            qrGenerationFailed = true
        }
    }

    private func clearQRCode() {
        qrImage = nil
        qrGenerationFailed = false
    }
}
