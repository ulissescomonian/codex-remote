import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = RemoteControlViewModel(service: RemoteControlService())
    let loginItemController = LoginItemController()

    private lazy var lifecycle = AppLifecycleCoordinator(
        viewModel: viewModel,
        loginItemController: loginItemController
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lifecycle.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycle.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Owns app-lifetime reconciliation independently from SwiftUI view rendering.
/// It reads preferences each cycle so changes made in Settings are observed
/// without recreating the menu bar scene.
@MainActor
final class AppLifecycleCoordinator {
    typealias Sleeper = @Sendable (UInt64) async throws -> Void

    private let viewModel: RemoteControlViewModel
    private let loginItemController: LoginItemController
    private let userDefaults: UserDefaults
    private let sleeper: Sleeper
    private var pollingTask: Task<Void, Never>?

    init(
        viewModel: RemoteControlViewModel,
        loginItemController: LoginItemController,
        userDefaults: UserDefaults = .standard,
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.viewModel = viewModel
        self.loginItemController = loginItemController
        self.userDefaults = userDefaults
        self.sleeper = sleeper
    }

    var isRunning: Bool { pollingTask != nil }

    func start() {
        guard pollingTask == nil else { return }
        loginItemController.reconcileOnLaunch()
        pollingTask = Task { [weak self] in
            await self?.runPollingLoop()
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func runCycle() async {
        await viewModel.reconcile(autoStart: autoStartPreference)
    }

    private func runPollingLoop() async {
        while !Task.isCancelled {
            await runCycle()
            guard !Task.isCancelled else { return }

            do {
                try await sleeper(refreshNanoseconds)
            } catch {
                return
            }
        }
    }

    private var autoStartPreference: Bool {
        userDefaults.object(forKey: AppPreferenceKey.autoStart) as? Bool
            ?? AppPreferenceDefault.autoStart
    }

    private var refreshNanoseconds: UInt64 {
        let configured = userDefaults.object(forKey: AppPreferenceKey.refreshInterval) as? Double
            ?? AppPreferenceDefault.refreshInterval
        return UInt64(max(configured, 5) * 1_000_000_000)
    }
}
