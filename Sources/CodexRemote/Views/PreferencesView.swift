import AppKit
import SwiftUI

struct PreferencesView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppPreferenceKey.autoStart) private var autoStart = AppPreferenceDefault.autoStart
    @AppStorage(AppPreferenceKey.customCodexPath) private var customCodexPath = ""
    @AppStorage(AppPreferenceKey.refreshInterval) private var refreshInterval = AppPreferenceDefault.refreshInterval

    @ObservedObject private var loginItemController: LoginItemController

    init(loginItemController: LoginItemController) {
        self.loginItemController = loginItemController
    }

    var body: some View {
        Form {
            Section("Inicialização") {
                Toggle("Iniciar e manter o Remote Control ativo", isOn: $autoStart)
                Text("Se o daemon parar inesperadamente, inclusive após um update, o Codex Remote tenta reparar com segurança e iniciá-lo novamente. A ação Parar pausa essa recuperação até você iniciar manualmente ou reabrir o app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Abrir Codex Remote ao iniciar sessão", isOn: launchAtLoginBinding)
                    .disabled(loginItemController.isBusy)

                LabeledContent("Estado no macOS") {
                    HStack(spacing: 6) {
                        if loginItemController.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(loginItemStatusTitle)
                            .foregroundStyle(loginItemStatusColor)
                    }
                }

                if loginItemController.status == .requiresApproval {
                    Text("O macOS exige sua aprovação para permitir que o Codex Remote abra ao iniciar sessão.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Abrir Ajustes do Sistema") {
                        loginItemController.openSystemSettings()
                    }
                }

                if loginItemController.status != .requiresApproval,
                   let errorMessage = loginItemController.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Codex CLI") {
                HStack {
                    TextField("Detectar automaticamente", text: $customCodexPath)
                    Button("Escolher…") { chooseExecutable() }
                }
                Text("Deixe vazio para localizar o executável automaticamente.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Picker("Atualizar a cada", selection: $refreshInterval) {
                    Text("5 segundos").tag(5.0)
                    Text("15 segundos").tag(15.0)
                    Text("30 segundos").tag(30.0)
                    Text("1 minuto").tag(60.0)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 430)
        .onAppear {
            loginItemController.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                loginItemController.refresh()
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItemController.desiredEnabled },
            set: { loginItemController.setDesiredEnabled($0) }
        )
    }

    private var loginItemStatusTitle: String {
        switch loginItemController.status {
        case .enabled:
            "Ativado"
        case .notRegistered:
            "Desativado"
        case .requiresApproval:
            "Aguardando aprovação"
        case .notFound:
            "Aplicativo não encontrado"
        }
    }

    private var loginItemStatusColor: Color {
        switch loginItemController.status {
        case .enabled:
            .green
        case .notRegistered:
            .secondary
        case .requiresApproval:
            .orange
        case .notFound:
            .red
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Escolha o executável Codex"
        panel.prompt = "Escolher"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customCodexPath = url.path
    }
}
