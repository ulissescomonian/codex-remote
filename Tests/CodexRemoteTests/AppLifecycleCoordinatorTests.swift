import Foundation
import Testing
@testable import CodexRemote

@Suite("App Lifecycle Coordinator")
@MainActor
struct AppLifecycleCoordinatorTests {
    @Test("Each cycle reads the current automatic-start preference")
    func cyclesReadUpdatedAutoStartPreference() async {
        let suiteName = uniqueSuiteName
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppPreferenceKey.autoStart)
        let remote = LifecycleRemoteService()
        let coordinator = makeCoordinator(defaults: defaults, remote: remote)

        await coordinator.runCycle()
        #expect(await remote.startCallCount == 0)

        defaults.set(true, forKey: AppPreferenceKey.autoStart)
        await coordinator.runCycle()
        #expect(await remote.startCallCount == 1)
    }

    @Test("Start owns one polling task and stop cancels it")
    func startIsIdempotentAndStopCancelsPolling() async {
        let suiteName = uniqueSuiteName
        let defaults = makeDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppPreferenceKey.autoStart)
        let remote = LifecycleRemoteService()
        let loginService = LifecycleLoginItemService()
        let viewModel = RemoteControlViewModel(service: remote)
        let loginController = LoginItemController(
            service: loginService,
            userDefaults: defaults,
            preferenceKey: "lifecycle-login-item"
        )
        let coordinator = AppLifecycleCoordinator(
            viewModel: viewModel,
            loginItemController: loginController,
            userDefaults: defaults,
            sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )

        coordinator.start()
        coordinator.start()

        #expect(await waitUntil { await remote.statusCallCount == 1 })
        #expect(coordinator.isRunning)
        #expect(loginService.setEnabledCallCount == 1)

        coordinator.stop()
        #expect(!coordinator.isRunning)
    }

    private func makeCoordinator(
        defaults: UserDefaults,
        remote: LifecycleRemoteService
    ) -> AppLifecycleCoordinator {
        let viewModel = RemoteControlViewModel(service: remote)
        let loginController = LoginItemController(
            service: LifecycleLoginItemService(),
            userDefaults: defaults,
            preferenceKey: "lifecycle-login-item"
        )
        return AppLifecycleCoordinator(
            viewModel: viewModel,
            loginItemController: loginController,
            userDefaults: defaults,
            sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )
    }

    private var uniqueSuiteName: String { "CodexRemoteLifecycleTests-\(UUID().uuidString)" }

    private func makeDefaults(suiteName: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor LifecycleRemoteService: RemoteControlServicing {
    private(set) var statusCallCount = 0
    private(set) var startCallCount = 0

    func status() async -> DaemonState {
        statusCallCount += 1
        return .stopped
    }

    func start() async throws -> DaemonState {
        startCallCount += 1
        return .running(cliVersion: "test", appServerVersion: "test")
    }

    func stop() async throws -> DaemonState { .stopped }
    func restart() async throws -> DaemonState { .stopped }
    func pair() async throws -> PairingCode { PairingCode(manualCode: "TEST", expiresAt: nil) }
}

private final class LifecycleLoginItemService: LoginItemServicing, @unchecked Sendable {
    private(set) var setEnabledCallCount = 0
    private var currentStatus: LoginItemStatus = .notRegistered

    var status: LoginItemStatus { currentStatus }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCallCount += 1
        currentStatus = enabled ? .enabled : .notRegistered
    }

    func openSystemSettings() {}
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}
