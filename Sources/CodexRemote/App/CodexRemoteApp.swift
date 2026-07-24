import SwiftUI

@main
struct CodexRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            RemoteControlMenu(viewModel: appDelegate.viewModel)
        } label: {
            MenuBarStatusLabel(viewModel: appDelegate.viewModel)
        }
        .menuBarExtraStyle(.window)

        Window("Parear Codex Remote", id: "pairing") {
            PairingView(viewModel: appDelegate.viewModel)
        }
        .defaultSize(width: 400, height: 500)
        .windowResizability(.contentSize)

        Settings {
            PreferencesView(loginItemController: appDelegate.loginItemController)
        }
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var viewModel: RemoteControlViewModel

    var body: some View {
        Image(systemName: viewModel.menuBarSymbol)
            .accessibilityLabel("Codex Remote: \(viewModel.statusTitle)")
    }
}
