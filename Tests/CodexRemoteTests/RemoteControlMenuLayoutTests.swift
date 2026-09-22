import AppKit
import SwiftUI
import Testing
@testable import CodexRemote

@Suite("Remote Control Menu Layout")
@MainActor
struct RemoteControlMenuLayoutTests {
    @Test("Normal controls and a long error keep identical menu geometry")
    func contentChangesDoNotResizeMenu() {
        let viewModel = RemoteControlViewModel(service: LayoutRemoteControlService())
        let normalSize = fittingSize(of: viewModel)

        viewModel.lastError = String(
            repeating: "O servidor remoto recusou o pareamento para a conta atual. ",
            count: 12
        )
        let errorSize = fittingSize(of: viewModel)

        #expect(normalSize == NSSize(width: 324, height: 238))
        #expect(errorSize == normalSize)
    }

    private func fittingSize(of viewModel: RemoteControlViewModel) -> NSSize {
        let hostingView = NSHostingView(rootView: RemoteControlMenu(viewModel: viewModel))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize
    }
}

private struct LayoutRemoteControlService: RemoteControlServicing {
    func status() async -> DaemonState { .stopped }
    func start() async throws -> DaemonState { .stopped }
    func stop() async throws -> DaemonState { .stopped }
    func restart() async throws -> DaemonState { .stopped }
    func pair() async throws -> PairingCode { throw RemoteControlError.invalidPairingResponse }
}
