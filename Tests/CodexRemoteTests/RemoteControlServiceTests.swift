import Foundation
import Testing
@testable import CodexRemote

@Suite("Remote Control Service")
struct RemoteControlServiceTests {
    @Test("Recognizes transient remote connection failure after Start")
    func recognizesStartRemoteConnectionFailure() {
        let messages = [
            "Remote control is enabled on example-mac.local but the connection is errored.",
            "REMOTE CONTROL IS ENABLED ON host.local,\n but the remote connection is errored.",
        ]

        for message in messages {
            let error = RemoteControlError.commandFailed(
                action: "iniciar",
                exitCode: 1,
                message: message
            )

            #expect(error.isRemoteConnectionFailure)
        }
    }

    @Test("Does not classify generic or non-Start failures as remote connection failure")
    func rejectsUnrelatedRemoteConnectionFailures() {
        let errors: [RemoteControlError] = [
            .commandFailed(
                action: "parar",
                exitCode: 1,
                message: "Remote control is enabled on host.local but the connection is errored."
            ),
            .commandFailed(
                action: "iniciar",
                exitCode: 1,
                message: "The remote connection is errored."
            ),
            .commandFailed(
                action: "iniciar",
                exitCode: 1,
                message: "Remote control is enabled on host.local but connection is errored."
            ),
            .commandFailed(
                action: "iniciar",
                exitCode: 1,
                message: "Remote control is enabled on host.local but the connection timed out."
            ),
            .invalidPairingResponse,
            .pairingUnavailable,
            .stopTimedOut(seconds: 75),
        ]

        for error in errors {
            #expect(!error.isRemoteConnectionFailure)
        }
    }

    @Test("Daemon probe parses running versions")
    func daemonProbeParsesRunningVersions() async {
        let payload = Data(#"{"cliVersion":"0.144.1","appServerVersion":"0.144.1"}"#.utf8)
        let runner = FakeRunner(results: [.init(exitCode: 0, stdout: payload, stderr: Data())])
        let probe = DaemonStatusProbe(runner: runner)

        let state = await probe.status(codexURL: URL(fileURLWithPath: "/tmp/codex"))
        let calls = await runner.arguments

        #expect(state == .running(cliVersion: "0.144.1", appServerVersion: "0.144.1"))
        #expect(calls == [["app-server", "daemon", "version"]])
    }

    @Test("Missing daemon socket means stopped")
    func daemonProbeTreatsMissingSocketAsStopped() async {
        let runner = FakeRunner(results: [
            .init(
                exitCode: 1,
                stdout: Data(),
                stderr: Data("Error: failed to connect: No such file or directory".utf8)
            ),
        ])
        let probe = DaemonStatusProbe(runner: runner)

        let state = await probe.status(codexURL: URL(fileURLWithPath: "/tmp/codex"))

        #expect(state == .stopped)
    }

    @Test("Restart serializes stop then start")
    func restartSerializesStopThenStartAndRefreshesStatus() async throws {
        let runner = FakeRunner(results: [
            .init(exitCode: 0, stdout: Data(#"{}"#.utf8), stderr: Data()),
            .init(exitCode: 0, stdout: Data(#"{}"#.utf8), stderr: Data()),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: "cli", appServerVersion: "server"))
        )

        let state = try await service.restart()
        let calls = await runner.arguments
        let timeouts = await runner.timeouts

        #expect(state == .running(cliVersion: "cli", appServerVersion: "server"))
        #expect(calls == [
            ["remote-control", "stop", "--json"],
            ["remote-control", "start", "--json"],
        ])
        #expect(timeouts == [75, 15])
    }

    @Test("Stop allows the daemon graceful shutdown window")
    func stopUsesDedicatedTimeout() async throws {
        let runner = FakeRunner(results: [
            .init(exitCode: 0, stdout: Data(#"{}"#.utf8), stderr: Data()),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .stopped)
        )

        let state = try await service.stop()
        let calls = await runner.arguments
        let timeouts = await runner.timeouts

        #expect(state == .stopped)
        #expect(calls == [["remote-control", "stop", "--json"]])
        #expect(timeouts == [75])
    }

    @Test("Stop timeout is success when the daemon finished stopping")
    func stopTimeoutReturnsStoppedStateWhenProbeIsStopped() async throws {
        let runner = FakeRunner(responses: [.failure(.timedOut(seconds: 75))])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .stopped)
        )

        let state = try await service.stop()

        #expect(state == .stopped)
    }

    @Test("Stop timeout explains when the daemon remains active")
    func stopTimeoutReportsRunningDaemon() async {
        let runner = FakeRunner(responses: [.failure(.timedOut(seconds: 75))])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: "cli", appServerVersion: "server"))
        )

        do {
            _ = try await service.stop()
            Issue.record("Stop deveria informar que o daemon continua ativo")
        } catch {
            #expect(error as? RemoteControlError == .stopTimedOut(seconds: 75))
            #expect(error.localizedDescription == "O Codex não concluiu a parada em 75 segundos. O daemon continua ativo.")
        }
    }

    @Test("Matching stale updater failure recovers and retries Start once")
    func startRecoversMatchingStaleUpdaterFailure() async throws {
        let staleFailure = ProcessResult(
            exitCode: 1,
            stdout: Data(),
            stderr: Data("APP SERVER DID NOT BECOME READY at /tmp/APP-SERVER-CONTROL.SOCK".utf8)
        )
        let runner = FakeRunner(results: [
            staleFailure,
            .init(exitCode: 0, stdout: Data(#"{}"#.utf8), stderr: Data()),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        let state = try await service.start()
        let calls = await runner.arguments
        let recoveredURLs = await recovery.codexURLs

        #expect(state == .running(cliVersion: "cli", appServerVersion: "server"))
        #expect(calls == [
            ["remote-control", "start", "--json"],
            ["remote-control", "start", "--json"],
        ])
        #expect(recoveredURLs == [URL(fileURLWithPath: "/tmp/codex")])
    }

    @Test("Non-timeout Start failure remains unchanged and does not recover")
    func nonTimeoutStartFailureRemainsUnchanged() async {
        let runner = FakeRunner(results: [
            .init(exitCode: 2, stdout: Data(), stderr: Data("permission denied".utf8)),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        do {
            _ = try await service.start()
            Issue.record("Start deveria propagar a falha generica")
        } catch {
            #expect(error as? RemoteControlError == .commandFailed(
                action: "iniciar",
                exitCode: 2,
                message: "permission denied"
            ))
        }

        let recoveredURLs = await recovery.codexURLs
        let calls = await runner.arguments
        #expect(recoveredURLs.isEmpty)
        #expect(calls == [["remote-control", "start", "--json"]])
    }

    @Test("Start timeout succeeds when the daemon is already running")
    func startTimeoutReturnsSuccessWhenDaemonIsAlreadyRunning() async throws {
        let runner = FakeRunner(responses: [.failure(.timedOut(seconds: 15))])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        let state = try await service.start()
        let recoveredURLs = await recovery.codexURLs
        let calls = await runner.arguments

        #expect(state == .running(cliVersion: "cli", appServerVersion: "server"))
        #expect(recoveredURLs.isEmpty)
        #expect(calls == [["remote-control", "start", "--json"]])
    }

    @Test("Start timeout recovers once and retries when the daemon is stopped")
    func startTimeoutRecoversAndRetriesWhenDaemonIsStopped() async throws {
        let runner = FakeRunner(responses: [
            .failure(.timedOut(seconds: 15)),
            .success(.init(exitCode: 0, stdout: Data(), stderr: Data())),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let probe = SequencedProbe(states: [
            .stopped,
            .running(cliVersion: "cli", appServerVersion: "server"),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: probe,
            staleUpdaterRecovery: recovery
        )

        let state = try await service.start()
        let recoveredURLs = await recovery.codexURLs
        let calls = await runner.arguments

        #expect(state == .running(cliVersion: "cli", appServerVersion: "server"))
        #expect(recoveredURLs == [URL(fileURLWithPath: "/tmp/codex")])
        #expect(calls == [
            ["remote-control", "start", "--json"],
            ["remote-control", "start", "--json"],
        ])
    }

    @Test("Start timeout preserves the original timeout when recovery fails")
    func startTimeoutPreservesTimeoutWhenRecoveryFails() async {
        let runner = FakeRunner(responses: [.failure(.timedOut(seconds: 15))])
        let recovery = FakeStaleUpdaterRecovery(shouldFail: true)
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .stopped),
            staleUpdaterRecovery: recovery
        )

        do {
            _ = try await service.start()
            Issue.record("Start deveria propagar o timeout original")
        } catch {
            #expect(error as? ProcessRunnerError == .timedOut(seconds: 15))
        }

        let recoveredURLs = await recovery.codexURLs
        let calls = await runner.arguments
        #expect(recoveredURLs == [URL(fileURLWithPath: "/tmp/codex")])
        #expect(calls == [["remote-control", "start", "--json"]])
    }

    @Test("Recovery failure preserves original safe Start error")
    func recoveryFailureRethrowsOriginalStartError() async {
        let originalMessage = "app server did not become ready: failed to connect to /tmp/app-server-control.sock"
        let runner = FakeRunner(results: [
            .init(exitCode: 7, stdout: Data(), stderr: Data(originalMessage.utf8)),
        ])
        let recovery = FakeStaleUpdaterRecovery(shouldFail: true)
        let service = makeService(runner: runner, recovery: recovery)

        do {
            _ = try await service.start()
            Issue.record("Start deveria preservar a falha original")
        } catch {
            #expect(error as? RemoteControlError == .commandFailed(
                action: "iniciar",
                exitCode: 7,
                message: staleAppServerFriendlyMessage
            ))
        }

        let recoveredURLs = await recovery.codexURLs
        let calls = await runner.arguments
        #expect(recoveredURLs.count == 1)
        #expect(calls.count == 1)
    }

    @Test("A repeated matching failure gets only one recovery and one retry")
    func matchingFailureDoesNotEnterRecoveryLoop() async {
        let message = "app server did not become ready at /tmp/app-server-control.sock"
        let runner = FakeRunner(results: [
            .init(exitCode: 7, stdout: Data(), stderr: Data(message.utf8)),
            .init(exitCode: 8, stdout: Data(), stderr: Data(message.utf8)),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        do {
            _ = try await service.start()
            Issue.record("O retry deveria propagar sua propria falha")
        } catch {
            #expect(error as? RemoteControlError == .commandFailed(
                action: "iniciar",
                exitCode: 8,
                message: staleAppServerFriendlyMessage
            ))
        }

        let recoveredURLs = await recovery.codexURLs
        let calls = await runner.arguments
        #expect(recoveredURLs.count == 1)
        #expect(calls.count == 2)
    }

    @Test("App-server startup stderr is replaced with a short actionable message")
    func appServerStartupFailureDoesNotExposeManagedLogsOrPaths() async {
        let stderr = """
        Error: app server did not become ready on /Users/example/.codex/app-server-control/app-server-control.sock

        Daemon used app-server:
        path: /Users/example/.codex/packages/standalone/current/codex
        version: 0.145.0

        Managed app-server stderr (/Users/example/.codex/app-server-control/app-server.stderr.log):
        \u{001B}[2m2026-07-23T07:57:13.8232270Z\u{001B}[0m ERROR timeout_ms must be at least 1000
        \u{001B}[2m2026-07-23T08:04:57.827824Z\u{001B}[0m ERROR stale historical log
        """
        let runner = FakeRunner(results: [
            .init(exitCode: 1, stdout: Data(), stderr: Data(stderr.utf8)),
        ])
        let recovery = FakeStaleUpdaterRecovery(shouldFail: true)
        let service = makeService(runner: runner, recovery: recovery)

        do {
            _ = try await service.start()
            Issue.record("Start deveria falhar")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains(staleAppServerFriendlyMessage))
            #expect(!message.contains("Managed app-server stderr"))
            #expect(!message.contains("/Users/example"))
            #expect(!message.contains("\u{001B}"))
            #expect(!message.contains("timeout_ms"))
            #expect(!message.contains("historical log"))
        }
    }

    @Test("Generic stderr keeps useful context while removing ANSI, paths and secrets")
    func genericStartFailureSanitizesDiagnostics() async {
        let stderr = "\u{001B}[31mError: permission denied while launching daemon at /Users/example/.codex/bin/codex token=super-secret-value\u{001B}[0m"
        let runner = FakeRunner(results: [
            .init(exitCode: 2, stdout: Data(), stderr: Data(stderr.utf8)),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        do {
            _ = try await service.start()
            Issue.record("Start deveria falhar")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("permission denied while launching daemon"))
            #expect(message.contains("[caminho local]"))
            #expect(message.contains("token=[redacted]"))
            #expect(!message.contains("/Users/example"))
            #expect(!message.contains("super-secret-value"))
            #expect(!message.contains("\u{001B}"))
        }
    }

    @Test("Restart applies stale updater recovery only after Stop succeeds")
    func restartRecoversItsStartStep() async throws {
        let message = "app server did not become ready at /tmp/app-server-control.sock"
        let runner = FakeRunner(results: [
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
            .init(exitCode: 1, stdout: Data(), stderr: Data(message.utf8)),
            .init(exitCode: 0, stdout: Data(), stderr: Data()),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        _ = try await service.restart()

        let calls = await runner.arguments
        let recoveredURLs = await recovery.codexURLs
        #expect(calls == [
            ["remote-control", "stop", "--json"],
            ["remote-control", "start", "--json"],
            ["remote-control", "start", "--json"],
        ])
        #expect(recoveredURLs.count == 1)
    }

    @Test("Restart never attempts Start recovery when Stop fails")
    func restartStopFailureDoesNotRecover() async {
        let runner = FakeRunner(results: [
            .init(exitCode: 3, stdout: Data(), stderr: Data("stop failed".utf8)),
        ])
        let recovery = FakeStaleUpdaterRecovery()
        let service = makeService(runner: runner, recovery: recovery)

        do {
            _ = try await service.restart()
            Issue.record("Restart deveria encerrar depois da falha de Stop")
        } catch {
            #expect(error as? RemoteControlError == .commandFailed(
                action: "parar",
                exitCode: 3,
                message: "stop failed"
            ))
        }

        let calls = await runner.arguments
        let recoveredURLs = await recovery.codexURLs
        #expect(calls == [["remote-control", "stop", "--json"]])
        #expect(recoveredURLs.isEmpty)
    }

    @Test("Pair preserves current QR and manual artifacts with Unix expiration")
    func pairParsesCurrentResponse() async throws {
        let expiresAt: TimeInterval = 1_893_456_000
        let payload = Data(
            #"{"pairingCode":"opaque-token","manualPairingCode":"ABCD-EFGH","environmentId":"env_test","expiresAt":1893456000}"#.utf8
        )
        let runner = FakeRunner(results: [.init(exitCode: 0, stdout: payload, stderr: Data())])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        let pairing = try await service.pair()
        let calls = await runner.arguments

        #expect(pairing.qrPayload == "https://chatgpt.com/codex/pair?pairing_code=opaque-token")
        #expect(pairing.manualCode == "ABCD-EFGH")
        #expect(pairing.expiresAt == Date(timeIntervalSince1970: expiresAt))
        #expect(calls == [["remote-control", "pair", "--json"]])
    }

    @Test("Pair safely URL-encodes the opaque QR artifact")
    func pairSafelyEncodesReservedCharacters() async throws {
        let opaqueCode = "opaque +&=?#/ü"
        let payload = try JSONSerialization.data(withJSONObject: [
            "pairingCode": opaqueCode,
            "manualPairingCode": NSNull(),
            "environmentId": "env_test",
            "expiresAt": 1_893_456_000,
        ])
        let runner = FakeRunner(results: [.init(exitCode: 0, stdout: payload, stderr: Data())])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        let pairing = try await service.pair()
        let qrPayload = try #require(pairing.qrPayload)
        let components = try #require(URLComponents(string: qrPayload))

        #expect(pairing.manualCode == nil)
        #expect(components.scheme == "https")
        #expect(components.host == "chatgpt.com")
        #expect(components.path == "/codex/pair")
        #expect(components.queryItems == [URLQueryItem(name: "pairing_code", value: opaqueCode)])
        #expect(qrPayload.contains("%2B"))
        #expect(qrPayload.contains("%26"))
        #expect(qrPayload.contains("%23"))
    }

    @Test("Legacy manual-only response does not synthesize a QR payload")
    func pairSupportsManualOnlyResponse() async throws {
        let payload = Data(
            #"{"result":{"manual_pairing_code":"ABCD-EFGH","expires_at":"2030-01-02T03:04:05Z"}}"#.utf8
        )
        let runner = FakeRunner(results: [.init(exitCode: 0, stdout: payload, stderr: Data())])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        let pairing = try await service.pair()

        #expect(pairing.qrPayload == nil)
        #expect(pairing.manualCode == "ABCD-EFGH")
        #expect(pairing.expiresAt != nil)
    }

    @Test("Pair accepts QR-only response with nullable manual code")
    func pairSupportsNullableManualCode() async throws {
        let payload = Data(
            #"{"pairingCode":"opaque-token","manualPairingCode":null,"environmentId":"env_test","expiresAt":1893456000}"#.utf8
        )
        let runner = FakeRunner(results: [.init(exitCode: 0, stdout: payload, stderr: Data())])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        let pairing = try await service.pair()

        #expect(pairing.qrPayload != nil)
        #expect(pairing.manualCode == nil)
    }

    @Test("Invalid pair response never exposes raw stdout")
    func pairDoesNotExposeRawStdoutWhenResponseIsInvalid() async {
        let secret = "SECRET-PAIRING-CODE"
        let payload = try! JSONSerialization.data(withJSONObject: ["unexpected": secret])
        let runner = FakeRunner(results: [
            .init(exitCode: 0, stdout: payload, stderr: Data()),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .stopped)
        )

        do {
            _ = try await service.pair()
            Issue.record("Pair deveria falhar para JSON sem campo reconhecido")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test("Pairing timeout from the remote backend becomes an actionable account error")
    func pairMapsRemoteBackendTimeout() async {
        let runner = FakeRunner(results: [
            .init(
                exitCode: 1,
                stdout: Data(),
                stderr: Data(
                    "Error: timed out waiting for remoteControl/pairing/start response\n\nCaused by:\n    deadline has elapsed\n".utf8
                )
            ),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        do {
            _ = try await service.pair()
            Issue.record("Pair deveria orientar a configuração pelo ChatGPT")
        } catch {
            #expect(error as? RemoteControlError == .pairingUnavailable)
            #expect(!error.localizedDescription.contains("deadline has elapsed"))
        }
    }

    @Test("Pairing enrollment rejection is hidden behind account guidance")
    func pairMapsRemoteEnrollmentRejection() async {
        let backendDetail = "Multi-factor authentication required"
        let runner = FakeRunner(results: [
            .init(
                exitCode: 1,
                stdout: Data(),
                stderr: Data(
                    "Error: remoteControl/pairing/start failed: remote control server enrollment failed at 'https://chatgpt.com/backend-api/wham/remote/control/server/enroll': HTTP 403 Forbidden, body: {\"detail\":\"\u{001B}[31m\(backendDetail)\u{001B}[0m\"}".utf8
                )
            ),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        do {
            _ = try await service.pair()
            Issue.record("Pair deveria ocultar a rejeição técnica de enrollment")
        } catch {
            #expect(error as? RemoteControlError == .pairingUnavailable)
            #expect(!error.localizedDescription.contains("HTTP 403"))
            #expect(!error.localizedDescription.contains(backendDetail))
            #expect(!error.localizedDescription.contains("backend-api"))
        }
    }

    @Test("Unrelated Pair failures remain command errors")
    func pairPreservesUnrelatedFailure() async {
        let runner = FakeRunner(results: [
            .init(exitCode: 7, stdout: Data(), stderr: Data("network unavailable".utf8)),
        ])
        let service = RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: nil, appServerVersion: nil))
        )

        do {
            _ = try await service.pair()
            Issue.record("Pair deveria preservar a falha não classificada")
        } catch {
            #expect(error as? RemoteControlError == .commandFailed(
                action: "parear",
                exitCode: 7,
                message: "network unavailable"
            ))
        }
    }

    private func makeService(
        runner: FakeRunner,
        recovery: FakeStaleUpdaterRecovery
    ) -> RemoteControlService {
        RemoteControlService(
            runner: runner,
            locator: FixedLocator(),
            probe: FixedProbe(state: .running(cliVersion: "cli", appServerVersion: "server")),
            staleUpdaterRecovery: recovery
        )
    }

    private var staleAppServerFriendlyMessage: String {
        "O servidor local do Codex não ficou pronto. A recuperação automática não foi concluída; clique em Reiniciar. Se persistir após uma atualização do Codex, feche e abra o Codex novamente."
    }
}

private actor FakeRunner: ProcessRunning {
    private var pendingResponses: [FakeRunnerResponse]
    private(set) var arguments: [[String]] = []
    private(set) var timeouts: [TimeInterval] = []

    init(results: [ProcessResult]) {
        pendingResponses = results.map(FakeRunnerResponse.success)
    }

    init(responses: [FakeRunnerResponse]) {
        pendingResponses = responses
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        self.arguments.append(arguments)
        self.timeouts.append(timeout)
        guard !pendingResponses.isEmpty else {
            throw ProcessRunnerError.launchFailed("resultado falso ausente")
        }
        switch pendingResponses.removeFirst() {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }
}

private enum FakeRunnerResponse: Sendable {
    case success(ProcessResult)
    case failure(ProcessRunnerError)
}

private actor FakeStaleUpdaterRecovery: StaleUpdaterRecovering {
    private let shouldFail: Bool
    private(set) var codexURLs: [URL] = []

    init(shouldFail: Bool = false) {
        self.shouldFail = shouldFail
    }

    func recover(codexURL: URL) async throws {
        codexURLs.append(codexURL)
        if shouldFail { throw FakeStaleUpdaterRecoveryError.failed }
    }
}

private enum FakeStaleUpdaterRecoveryError: Error {
    case failed
}

private struct FixedLocator: CodexLocating {
    func locate() throws -> URL {
        URL(fileURLWithPath: "/tmp/codex")
    }
}

private struct FixedProbe: DaemonStatusProbing {
    let state: DaemonState

    func status(codexURL: URL) async -> DaemonState {
        state
    }
}

private actor SequencedProbe: DaemonStatusProbing {
    private var pendingStates: [DaemonState]

    init(states: [DaemonState]) {
        pendingStates = states
    }

    func status(codexURL: URL) async -> DaemonState {
        guard !pendingStates.isEmpty else {
            return .unknown("estado falso ausente")
        }
        return pendingStates.removeFirst()
    }
}
