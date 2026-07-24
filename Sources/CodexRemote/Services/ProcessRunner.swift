import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            return "Nao foi possivel executar o Codex: \(message)"
        case .timedOut(let seconds):
            return "O Codex nao respondeu em \(seconds.formatted()) segundos."
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) async throws -> ProcessResult
}

public extension ProcessRunning {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 10
    ) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, environment: nil, timeout: timeout)
    }
}

public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let state = ExecutionState(continuation: continuation, timeout: timeout)

            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            if let environment { process.environment = environment }

            state.process = process
            state.outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                state.stdout = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                state.outputGroup.leave()
            }
            state.outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                state.stderr = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                state.outputGroup.leave()
            }

            process.terminationHandler = { terminatedProcess in
                state.processDidTerminate(exitCode: terminatedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForWriting.closeFile()
                stderrPipe.fileHandleForWriting.closeFile()
                state.outputGroup.notify(queue: state.queue) {
                    state.failLaunch(error.localizedDescription)
                }
                return
            }

            state.scheduleTimeout()
        }
    }
}

private final class ExecutionState: @unchecked Sendable {
    let queue = DispatchQueue(label: "app.codexremote.macos.process-state")
    let outputGroup = DispatchGroup()
    let timeout: TimeInterval
    var stdout = Data()
    var stderr = Data()
    var process: Process?

    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var didTimeOut = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(continuation: CheckedContinuation<ProcessResult, Error>, timeout: TimeInterval) {
        self.continuation = continuation
        self.timeout = timeout
    }

    func scheduleTimeout() {
        let workItem = DispatchWorkItem { [weak self] in self?.timeOut() }
        timeoutWorkItem = workItem
        queue.asyncAfter(deadline: .now() + max(0, timeout), execute: workItem)
    }

    func processDidTerminate(exitCode: Int32) {
        queue.async { [self] in
            if didTimeOut {
                finishTimeout()
            } else {
                outputGroup.notify(queue: queue) { [self] in
                    finish(exitCode: exitCode)
                }
            }
        }
    }

    private func finish(exitCode: Int32) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutWorkItem?.cancel()
        continuation.resume(returning: ProcessResult(exitCode: exitCode, stdout: stdout, stderr: stderr))
    }

    func failLaunch(_ message: String) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutWorkItem?.cancel()
        continuation.resume(throwing: ProcessRunnerError.launchFailed(message))
    }

    private func timeOut() {
        guard continuation != nil else { return }
        didTimeOut = true

        if let process, process.isRunning {
            process.terminate()

            queue.asyncAfter(deadline: .now() + 0.5) { [weak process] in
                guard let process, process.isRunning else { return }
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        } else {
            finishTimeout()
        }
    }

    private func finishTimeout() {
        guard let continuation else { return }
        self.continuation = nil
        timeoutWorkItem?.cancel()
        continuation.resume(throwing: ProcessRunnerError.timedOut(seconds: timeout))
    }
}
