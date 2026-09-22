import AppKit
import SwiftUI

struct RemoteControlMenu: View {
    @ObservedObject var viewModel: RemoteControlViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusHeader
                .frame(height: 48, alignment: .top)

            Divider()

            contentPanel

            Divider()

            HStack(spacing: 12) {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Atualizar", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(viewModel.isBusy)

                Spacer(minLength: 0)

                SettingsLink {
                    Label("Ajustes…", systemImage: "gearshape")
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Sair", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(12)
        .frame(width: 324, height: 238, alignment: .top)
    }

    @ViewBuilder
    private var contentPanel: some View {
        Group {
            if let error = viewModel.lastError {
                errorPanel(error)
            } else if let warning = viewModel.lastWarning {
                warningPanel(warning)
            } else {
                actionControls
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: 104, alignment: .center)
    }

    private var actionControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                actionButton("Iniciar", systemImage: "play.fill", enabled: viewModel.canStart) {
                    await viewModel.start()
                }

                actionButton("Parar", systemImage: "stop.fill", enabled: viewModel.canStop) {
                    await viewModel.stop()
                }

                actionButton("Reiniciar", systemImage: "arrow.clockwise", enabled: viewModel.canStop) {
                    await viewModel.restart()
                }
            }

            Button {
                Task {
                    await viewModel.pair()
                    guard viewModel.pairingCode != nil else { return }
                    openWindow(id: "pairing")
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Label("Parear novo dispositivo…", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
            .disabled(!viewModel.canPair)
        }
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: viewModel.menuBarSymbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(viewModel.statusTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .layoutPriority(1)

                    if viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer(minLength: 0)
                }

                if let detail = viewModel.statusDetail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let checked = viewModel.lastCheckedAt {
                    Text("Verificado às \(checked.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Aguardando primeira verificação")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch viewModel.daemonState {
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .unknown:
            return .orange
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping @MainActor () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .disabled(!enabled)
    }

    private func warningPanel(_ warning: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Aviso do último início", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            ScrollView(.vertical) {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 40)

            HStack {
                Spacer()
                Button("Descartar") {
                    viewModel.clearWarning()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Último erro", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            ScrollView(.vertical) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 40)

            HStack {
                if viewModel.pairingSetupRequired {
                    Button("Abrir ChatGPT") {
                        openChatGPT()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
                Button("Descartar") {
                    viewModel.clearError()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func openChatGPT() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) else {
            NSWorkspace.shared.open(
                URL(string: "https://learn.chatgpt.com/docs/remote-connections")!
            )
            return
        }

        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

}
