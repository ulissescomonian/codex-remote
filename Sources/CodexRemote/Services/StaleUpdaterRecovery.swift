import Darwin
import Foundation

public protocol StaleUpdaterRecovering: Sendable {
    func recover(codexURL: URL) async throws
}

public enum StaleUpdaterRecoveryError: LocalizedError, Equatable, Sendable {
    case unsafeCandidate(String)
    case processDidNotExit

    public var errorDescription: String? {
        switch self {
        case .unsafeCandidate(let reason):
            "A recuperacao automatica foi cancelada por seguranca: \(reason)"
        case .processDidNotExit:
            "O updater antigo do Codex nao encerrou apos a solicitacao segura."
        }
    }
}

struct StaleUpdaterPIDRecord: Codable, Equatable, Sendable {
    let pid: Int32
    let processStartTime: String
}

protocol StaleUpdaterPIDRecordLoading: Sendable {
    func load() throws -> StaleUpdaterPIDRecord
}

protocol StaleUpdaterProcessControlling: Sendable {
    func identity(pid: Int32) throws -> StaleUpdaterProcessIdentity
    func terminate(pid: Int32) throws
    func isRunning(pid: Int32) -> Bool
}

struct StaleUpdaterProcessIdentity: Equatable, Sendable {
    let uid: uid_t
    let executablePath: String
}

public final class StaleUpdaterRecovery: StaleUpdaterRecovering, @unchecked Sendable {
    private static let updaterCommandSuffix = " app-server daemon pid-update-loop"

    private let runner: any ProcessRunning
    private let pidRecordLoader: any StaleUpdaterPIDRecordLoading
    private let appServerPIDRecordLoader: any StaleUpdaterPIDRecordLoading
    private let processController: any StaleUpdaterProcessControlling
    private let homeDirectory: URL
    private let stopTimeout: TimeInterval
    private let inspectionTimeout: TimeInterval
    private let terminationPollNanoseconds: UInt64
    private let terminationPollAttempts: Int
    private let staleConfirmationInterval: TimeInterval
    private let now: () -> Date
    private let stateLock = NSLock()
    private var signaledFingerprints: Set<StaleUpdaterFingerprint> = []
    private var pendingFingerprint: (fingerprint: StaleUpdaterFingerprint, firstSeenAt: Date)?

    public convenience init(runner: any ProcessRunning) {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            runner: runner,
            pidRecordLoader: SecureStaleUpdaterPIDRecordLoader(homeDirectory: homeDirectory),
            appServerPIDRecordLoader: SecureStaleUpdaterPIDRecordLoader(
                homeDirectory: homeDirectory,
                fileName: "app-server.pid"
            ),
            processController: DarwinStaleUpdaterProcessController(),
            homeDirectory: homeDirectory
        )
    }

    init(
        runner: any ProcessRunning,
        pidRecordLoader: any StaleUpdaterPIDRecordLoading,
        appServerPIDRecordLoader: any StaleUpdaterPIDRecordLoading,
        processController: any StaleUpdaterProcessControlling,
        homeDirectory: URL,
        stopTimeout: TimeInterval = 5,
        inspectionTimeout: TimeInterval = 2,
        terminationPollNanoseconds: UInt64 = 100_000_000,
        terminationPollAttempts: Int = 20,
        staleConfirmationInterval: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.runner = runner
        self.pidRecordLoader = pidRecordLoader
        self.appServerPIDRecordLoader = appServerPIDRecordLoader
        self.processController = processController
        self.homeDirectory = homeDirectory
        self.stopTimeout = stopTimeout
        self.inspectionTimeout = inspectionTimeout
        self.terminationPollNanoseconds = terminationPollNanoseconds
        self.terminationPollAttempts = terminationPollAttempts
        self.staleConfirmationInterval = staleConfirmationInterval
        self.now = now
    }

    public func recover(codexURL: URL) async throws {
        let stopSucceeded = await officialStopSucceeded(codexURL: codexURL)

        let record: StaleUpdaterPIDRecord
        do {
            // A recorded zombie child is terminal and is therefore repaired
            // before considering a merely old updater that needs time-based
            // confirmation. Updates can leave the parent mapped to its old
            // release while its command launcher already resolves to current.
            record = try await validatedUpdaterWithZombieChild(codexURL: codexURL)
        } catch {
            do {
                record = try await validatedStaleUpdater(codexURL: codexURL)
            } catch {
                // The official Stop is sufficient when neither exceptional
                // process shape can be proven safe to signal.
                if stopSucceeded { return }
                throw error
            }
        }

        try processController.terminate(pid: record.pid)
        for _ in 0..<max(1, terminationPollAttempts) {
            if !processController.isRunning(pid: record.pid) { return }
            try? await Task.sleep(nanoseconds: terminationPollNanoseconds)
        }
        throw StaleUpdaterRecoveryError.processDidNotExit
    }

    private func validatedStaleUpdater(codexURL: URL) async throws -> StaleUpdaterPIDRecord {
        let initialCurrentTarget = try resolveCurrentCodexTarget()
        guard canonicalURL(codexURL) == initialCurrentTarget else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o comando que falhou nao e a release standalone atual")
        }

        let record = try pidRecordLoader.load()
        guard record.pid > 1, !record.processStartTime.isEmpty else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("registro de processo invalido")
        }

        let initialProcessFingerprint = try await inspect(
            record: record,
            codexURL: codexURL,
            currentTarget: initialCurrentTarget,
            releaseRequirement: .old
        )
        let initialFingerprint = StaleUpdaterFingerprint(updater: initialProcessFingerprint)

        // Re-read every externally mutable identity immediately before signaling.
        let finalCurrentTarget = try resolveCurrentCodexTarget()
        guard finalCurrentTarget == initialCurrentTarget else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("a versao atual do Codex mudou durante a verificacao")
        }
        let finalProcessFingerprint = try await inspect(
            record: record,
            codexURL: codexURL,
            currentTarget: finalCurrentTarget,
            releaseRequirement: .old
        )
        let finalFingerprint = StaleUpdaterFingerprint(updater: finalProcessFingerprint)
        guard finalFingerprint == initialFingerprint else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("a identidade do updater mudou durante a verificacao")
        }
        guard try resolveCurrentCodexTarget() == initialCurrentTarget else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("a versao atual do Codex mudou antes do encerramento")
        }
        guard confirmFingerprintForFirstSignal(
            finalFingerprint,
            requiresTemporalConfirmation: true
        ) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate(
                "o updater antigo ainda aguarda confirmacao temporal ou ja recebeu encerramento"
            )
        }
        return record
    }

    /// Handles the precise failure observed after a Codex update: an updater
    /// from any managed standalone release remains alive while its recorded
    /// app-server child is a zombie.
    /// Both secured PID records must validate twice before the updater alone
    /// can receive SIGTERM.
    private func validatedUpdaterWithZombieChild(codexURL: URL) async throws -> StaleUpdaterPIDRecord {
        let initialCurrentTarget = try resolveCurrentCodexTarget()
        guard canonicalURL(codexURL) == initialCurrentTarget else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o comando que falhou nao e a release standalone atual")
        }

        let updaterRecord = try validatedRecord(pidRecordLoader.load())
        let appServerRecord = try validatedRecord(appServerPIDRecordLoader.load())
        guard updaterRecord.pid != appServerRecord.pid else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("os registros do updater e app-server usam o mesmo PID")
        }

        let initialUpdater = try await inspect(
            record: updaterRecord,
            codexURL: codexURL,
            currentTarget: initialCurrentTarget,
            releaseRequirement: .managed
        )
        let initialChild = try await inspectZombieChild(
            record: appServerRecord,
            expectedParentPID: updaterRecord.pid
        )
        let initialFingerprint = StaleUpdaterFingerprint(
            updater: initialUpdater,
            zombieChild: initialChild
        )

        guard !FileManager.default.fileExists(
            atPath: controlSocketURL.path
        ) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o socket do app-server ainda existe")
        }

        // Re-read every mutable source immediately before the signal.
        let finalCurrentTarget = try resolveCurrentCodexTarget()
        guard finalCurrentTarget == initialCurrentTarget else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("a versao atual do Codex mudou durante a verificacao")
        }
        let finalUpdaterRecord = try validatedRecord(pidRecordLoader.load())
        let finalAppServerRecord = try validatedRecord(appServerPIDRecordLoader.load())
        guard finalUpdaterRecord == updaterRecord, finalAppServerRecord == appServerRecord else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("os registros de processo mudaram durante a verificacao")
        }
        let finalUpdater = try await inspect(
            record: finalUpdaterRecord,
            codexURL: codexURL,
            currentTarget: finalCurrentTarget,
            releaseRequirement: .managed
        )
        let finalChild = try await inspectZombieChild(
            record: finalAppServerRecord,
            expectedParentPID: finalUpdaterRecord.pid
        )
        let finalFingerprint = StaleUpdaterFingerprint(updater: finalUpdater, zombieChild: finalChild)
        guard finalFingerprint == initialFingerprint else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("a identidade dos processos mudou durante a verificacao")
        }
        guard !FileManager.default.fileExists(
            atPath: controlSocketURL.path
        ) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o socket do app-server reapareceu antes do encerramento")
        }
        // A zombie is terminal and both process records have just been
        // revalidated. Unlike an old live updater, waiting would only leave
        // the daemon unavailable; the fingerprint remains one-shot.
        guard confirmFingerprintForFirstSignal(
            finalFingerprint,
            requiresTemporalConfirmation: false
        ) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate(
                "o updater com filho zumbi ja recebeu encerramento para esta identidade"
            )
        }
        return updaterRecord
    }

    private func validatedRecord(_ record: StaleUpdaterPIDRecord) throws -> StaleUpdaterPIDRecord {
        guard record.pid > 1, !record.processStartTime.isEmpty else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("registro de processo invalido")
        }
        return record
    }

    private var controlSocketURL: URL {
        homeDirectory.appendingPathComponent(".codex/app-server-control/app-server-control.sock")
    }

    private func confirmFingerprintForFirstSignal(
        _ fingerprint: StaleUpdaterFingerprint,
        requiresTemporalConfirmation: Bool
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !signaledFingerprints.contains(fingerprint) else { return false }

        let timestamp = now()
        if requiresTemporalConfirmation, staleConfirmationInterval > 0 {
            if let pendingFingerprint, pendingFingerprint.fingerprint == fingerprint {
                guard timestamp.timeIntervalSince(pendingFingerprint.firstSeenAt) >= staleConfirmationInterval else {
                    return false
                }
            } else {
                pendingFingerprint = (fingerprint, timestamp)
                return false
            }
        }

        pendingFingerprint = nil
        signaledFingerprints.insert(fingerprint)
        return true
    }

    private func officialStopSucceeded(codexURL: URL) async -> Bool {
        do {
            let result = try await runner.run(
                executable: codexURL,
                arguments: ["remote-control", "stop", "--json"],
                environment: nil,
                timeout: stopTimeout
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    private func inspect(
        record: StaleUpdaterPIDRecord,
        codexURL: URL,
        currentTarget: URL,
        releaseRequirement: ReleaseRequirement
    ) async throws -> StaleUpdaterProcessFingerprint {
        let identity: StaleUpdaterProcessIdentity
        do {
            identity = try processController.identity(pid: record.pid)
        } catch {
            throw StaleUpdaterRecoveryError.unsafeCandidate("nao foi possivel confirmar a identidade do updater")
        }
        guard identity.uid == getuid() else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o updater pertence a outro usuario")
        }

        let actualExecutable = canonicalURL(URL(fileURLWithPath: identity.executablePath))
        let releasesRoot = canonicalURL(
            homeDirectory.appendingPathComponent(".codex/packages/standalone/releases", isDirectory: true)
        )
        guard isDescendant(actualExecutable, of: releasesRoot) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o executavel nao pertence as releases standalone do Codex")
        }
        switch releaseRequirement {
        case .old:
            guard actualExecutable != currentTarget else {
                throw StaleUpdaterRecoveryError.unsafeCandidate("o updater pertence a versao atual do Codex")
            }
        case .current:
            guard actualExecutable == currentTarget else {
                throw StaleUpdaterRecoveryError.unsafeCandidate("o updater nao pertence a versao atual do Codex")
            }
        case .managed:
            break
        }

        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-ww", "-p", String(record.pid), "-o", "uid=", "-o", "lstart=", "-o", "command="],
                environment: ["LC_ALL": "C"],
                timeout: inspectionTimeout
            )
        } catch {
            throw StaleUpdaterRecoveryError.unsafeCandidate("nao foi possivel inspecionar o updater")
        }
        guard result.exitCode == 0,
              let processLine = result.stdoutString
                .split(whereSeparator: \Character.isNewline)
                .first
                .map(String.init)
        else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o updater nao esta mais em execucao")
        }

        let trimmedLine = processLine.trimmingCharacters(in: .whitespaces)
        let uidAndRemainder = trimmedLine.split(
            maxSplits: 1,
            whereSeparator: \Character.isWhitespace
        )
        guard uidAndRemainder.count == 2,
              let psUID = uid_t(uidAndRemainder[0]),
              psUID == identity.uid
        else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o usuario do updater nao confere")
        }

        let expectedStartPrefix = record.processStartTime + " "
        let startAndCommand = String(uidAndRemainder[1])
        guard startAndCommand.hasPrefix(expectedStartPrefix) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o PID foi reutilizado por outro processo")
        }
        let command = String(startAndCommand.dropFirst(expectedStartPrefix.count))
        guard command.hasSuffix(Self.updaterCommandSuffix) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("os argumentos do processo nao correspondem ao updater")
        }
        let commandExecutable = String(command.dropLast(Self.updaterCommandSuffix.count))
        guard commandExecutable.hasPrefix("/") else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o launcher do updater nao possui path absoluto")
        }
        let commandURL = URL(fileURLWithPath: commandExecutable).standardizedFileURL
        let directReleasePathMatches = canonicalURL(commandURL) == actualExecutable
        let currentReleasePathMatches = canonicalURL(commandURL) == currentTarget
        let allowedLaunchers = Set([
            codexURL.standardizedFileURL,
            homeDirectory.appendingPathComponent(".local/bin/codex").standardizedFileURL,
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/codex").standardizedFileURL,
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex").standardizedFileURL,
        ])
        guard directReleasePathMatches || currentReleasePathMatches || allowedLaunchers.contains(commandURL) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o launcher do updater nao pertence ao Codex standalone atual")
        }

        return StaleUpdaterProcessFingerprint(
            pid: record.pid,
            processStartTime: record.processStartTime,
            uid: identity.uid,
            executable: actualExecutable
        )
    }

    private func inspectZombieChild(
        record: StaleUpdaterPIDRecord,
        expectedParentPID: Int32
    ) async throws -> StaleUpdaterProcessFingerprint {
        // macOS deliberately hides libproc executable metadata once a process
        // is a zombie. The current updater's executable is validated above;
        // this child is authenticated by its independently secured PID record
        // plus the kernel's uid, PPID, state and start-time reported by ps.
        let result: ProcessResult
        do {
            result = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: [
                    "-ww", "-p", String(record.pid),
                    "-o", "uid=", "-o", "ppid=", "-o", "stat=",
                    "-o", "lstart=", "-o", "command=",
                ],
                environment: ["LC_ALL": "C"],
                timeout: inspectionTimeout
            )
        } catch {
            throw StaleUpdaterRecoveryError.unsafeCandidate("nao foi possivel inspecionar o app-server")
        }
        guard result.exitCode == 0,
              let line = result.stdoutString.split(whereSeparator: \.isNewline).first.map(String.init)
        else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o app-server nao esta mais em execucao")
        }
        let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 3, whereSeparator: \.isWhitespace)
        guard fields.count == 4,
              let uid = uid_t(fields[0]), uid == getuid(),
              let parentPID = Int32(fields[1]), parentPID == expectedParentPID,
              fields[2].first == "Z",
              String(fields[3]).hasPrefix(record.processStartTime + " ")
        else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o app-server nao e um filho zumbi seguro do updater")
        }
        return StaleUpdaterProcessFingerprint(
            pid: record.pid,
            processStartTime: record.processStartTime,
            uid: uid,
            executable: nil
        )
    }

    private func resolveCurrentCodexTarget() throws -> URL {
        let candidates = [
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            homeDirectory.appendingPathComponent(".codex/packages/standalone/current/codex"),
        ]
        guard let candidate = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("a release standalone atual do Codex nao foi encontrada")
        }
        let resolved = canonicalURL(candidate)
        let releasesRoot = canonicalURL(
            homeDirectory.appendingPathComponent(".codex/packages/standalone/releases", isDirectory: true)
        )
        guard isDescendant(resolved, of: releasesRoot) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o alvo current nao pertence as releases standalone")
        }
        return resolved
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

private enum ReleaseRequirement {
    case old
    case current
    case managed
}

private struct StaleUpdaterProcessFingerprint: Hashable, Sendable {
    let pid: Int32
    let processStartTime: String
    let uid: uid_t
    let executable: URL?
}

private struct StaleUpdaterFingerprint: Hashable, Sendable {
    let updater: StaleUpdaterProcessFingerprint
    let zombieChild: StaleUpdaterProcessFingerprint?

    init(updater: StaleUpdaterProcessFingerprint) {
        self.updater = updater
        zombieChild = nil
    }

    init(updater: StaleUpdaterProcessFingerprint, zombieChild: StaleUpdaterProcessFingerprint) {
        self.updater = updater
        self.zombieChild = zombieChild
    }
}

struct SecureStaleUpdaterPIDRecordLoader: StaleUpdaterPIDRecordLoading, Sendable {
    private static let maximumSize: off_t = 4_096
    private let fileURL: URL

    init(homeDirectory: URL, fileName: String = "app-server-updater.pid") {
        fileURL = homeDirectory.appendingPathComponent(
            ".codex/app-server-daemon/\(fileName)"
        )
    }

    func load() throws -> StaleUpdaterPIDRecord {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o registro do updater nao e um arquivo seguro")
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_size > 0,
              metadata.st_size <= Self.maximumSize
        else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o registro do updater falhou na validacao")
        }

        var data = Data(count: Int(metadata.st_size))
        let bytesRead = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return -1 }
            return Darwin.read(descriptor, baseAddress, buffer.count)
        }
        guard bytesRead == data.count,
              let record = try? JSONDecoder().decode(StaleUpdaterPIDRecord.self, from: data)
        else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o registro do updater possui JSON invalido")
        }
        return record
    }
}

private struct DarwinStaleUpdaterProcessController: StaleUpdaterProcessControlling, Sendable {
    func identity(pid: Int32) throws -> StaleUpdaterProcessIdentity {
        var processInfo = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.size
        let infoSize = withUnsafeMutablePointer(to: &processInfo) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, Int32(expectedSize))
        }
        guard infoSize == Int32(expectedSize) else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o processo nao esta acessivel")
        }

        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLength > 0 else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o executavel do processo nao esta acessivel")
        }
        return StaleUpdaterProcessIdentity(
            uid: processInfo.pbi_uid,
            executablePath: String(cString: pathBuffer)
        )
    }

    func terminate(pid: Int32) throws {
        guard Darwin.kill(pid, SIGTERM) == 0 || errno == ESRCH else {
            throw StaleUpdaterRecoveryError.unsafeCandidate("o macOS recusou encerrar o updater antigo")
        }
    }

    func isRunning(pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
