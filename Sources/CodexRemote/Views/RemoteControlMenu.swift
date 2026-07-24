import AppKit
import SwiftUI

struct RemoteControlMenu: View {
    @ObservedObject var viewModel: RemoteControlViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusHeader

            Divider()

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
            .controlSize(.large)
            .disabled(!viewModel.canPair)

            if let warning = viewModel.lastWarning {
                warningPanel(warning)
            }

            if let error = viewModel.lastError {
                errorPanel(error)
            }

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
        }
        .padding(16)
        .frame(width: 324)
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: viewModel.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(statusColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(viewModel.statusTitle)
                        .font(.headline)

                    if viewModel.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let detail = viewModel.statusDetail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let checked = viewModel.lastCheckedAt {
                    Text("Verificado às \(checked.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Aguardando primeira verificação")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
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
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .disabled(!enabled)
    }

    private func warningPanel(_ warning: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Aviso do último início", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)

            Text(warning)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Descartar") {
                    viewModel.clearWarning()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorPanel(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Último erro", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)

            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Descartar") {
                    viewModel.clearError()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
