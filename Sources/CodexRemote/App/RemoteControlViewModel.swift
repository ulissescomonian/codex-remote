import Foundation

@MainActor
final class RemoteControlViewModel: ObservableObject {
    static let remoteConnectionStartWarning =
        "Ao iniciar, o Codex informou que a conexão remota ainda estava sendo restabelecida naquele momento."

    enum Operation: Equatable {
        case checking
        case starting
        case stopping
        case restartStopping
        case restartStarting
        case restartReconnecting
        case pairing

        var description: String {
            switch self {
            case .checking: "Verificando…"
            case .starting: "Iniciando…"
            case .stopping: "Parando…"
            case .restartStopping: "Parando para reiniciar…"
            case .restartStarting: "Iniciando novamente…"
            case .restartReconnecting: "Reconectando Remote Control…"
            case .pairing: "Gerando código…"
            }
        }
    }

    @Published private(set) var daemonState: DaemonState = .unknown("Ainda não verificado")
    @Published private(set) var operation: Operation?
    @Published private(set) var pairingCode: PairingCode?
    @Published private(set) var lastCheckedAt: Date?
    @Published var lastError: String?
    @Published private(set) var lastWarning: String?

    private let service: any RemoteControlServicing
    private let automaticStartRetryInterval: TimeInterval
    private let startStatusPollInterval: TimeInterval
    private let now: () -> Date
    private var lastAutomaticStartAttemptAt: Date?
    private var isAutomaticRecoverySuppressed = false
    private var activeStartMonitorID: UUID?
    private var isAutomaticStartEnabled = false
    private var automaticStartRetryID: UUID?
    private var automaticStartRetryTask: Task<Void, Never>?

    init(
        service: any RemoteControlServicing,
        automaticStartRetryInterval: TimeInterval = 30,
        startStatusPollInterval: TimeInterval = 0.5,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.automaticStartRetryInterval = automaticStartRetryInterval
        self.startStatusPollInterval = startStatusPollInterval
        self.now = now
    }

    var isBusy: Bool { operation != nil }

    var statusTitle: String {
        if let operation { return operation.description }
        switch daemonState {
        case .stopped:
            return "Daemon parado"
        case .running:
            return "Daemon ativo"
        case .unknown:
            return "Estado desconhecido"
        }
    }

    var statusDetail: String? {
        switch daemonState {
        case .stopped:
            return nil
        case let .running(cliVersion, appServerVersion):
            let versions = [
                cliVersion.map { "CLI \($0)" },
                appServerVersion.map { "App Server \($0)" },
            ].compactMap { $0 }
            return versions.isEmpty ? nil : versions.joined(separator: " · ")
        case let .unknown(reason):
            return reason.isEmpty ? nil : reason
        }
    }

    var menuBarSymbol: String {
        return switch daemonState {
        case .stopped: "antenna.radiowaves.left.and.right.slash"
        case .running: "antenna.radiowaves.left.and.right"
        case .unknown: "exclamationmark.triangle"
        }
    }

    var canStart: Bool {
        guard !isBusy else { return false }
        if case .running = daemonState { return false }
        return true
    }

    var canStop: Bool {
        guard !isBusy else { return false }
        if case .running = daemonState { return true }
        return false
    }

    var canPair: Bool { canStop }

    func reconcile(autoStart: Bool) async {
        isAutomaticStartEnabled = autoStart
        if !autoStart {
            cancelAutomaticStartRetry()
        }

        await refresh()
        guard autoStart,
              !isAutomaticRecoverySuppressed,
              !isBusy,
              case .stopped = daemonState,
              canAttemptAutomaticStart
        else { return }

        await performAutomaticStart(scheduleRetryAfterFailure: true)
    }

    func refresh() async {
        guard operation == nil else { return }
        operation = .checking
        let state = await service.status()
        updateDaemonState(state)
        lastCheckedAt = Date()
        operation = nil
    }

    func start() async {
        cancelAutomaticStartRetry()
        isAutomaticRecoverySuppressed = false
        lastAutomaticStartAttemptAt = nil
        _ = await performStart(initialOperation: .starting)
    }

    func stop() async {
        cancelAutomaticStartRetry()
        isAutomaticRecoverySuppressed = true
        await perform(.stopping) { try await service.stop() }
    }

    func restart() async {
        guard operation == nil else { return }
        cancelAutomaticStartRetry()
        operation = .restartStopping
        clearMessages()

        do {
            updateDaemonState(try await service.stop())
        } catch {
            await recordFailure(error)
            operation = nil
            return
        }

        operation = .restartStarting
        do {
            updateDaemonState(
                try await startMonitoringStatus(reconnectingOperation: .restartReconnecting)
            )
            lastCheckedAt = Date()
        } catch {
            await recordStartFailure(error)
        }
        operation = nil
    }

    func pair() async {
        guard operation == nil else { return }
        operation = .pairing
        clearMessages()
        pairingCode = nil
        do {
            pairingCode = try await service.pair()
        } catch {
            lastError = Self.friendlyMessage(for: error)
        }
        operation = nil
    }

    func dismissPairingCode() {
        pairingCode = nil
    }

    func clearError() {
        lastError = nil
    }

    func clearWarning() {
        lastWarning = nil
    }

    private func perform(
        _ nextOperation: Operation,
        action: () async throws -> DaemonState
    ) async {
        guard operation == nil else { return }
        operation = nextOperation
        clearMessages()
        do {
            updateDaemonState(try await action())
            lastCheckedAt = Date()
        } catch {
            lastError = Self.friendlyMessage(for: error)
            updateDaemonState(await service.status())
            lastCheckedAt = Date()
        }
        operation = nil
    }

    @discardableResult
    private func performStart(initialOperation: Operation) async -> Bool {
        guard operation == nil else { return false }
        operation = initialOperation
        clearMessages()
        do {
            updateDaemonState(try await service.start())
            lastCheckedAt = Date()
            operation = nil
            return true
        } catch {
            await recordStartFailure(error)
            operation = nil
            return false
        }
    }

    private func performAutomaticStart(scheduleRetryAfterFailure: Bool) async {
        cancelAutomaticStartRetry()
        guard isAutomaticStartEnabled,
              !isAutomaticRecoverySuppressed,
              operation == nil,
              case .stopped = daemonState
        else { return }

        lastAutomaticStartAttemptAt = now()
        let succeeded = await performStart(initialOperation: .starting)
        if !succeeded,
           scheduleRetryAfterFailure,
           isAutomaticStartEnabled,
           !isAutomaticRecoverySuppressed,
           case .stopped = daemonState {
            scheduleAutomaticStartRetry()
        }
    }

    private func scheduleAutomaticStartRetry() {
        cancelAutomaticStartRetry()
        let retryID = UUID()
        let retryInterval = max(automaticStartRetryInterval, 0)
        automaticStartRetryID = retryID
        automaticStartRetryTask = Task { [weak self] in
            if retryInterval > 0 {
                let nanoseconds = UInt64(retryInterval * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }

            guard !Task.isCancelled, let self else { return }
            await self.runScheduledAutomaticStartRetry(id: retryID)
        }
    }

    private func runScheduledAutomaticStartRetry(id: UUID) async {
        guard automaticStartRetryID == id else { return }

        while operation != nil {
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, automaticStartRetryID == id else { return }
        }

        guard isAutomaticStartEnabled,
              !isAutomaticRecoverySuppressed,
              case .stopped = daemonState
        else {
            clearAutomaticStartRetry(id: id)
            return
        }

        clearAutomaticStartRetry(id: id)
        await performAutomaticStart(scheduleRetryAfterFailure: false)
    }

    private func clearAutomaticStartRetry(id: UUID) {
        guard automaticStartRetryID == id else { return }
        automaticStartRetryID = nil
        automaticStartRetryTask = nil
    }

    private func cancelAutomaticStartRetry() {
        automaticStartRetryID = nil
        automaticStartRetryTask?.cancel()
        automaticStartRetryTask = nil
    }

    private func startMonitoringStatus(
        reconnectingOperation: Operation
    ) async throws -> DaemonState {
        let monitorID = UUID()
        activeStartMonitorID = monitorID
        let monitor = Task { [weak self] in
            guard let self else { return }
            await self.monitorStartStatus(
                id: monitorID,
                reconnectingOperation: reconnectingOperation
            )
        }

        do {
            let state = try await service.start()
            stopStartMonitor(id: monitorID, task: monitor)
            return state
        } catch {
            stopStartMonitor(id: monitorID, task: monitor)
            throw error
        }
    }

    private func monitorStartStatus(
        id: UUID,
        reconnectingOperation: Operation
    ) async {
        while !Task.isCancelled {
            if startStatusPollInterval > 0 {
                let nanoseconds = UInt64(startStatusPollInterval * 1_000_000_000)
                do {
                    try await Task.sleep(nanoseconds: nanoseconds)
                } catch {
                    return
                }
            } else {
                await Task.yield()
            }

            guard !Task.isCancelled, activeStartMonitorID == id else { return }
            let state = await service.status()
            guard !Task.isCancelled, activeStartMonitorID == id else { return }

            if case .running = state {
                updateDaemonState(state)
                operation = reconnectingOperation
                return
            }
        }
    }

    private func stopStartMonitor(id: UUID, task: Task<Void, Never>) {
        guard activeStartMonitorID == id else { return }
        activeStartMonitorID = nil
        task.cancel()
    }

    private func recordStartFailure(_ error: Error) async {
        let finalState = await service.status()
        updateDaemonState(finalState)
        lastCheckedAt = Date()

        if let remoteControlError = error as? RemoteControlError,
           remoteControlError.isRemoteConnectionFailure,
           case .running = finalState {
            lastError = nil
            // The local socket probe cannot establish the current remote
            // connection state, so retain this as a historical Start warning.
            lastWarning = Self.remoteConnectionStartWarning
        } else {
            lastError = Self.friendlyMessage(for: error)
        }
    }

    private func recordFailure(_ error: Error) async {
        lastError = Self.friendlyMessage(for: error)
        updateDaemonState(await service.status())
        lastCheckedAt = Date()
    }

    private func clearMessages() {
        lastError = nil
        lastWarning = nil
    }

    private var canAttemptAutomaticStart: Bool {
        guard let lastAutomaticStartAttemptAt else { return true }
        return now().timeIntervalSince(lastAutomaticStartAttemptAt) >= automaticStartRetryInterval
    }

    private func updateDaemonState(_ state: DaemonState) {
        daemonState = state
        if case .running = state {
            cancelAutomaticStartRetry()
            lastAutomaticStartAttemptAt = nil
        }
    }

    private static func friendlyMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
