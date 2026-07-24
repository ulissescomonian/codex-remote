import Darwin
import Foundation
import Testing
@testable import CodexRemote

@Suite("Stale Updater Recovery")
struct StaleUpdaterRecoveryTests {
    @Test("Official Stop success still validates but does not signal an unsafe candidate")
    func officialStopSuccessWithoutSafeCandidateDoesNotSignal() async throws {
        let layout = try StandaloneLayout()
        let runner = RecoveryRunner(results: [
            .success(.init(exitCode: 0, stdout: Data(), stderr: Data())),
        ])
        let identity = StaleUpdaterProcessIdentity(
            uid: getuid(),
            executablePath: layout.currentExecutable.path
        )
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
        #expect(controller.identityCallCount == 1)
        #expect(await runner.arguments == [["remote-control", "stop", "--json"]])
    }

    @Test("Official Stop success still terminates a validated old updater")
    func officialStopSuccessTerminatesValidatedOldUpdater() async throws {
        let layout = try StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: layout.oldExecutable),
            stopExitCode: 0
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity],
            runningStates: [false]
        )
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminatedPIDs == [testRecord.pid])
    }

    @Test("Official Stop success never hides a stale updater that does not exit")
    func officialStopSuccessPreservesProcessDidNotExit() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: layout.oldExecutable),
            stopExitCode: 0
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity],
            runningStates: [true]
        )
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        do {
            try await recovery.recover(codexURL: layout.currentExecutable)
            Issue.record("A recuperacao deveria informar que o updater continuou em execucao")
        } catch {
            #expect(error as? StaleUpdaterRecoveryError == .processDidNotExit)
        }
    }

    @Test("Validated updater from an old release is terminated with SIGTERM")
    func oldReleaseUpdaterIsTerminated() async throws {
        let layout = try StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: layout.oldExecutable)
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity],
            runningStates: [false]
        )
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminatedPIDs == [testRecord.pid])
    }

    @Test("Current launcher backed by an old loaded release is eligible")
    func currentLauncherWithOldLoadedReleaseIsTerminated() async throws {
        let layout = try StandaloneLayout()
        let currentLauncher = layout.currentLink.appendingPathComponent("bin/codex")
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: currentLauncher)
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity],
            runningStates: [false]
        )
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminatedPIDs == [testRecord.pid])
    }

    @Test("Healthy updater from current release is never terminated")
    func currentReleaseUpdaterIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: layout.currentExecutable)
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("A current updater with a validated zombie app-server child is terminated")
    func currentUpdaterWithZombieChildIsTerminated() async throws {
        let layout = try StandaloneLayout()
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(layout: layout))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(
            identities: [updater, updater, updater],
            runningStates: [false]
        )
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord,
            staleConfirmationInterval: 30
        )

        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminatedPIDs == [testRecord.pid])
    }

    @Test("An old managed updater with a zombie child is terminated immediately")
    func oldUpdaterWithZombieChildIsTerminatedImmediately() async throws {
        let layout = try StandaloneLayout()
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(
            layout: layout,
            updaterCommandExecutable: layout.currentExecutable
        ))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [updater, updater, updater],
            runningStates: [false]
        )
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord,
            staleConfirmationInterval: 30
        )

        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminatedPIDs == [testRecord.pid])
    }

    @Test("A non-zombie app-server child never terminates the current updater")
    func liveChildRejectsCurrentUpdaterRecovery() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(layout: layout, childState: "R"))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(identities: [updater, updater])
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord
        )

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("A zombie with another parent never terminates the current updater")
    func foreignParentZombieIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(layout: layout, childParentPID: testRecord.pid + 1))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(identities: [updater, updater])
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord
        )

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("A reused app-server PID never terminates the current updater")
    func reusedAppServerPIDIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(
            layout: layout,
            childStartTime: "Mon Jul 20 16:02:18 2026"
        ))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(identities: [updater, updater])
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord
        )

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("An existing control socket prevents current-updater recovery")
    func existingSocketPreventsCurrentUpdaterRecovery() async throws {
        let layout = try StandaloneLayout()
        let socket = layout.homeDirectory.appendingPathComponent(
            ".codex/app-server-control/app-server-control.sock"
        )
        try FileManager.default.createDirectory(
            at: socket.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(layout: layout))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(identities: [updater, updater])
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord
        )

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("PID reuse detected by start-time mismatch is never terminated")
    func reusedPIDIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: "\(getuid()) Mon Jul 13 05:17:14 2026 \(layout.oldExecutable.path) app-server daemon pid-update-loop"
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("Updater owned by another user is never terminated")
    func foreignUIDIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: layout.oldExecutable)
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid() + 1, executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("Near-match process arguments are never terminated")
    func nearMatchArgumentsAreRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: "\(getuid()) \(testRecord.processStartTime) \(layout.oldExecutable.path) app-server daemon pid-update-loop extra"
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("Updater outside standalone releases is never terminated")
    func executableOutsideReleasesIsRejected() async {
        let layout = try! StandaloneLayout()
        let outside = layout.homeDirectory.appendingPathComponent(".codex-malicious/codex")
        let runner = RecoveryRunner(results: recoveryResults(processLine: processLine(executable: outside)))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: outside.path)
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("A custom CLI can never trigger standalone updater cleanup")
    func customCLIIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: [
            .success(.init(exitCode: 1, stdout: Data(), stderr: Data())),
        ])
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(identities: [identity])
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(
            recovery,
            codexURL: layout.homeDirectory.appendingPathComponent("custom/codex")
        )

        #expect(controller.terminateCallCount == 0)
    }

    @Test("Changing current release during validation aborts without signaling")
    func currentTargetRaceIsRejected() async {
        let layout = try! StandaloneLayout()
        let runner = RecoveryRunner(results: recoveryResults(
            processLine: processLine(executable: layout.oldExecutable)
        ))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity],
            onIdentity: {
                try? FileManager.default.removeItem(at: layout.currentLink)
                try? FileManager.default.createSymbolicLink(
                    at: layout.currentLink,
                    withDestinationURL: layout.oldRelease
                )
            }
        )
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 0)
    }

    @Test("The same stale fingerprint is never signaled twice")
    func sameFingerprintIsNotSignaledTwice() async {
        let layout = try! StandaloneLayout()
        let line = processLine(executable: layout.oldExecutable)
        let runner = RecoveryRunner(results: recoveryResults(processLine: line) + recoveryResults(processLine: line))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity, identity, identity],
            runningStates: [true]
        )
        let recovery = makeRecovery(layout: layout, runner: runner, controller: controller)

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)
        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 1)
    }

    @Test("The same current-zombie fingerprint is never signaled twice")
    func sameCurrentZombieFingerprintIsNotSignaledTwice() async throws {
        let layout = try StandaloneLayout()
        let runner = RecoveryRunner(results: currentZombieRecoveryResults(layout: layout) + currentZombieRecoveryResults(layout: layout))
        let updater = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.currentExecutable.path)
        let controller = RecoveryProcessController(
            identities: [updater, updater, updater, updater, updater, updater],
            runningStates: [false]
        )
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            appServerRecord: zombieChildRecord,
            staleConfirmationInterval: 30
        )

        try await recovery.recover(codexURL: layout.currentExecutable)
        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 1)
    }

    @Test("A stale fingerprint must remain stable for the confirmation interval")
    func staleFingerprintRequiresTemporalConfirmation() async throws {
        let layout = try StandaloneLayout()
        let line = processLine(executable: layout.oldExecutable)
        let runner = RecoveryRunner(results: recoveryResults(processLine: line) + recoveryResults(processLine: line))
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity, identity, identity],
            runningStates: [false]
        )
        let clock = RecoveryClock(now: Date(timeIntervalSince1970: 1_000))
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            staleConfirmationInterval: 30,
            now: { clock.now }
        )

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)
        #expect(controller.terminateCallCount == 0)

        clock.advance(by: 30)
        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 1)
    }

    @Test("An intermediate old-updater observation does not delay confirmation")
    func repeatedOldFingerprintKeepsOriginalConfirmationTime() async throws {
        let layout = try StandaloneLayout()
        let line = processLine(executable: layout.oldExecutable)
        let runner = RecoveryRunner(results:
            recoveryResults(processLine: line) + recoveryResults(processLine: line) + recoveryResults(processLine: line)
        )
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity, identity, identity, identity, identity],
            runningStates: [false]
        )
        let clock = RecoveryClock(now: Date(timeIntervalSince1970: 1_000))
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            staleConfirmationInterval: 30,
            now: { clock.now }
        )

        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)
        clock.advance(by: 10)
        await expectRecoveryFailure(recovery, codexURL: layout.currentExecutable)
        clock.advance(by: 20)
        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 1)
    }

    @Test("Official Stop success retries temporal confirmation before signaling once")
    func officialStopSuccessRetriesTemporalConfirmation() async throws {
        let layout = try StandaloneLayout()
        let line = processLine(executable: layout.oldExecutable)
        let results = recoveryResults(processLine: line, stopExitCode: 0)
        let runner = RecoveryRunner(results: results + results)
        let identity = StaleUpdaterProcessIdentity(uid: getuid(), executablePath: layout.oldExecutable.path)
        let controller = RecoveryProcessController(
            identities: [identity, identity, identity, identity],
            runningStates: [false]
        )
        let clock = RecoveryClock(now: Date(timeIntervalSince1970: 1_000))
        let recovery = makeRecovery(
            layout: layout,
            runner: runner,
            controller: controller,
            staleConfirmationInterval: 30,
            now: { clock.now }
        )

        try await recovery.recover(codexURL: layout.currentExecutable)
        #expect(controller.terminateCallCount == 0)

        clock.advance(by: 30)
        try await recovery.recover(codexURL: layout.currentExecutable)

        #expect(controller.terminateCallCount == 1)
    }

    @Test("Secure PID loader rejects symbolic links")
    func pidLoaderRejectsSymbolicLink() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRemotePIDLoaderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let daemonDirectory = home.appendingPathComponent(".codex/app-server-daemon")
        try FileManager.default.createDirectory(at: daemonDirectory, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("record.json")
        try Data(#"{"pid":42,"processStartTime":"time"}"#.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: daemonDirectory.appendingPathComponent("app-server-updater.pid"),
            withDestinationURL: target
        )

        let loader = SecureStaleUpdaterPIDRecordLoader(homeDirectory: home)

        #expect(throws: StaleUpdaterRecoveryError.self) {
            _ = try loader.load()
        }
    }
}

private let testRecord = StaleUpdaterPIDRecord(
    pid: 10_128,
    processStartTime: "Sat Jul 11 19:49:39 2026"
)

private let zombieChildRecord = StaleUpdaterPIDRecord(
    pid: 10_129,
    processStartTime: "Tue Jul 21 16:02:18 2026"
)

private func makeRecovery(
    layout: StandaloneLayout,
    runner: RecoveryRunner,
    controller: RecoveryProcessController,
    appServerRecord: StaleUpdaterPIDRecord = testRecord,
    staleConfirmationInterval: TimeInterval = 0,
    now: @escaping () -> Date = Date.init
) -> StaleUpdaterRecovery {
    StaleUpdaterRecovery(
        runner: runner,
        pidRecordLoader: FixedPIDRecordLoader(record: testRecord),
        appServerPIDRecordLoader: FixedPIDRecordLoader(record: appServerRecord),
        processController: controller,
        homeDirectory: layout.homeDirectory,
        terminationPollNanoseconds: 0,
        terminationPollAttempts: 1,
        staleConfirmationInterval: staleConfirmationInterval,
        now: now
    )
}

private func recoveryResults(
    processLine: String,
    stopExitCode: Int32 = 1
) -> [Result<ProcessResult, Error>] {
    [
        .success(.init(exitCode: stopExitCode, stdout: Data(), stderr: Data())),
        .success(.init(exitCode: 0, stdout: Data((processLine + "\n").utf8), stderr: Data())),
        .success(.init(exitCode: 0, stdout: Data((processLine + "\n").utf8), stderr: Data())),
    ]
}

private func currentZombieRecoveryResults(
    layout: StandaloneLayout,
    updaterCommandExecutable: URL? = nil,
    childParentPID: Int32 = testRecord.pid,
    childState: String = "Z",
    childStartTime: String = zombieChildRecord.processStartTime
) -> [Result<ProcessResult, Error>] {
    [
        .success(.init(exitCode: 1, stdout: Data(), stderr: Data())),
        .success(.init(exitCode: 0, stdout: Data((processLine(executable: updaterCommandExecutable ?? layout.currentExecutable) + "\n").utf8), stderr: Data())),
        .success(.init(exitCode: 0, stdout: Data((zombieProcessLine(parentPID: childParentPID, state: childState, startTime: childStartTime) + " <defunct>\n").utf8), stderr: Data())),
        .success(.init(exitCode: 0, stdout: Data((processLine(executable: updaterCommandExecutable ?? layout.currentExecutable) + "\n").utf8), stderr: Data())),
        .success(.init(exitCode: 0, stdout: Data((zombieProcessLine(parentPID: childParentPID, state: childState, startTime: childStartTime) + " <defunct>\n").utf8), stderr: Data())),
    ]
}

private func processLine(executable: URL) -> String {
    "\(getuid()) \(testRecord.processStartTime) \(executable.path) app-server daemon pid-update-loop"
}

private func zombieProcessLine(parentPID: Int32, state: String, startTime: String) -> String {
    "\(getuid()) \(parentPID) \(state) \(startTime)"
}

private func expectRecoveryFailure(_ recovery: StaleUpdaterRecovery, codexURL: URL) async {
    do {
        try await recovery.recover(codexURL: codexURL)
        Issue.record("A recuperacao deveria falhar de forma segura")
    } catch {
        #expect(error is StaleUpdaterRecoveryError)
    }
}

private struct FixedPIDRecordLoader: StaleUpdaterPIDRecordLoading {
    let record: StaleUpdaterPIDRecord

    func load() throws -> StaleUpdaterPIDRecord { record }
}

private actor RecoveryRunner: ProcessRunning {
    private var results: [Result<ProcessResult, Error>]
    private(set) var arguments: [[String]] = []

    init(results: [Result<ProcessResult, Error>]) {
        self.results = results
    }

    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        self.arguments.append(arguments)
        guard !results.isEmpty else {
            throw ProcessRunnerError.launchFailed("resultado falso ausente")
        }
        return try results.removeFirst().get()
    }
}

private final class RecoveryProcessController: StaleUpdaterProcessControlling, @unchecked Sendable {
    private var identities: [StaleUpdaterProcessIdentity]
    private var runningStates: [Bool]
    private let onIdentity: (() -> Void)?
    private(set) var terminatedPIDs: [Int32] = []
    private(set) var identityCallCount = 0

    init(
        identities: [StaleUpdaterProcessIdentity],
        runningStates: [Bool] = [],
        onIdentity: (() -> Void)? = nil
    ) {
        self.identities = identities
        self.runningStates = runningStates
        self.onIdentity = onIdentity
    }

    var terminateCallCount: Int { terminatedPIDs.count }

    func identity(pid: Int32) throws -> StaleUpdaterProcessIdentity {
        identityCallCount += 1
        onIdentity?()
        guard !identities.isEmpty else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("identidade falsa ausente")
        }
        return identities.removeFirst()
    }

    func terminate(pid: Int32) throws {
        terminatedPIDs.append(pid)
    }

    func isRunning(pid: Int32) -> Bool {
        guard !runningStates.isEmpty else { return false }
        return runningStates.removeFirst()
    }
}

private final class StandaloneLayout {
    let homeDirectory: URL
    let releasesRoot: URL
    let oldRelease: URL
    let newRelease: URL
    let oldExecutable: URL
    let newExecutable: URL
    let currentLink: URL

    var currentExecutable: URL {
        currentLink.appendingPathComponent("bin/codex").resolvingSymlinksInPath()
    }

    init() throws {
        homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexRemoteRecoveryTests-\(UUID().uuidString)")
        releasesRoot = homeDirectory.appendingPathComponent(".codex/packages/standalone/releases")
        oldRelease = releasesRoot.appendingPathComponent("0.144.2-aarch64-apple-darwin")
        newRelease = releasesRoot.appendingPathComponent("0.144.3-aarch64-apple-darwin")
        oldExecutable = oldRelease.appendingPathComponent("bin/codex")
        newExecutable = newRelease.appendingPathComponent("bin/codex")
        currentLink = homeDirectory.appendingPathComponent(".codex/packages/standalone/current")

        try FileManager.default.createDirectory(
            at: oldExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: newExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: oldExecutable.path, contents: Data())
        FileManager.default.createFile(atPath: newExecutable.path, contents: Data())
        try FileManager.default.createSymbolicLink(at: currentLink, withDestinationURL: newRelease)
    }

    deinit {
        try? FileManager.default.removeItem(at: homeDirectory)
    }
}

private final class RecoveryClock: @unchecked Sendable {
    private(set) var now: Date

    init(now: Date) {
        self.now = now
    }

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
