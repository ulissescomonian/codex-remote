import Darwin
import Foundation
import Testing
@testable import CodexRemote

@Suite("Process Runner")
struct ProcessRunnerTests {
    @Test("Timeout completes even when a descendant keeps output pipes open")
    func timeoutDoesNotWaitForDescendantPipeEOF() async {
        let runner = ProcessRunner()
        let timeout: TimeInterval = 0.1
        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 1 &"],
                timeout: timeout
            )
            Issue.record("Expected the process execution to time out")
        } catch {
            #expect(error as? ProcessRunnerError == .timedOut(seconds: timeout))
        }

        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(50))
        #expect(elapsed < .milliseconds(750))
    }

    @Test("Timeout waits for the parent process to terminate")
    func timeoutWaitsForParentTermination() async throws {
        let runner = ProcessRunner()
        let timeout: TimeInterval = 0.1
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-remote-process-runner-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let clock = ContinuousClock()
        let startedAt = clock.now

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "echo $$ > \"$1\"; trap '' TERM; while :; do :; done",
                    "sh",
                    pidFile.path,
                ],
                timeout: timeout
            )
            Issue.record("Expected the process execution to time out")
        } catch {
            #expect(error as? ProcessRunnerError == .timedOut(seconds: timeout))
        }

        let elapsed = startedAt.duration(to: clock.now)
        #expect(elapsed >= .milliseconds(500))
        #expect(elapsed < .seconds(2))

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))

        errno = 0
        #expect(Darwin.kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test("Normal command captures complete standard output and error")
    func capturesNormalCommandOutput() async throws {
        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf standard-output; printf standard-error >&2"],
            timeout: 2
        )

        #expect(result.exitCode == 0)
        #expect(result.stdoutString == "standard-output")
        #expect(result.stderrString == "standard-error")
    }
}
