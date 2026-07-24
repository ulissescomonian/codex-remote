import Foundation
import Testing
@testable import CodexRemote

@Suite("Remote Control View Model")
@MainActor
struct RemoteControlViewModelTests {
    @Test("Stopped daemon starts when automatic start is enabled")
    func stoppedDaemonStartsWhenEnabled() async {
        let service = FakeRemoteControlService(statuses: [.stopped])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: true)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == .running(cliVersion: "test", appServerVersion: "test"))
    }

    @Test("Running daemon is not started again")
    func runningDaemonDoesNotStart() async {
        let service = FakeRemoteControlService(statuses: [.running(cliVersion: nil, appServerVersion: nil)])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: true)

        #expect(await service.startCallCount == 0)
    }

    @Test("Stopped daemon remains stopped when automatic start is disabled")
    func disabledAutomaticStartDoesNotStart() async {
        let service = FakeRemoteControlService(statuses: [.stopped])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: false)

        #expect(await service.startCallCount == 0)
        #expect(viewModel.daemonState == .stopped)
    }

    @Test("A daemon that stops after running is recovered automatically")
    func runningThenStoppedRecovers() async {
        let service = FakeRemoteControlService(statuses: [
            .running(cliVersion: nil, appServerVersion: nil),
            .stopped,
        ])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: true)
        await viewModel.reconcile(autoStart: true)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == .running(cliVersion: "test", appServerVersion: "test"))
    }

    @Test("Manual stop suppresses recovery on the next reconciliation")
    func manualStopSuppressesAutomaticRecovery() async {
        let service = FakeRemoteControlService(statuses: [
            .running(cliVersion: nil, appServerVersion: nil),
            .stopped,
        ])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: true)
        await viewModel.stop()
        await viewModel.reconcile(autoStart: true)

        #expect(await service.stopCallCount == 1)
        #expect(await service.startCallCount == 0)
        #expect(viewModel.daemonState == .stopped)
    }

    @Test("Manual start resumes automatic recovery after a manual stop")
    func manualStartResumesAutomaticRecovery() async {
        let service = FakeRemoteControlService(statuses: [
            .running(cliVersion: nil, appServerVersion: nil),
            .stopped,
            .stopped,
        ])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: true)
        await viewModel.stop()
        await viewModel.reconcile(autoStart: true)
        await viewModel.start()
        await viewModel.reconcile(autoStart: true)

        #expect(await service.startCallCount == 2)
        #expect(viewModel.daemonState == .running(cliVersion: "test", appServerVersion: "test"))
    }

    @Test("An unknown state can recover when a later probe reports stopped")
    func unknownThenStoppedRecovers() async {
        let service = FakeRemoteControlService(statuses: [
            .unknown("probe temporariamente indisponível"),
            .stopped,
        ])
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.reconcile(autoStart: true)
        #expect(await service.startCallCount == 0)

        await viewModel.reconcile(autoStart: true)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == .running(cliVersion: "test", appServerVersion: "test"))
    }

    @Test("Failed automatic start respects retry interval")
    func failedAutomaticStartUsesRetryInterval() async {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped, .stopped, .stopped],
            startResults: [
                .failure(.startFailed),
                .success(.running(cliVersion: "test", appServerVersion: "test")),
            ]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 30,
            now: { clock.now }
        )

        await viewModel.reconcile(autoStart: true)
        #expect(await service.startCallCount == 1)

        clock.advance(by: 29)
        await viewModel.reconcile(autoStart: true)
        #expect(await service.startCallCount == 1)

        clock.advance(by: 1)
        await viewModel.reconcile(autoStart: true)

        #expect(await service.startCallCount == 2)
        #expect(viewModel.daemonState == .running(cliVersion: "test", appServerVersion: "test"))
    }

    @Test("A failed automatic start retries once without waiting for another reconciliation")
    func failedAutomaticStartSchedulesOneRetry() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped],
            startResults: [
                .failure(.startFailed),
                .success(.running(cliVersion: "retry", appServerVersion: "retry")),
            ]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.reconcile(autoStart: true)

        #expect(await waitUntil { await service.startCallCount == 2 })
        #expect(viewModel.daemonState == .running(cliVersion: "retry", appServerVersion: "retry"))
    }

    @Test("The scheduled automatic retry does not recursively schedule another retry")
    func scheduledAutomaticRetryRunsOnlyOnce() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped, .stopped],
            startResults: [
                .failure(.startFailed),
                .failure(.startFailed),
            ]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.reconcile(autoStart: true)

        #expect(await waitUntil { await service.startCallCount == 2 })
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(await service.startCallCount == 2)
        #expect(viewModel.daemonState == .stopped)
    }

    @Test("Disabling automatic start cancels a scheduled retry")
    func disablingAutomaticStartCancelsScheduledRetry() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped, .stopped],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0.02
        )

        await viewModel.reconcile(autoStart: true)
        await viewModel.reconcile(autoStart: false)
        try? await Task.sleep(nanoseconds: 40_000_000)

        #expect(await service.startCallCount == 1)
    }

    @Test("Opting out while an automatic start is suspended prevents its retry")
    func optingOutDuringAutomaticStartPreventsRetry() async {
        let service = ControlledRestartService()
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        let reconciliation = Task { await viewModel.reconcile(autoStart: true) }
        #expect(await waitUntil { await service.didStartStarting })

        await viewModel.reconcile(autoStart: false)
        await service.finishStart(with: .failure(FakeRemoteControlError.startFailed))
        await reconciliation.value
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == .stopped)
    }

    @Test("A running probe cancels a scheduled automatic retry")
    func runningProbeCancelsScheduledRetry() async {
        let running = DaemonState.running(cliVersion: "test", appServerVersion: "test")
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped, running],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0.02
        )

        await viewModel.reconcile(autoStart: true)
        await viewModel.refresh()
        try? await Task.sleep(nanoseconds: 40_000_000)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == running)
    }

    @Test("Manual stop cancels a scheduled automatic retry")
    func manualStopCancelsScheduledRetry() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.reconcile(autoStart: true)
        await viewModel.stop()
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await service.stopCallCount == 1)
        #expect(await service.startCallCount == 1)
    }

    @Test("Manual start failure does not schedule an automatic retry")
    func manualStartFailureDoesNotScheduleRetry() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.start()
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == .stopped)
    }

    @Test("Automatic start failure with an unknown final state does not schedule a retry")
    func unknownFinalStateDoesNotScheduleRetry() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped, .unknown("probe indisponível")],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.reconcile(autoStart: true)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == .unknown("probe indisponível"))
    }

    @Test("Automatic start failure with a running final state does not schedule a retry")
    func runningFinalStateDoesNotScheduleRetry() async {
        let running = DaemonState.running(cliVersion: "test", appServerVersion: "test")
        let service = FakeRemoteControlService(
            statuses: [.stopped, running],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.reconcile(autoStart: true)
        try? await Task.sleep(nanoseconds: 10_000_000)

        #expect(await service.startCallCount == 1)
        #expect(viewModel.daemonState == running)
    }

    @Test("Polling and the scheduled retry do not create duplicate starts")
    func pollingAndScheduledRetryDoNotDuplicateStarts() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped, .stopped, .stopped, .stopped],
            startResults: [
                .failure(.startFailed),
                .success(.running(cliVersion: "test", appServerVersion: "test")),
            ]
        )
        let viewModel = RemoteControlViewModel(
            service: service,
            automaticStartRetryInterval: 0
        )

        await viewModel.reconcile(autoStart: true)
        await viewModel.reconcile(autoStart: true)

        #expect(await waitUntil { await service.startCallCount == 2 })
        try? await Task.sleep(nanoseconds: 10_000_000)
        #expect(await service.startCallCount == 2)
    }

    @Test("Restart reports each phase and composes stop followed by start")
    func restartReportsPhases() async {
        let service = ControlledRestartService()
        let viewModel = RemoteControlViewModel(
            service: service,
            startStatusPollInterval: 0.001
        )

        let restart = Task { await viewModel.restart() }

        #expect(await waitUntil { await service.didStartStopping })
        #expect(viewModel.operation == .restartStopping)
        #expect(viewModel.statusTitle == "Parando para reiniciar…")

        await service.finishStop()
        #expect(await waitUntil { await service.didStartStarting })
        #expect(viewModel.operation == .restartStarting)
        #expect(viewModel.statusTitle == "Iniciando novamente…")

        await service.setStatus(.running(cliVersion: "0.144.3", appServerVersion: "0.144.3"))
        #expect(await waitUntil { viewModel.operation == .restartReconnecting })
        #expect(viewModel.statusTitle == "Reconectando Remote Control…")
        #expect(viewModel.isBusy)
        #expect(!viewModel.canStart)
        #expect(!viewModel.canStop)

        await service.finishStart(
            with: .success(.running(cliVersion: "0.144.3", appServerVersion: "0.144.3"))
        )
        await restart.value

        #expect(viewModel.operation == nil)
        #expect(viewModel.daemonState == .running(cliVersion: "0.144.3", appServerVersion: "0.144.3"))
        #expect(await service.stopCallCount == 1)
        #expect(await service.startCallCount == 1)
        #expect(await service.restartCallCount == 0)
    }

    @Test("A remote connection error is a warning when the daemon is already running")
    func remoteConnectionFailureAfterStartIsWarning() async {
        let service = FakeRemoteControlService(
            statuses: [.running(cliVersion: "0.144.3", appServerVersion: "0.144.3")],
            remoteStartErrors: [
                .commandFailed(
                    action: "iniciar",
                    exitCode: 1,
                    message: "Remote control is enabled on example-mac.local but the connection is errored."
                ),
            ]
        )
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.start()

        #expect(viewModel.daemonState == .running(cliVersion: "0.144.3", appServerVersion: "0.144.3"))
        #expect(viewModel.lastError == nil)
        #expect(viewModel.lastWarning == RemoteControlViewModel.remoteConnectionStartWarning)

        viewModel.clearWarning()
        #expect(viewModel.lastWarning == nil)
    }

    @Test("A normal start does not run the restart status monitor")
    func normalStartDoesNotPollStatus() async {
        let service = FakeRemoteControlService(statuses: [.stopped])
        let viewModel = RemoteControlViewModel(
            service: service,
            startStatusPollInterval: 0
        )

        await viewModel.start()

        #expect(await service.startCallCount == 1)
        #expect(await service.statusCallCount == 0)
        #expect(viewModel.daemonState == .running(cliVersion: "test", appServerVersion: "test"))
    }

    @Test("A real start failure remains an error even after the final probe")
    func realStartFailureRemainsError() async {
        let service = FakeRemoteControlService(
            statuses: [.stopped],
            startResults: [.failure(.startFailed)]
        )
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.start()

        #expect(viewModel.daemonState == .stopped)
        #expect(viewModel.lastError == "Falha simulada ao iniciar")
        #expect(viewModel.lastWarning == nil)
    }

    @Test("A read-only refresh preserves the historical Start warning")
    func refreshPreservesWarning() async {
        let service = FakeRemoteControlService(
            statuses: [
                .running(cliVersion: nil, appServerVersion: nil),
                .running(cliVersion: nil, appServerVersion: nil),
            ],
            remoteStartErrors: [
                .commandFailed(
                    action: "iniciar",
                    exitCode: 1,
                    message: "Remote control is enabled on host but the remote connection is errored."
                ),
            ]
        )
        let viewModel = RemoteControlViewModel(service: service)

        await viewModel.start()
        await viewModel.refresh()

        #expect(viewModel.lastWarning == RemoteControlViewModel.remoteConnectionStartWarning)
        #expect(viewModel.lastError == nil)
    }
}

private actor FakeRemoteControlService: RemoteControlServicing {
    private var pendingStatuses: [DaemonState]
    private var pendingStartResults: [Result<DaemonState, FakeRemoteControlError>]
    private var pendingRemoteStartErrors: [RemoteControlError]
    private(set) var statusCallCount = 0
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var restartCallCount = 0

    init(
        statuses: [DaemonState],
        startResults: [Result<DaemonState, FakeRemoteControlError>] = [],
        remoteStartErrors: [RemoteControlError] = []
    ) {
        pendingStatuses = statuses
        pendingStartResults = startResults
        pendingRemoteStartErrors = remoteStartErrors
    }

    func status() async -> DaemonState {
        statusCallCount += 1
        guard !pendingStatuses.isEmpty else { return .stopped }
        return pendingStatuses.removeFirst()
    }

    func start() async throws -> DaemonState {
        startCallCount += 1
        if !pendingRemoteStartErrors.isEmpty {
            throw pendingRemoteStartErrors.removeFirst()
        }
        guard !pendingStartResults.isEmpty else {
            return .running(cliVersion: "test", appServerVersion: "test")
        }
        return try pendingStartResults.removeFirst().get()
    }

    func stop() async throws -> DaemonState {
        stopCallCount += 1
        return .stopped
    }

    func restart() async throws -> DaemonState {
        restartCallCount += 1
        return .running(cliVersion: "test", appServerVersion: "test")
    }

    func pair() async throws -> PairingCode {
        PairingCode(manualCode: "TEST-CODE", expiresAt: nil)
    }
}

private actor ControlledRestartService: RemoteControlServicing {
    private var currentStatus: DaemonState = .stopped
    private var stopContinuation: CheckedContinuation<Void, Never>?
    private var startContinuation: CheckedContinuation<DaemonState, any Error>?
    private(set) var stopCallCount = 0
    private(set) var startCallCount = 0
    private(set) var restartCallCount = 0

    var didStartStopping: Bool { stopCallCount > 0 }
    var didStartStarting: Bool { startCallCount > 0 }

    func status() async -> DaemonState {
        currentStatus
    }

    func start() async throws -> DaemonState {
        startCallCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
    }

    func stop() async throws -> DaemonState {
        stopCallCount += 1
        await withCheckedContinuation { continuation in
            stopContinuation = continuation
        }
        currentStatus = .stopped
        return .stopped
    }

    func restart() async throws -> DaemonState {
        restartCallCount += 1
        return currentStatus
    }

    func pair() async throws -> PairingCode {
        PairingCode(manualCode: "TEST-CODE", expiresAt: nil)
    }

    func setStatus(_ status: DaemonState) {
        currentStatus = status
    }

    func finishStop() {
        stopContinuation?.resume()
        stopContinuation = nil
    }

    func finishStart(with result: Result<DaemonState, any Error>) {
        startContinuation?.resume(with: result)
        startContinuation = nil
    }
}

@MainActor
private func waitUntil(
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return false
}

private enum FakeRemoteControlError: LocalizedError, Sendable {
    case startFailed

    var errorDescription: String? {
        "Falha simulada ao iniciar"
    }
}

@MainActor
private final class TestClock {
    private(set) var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
