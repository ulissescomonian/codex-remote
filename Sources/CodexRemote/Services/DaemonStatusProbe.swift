import Foundation

public protocol DaemonStatusProbing: Sendable {
    func status(codexURL: URL) async -> DaemonState
}

public struct DaemonStatusProbe: DaemonStatusProbing, Sendable {
    private let runner: any ProcessRunning
    private let timeout: TimeInterval

    public init(runner: any ProcessRunning, timeout: TimeInterval = 4) {
        self.runner = runner
        self.timeout = timeout
    }

    public func status(codexURL: URL) async -> DaemonState {
        do {
            let result = try await runner.run(
                executable: codexURL,
                arguments: ["app-server", "daemon", "version"],
                environment: nil,
                timeout: timeout
            )
            if result.exitCode == 0 {
                return parseVersion(result.stdout) ?? .unknown("O daemon respondeu com JSON invalido.")
            }

            let details = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if Self.meansStopped(details) { return .stopped }
            return .unknown(Self.safeMessage(details, fallback: "Falha ao consultar o daemon (codigo \(result.exitCode))."))
        } catch let error as ProcessRunnerError {
            return .unknown(error.localizedDescription)
        } catch {
            return .unknown("Nao foi possivel consultar o daemon: \(error.localizedDescription)")
        }
    }

    private func parseVersion(_ data: Data) -> DaemonState? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return nil }

        let cli = Self.string(in: dictionary, keys: ["cliVersion", "cli_version", "codexVersion", "codex_version"])
        let server = Self.string(in: dictionary, keys: ["appServerVersion", "app_server_version", "serverVersion", "server_version"])
        return .running(cliVersion: cli, appServerVersion: server)
    }

    private static func string(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        for value in dictionary.values {
            if let nested = value as? [String: Any], let found = string(in: nested, keys: keys) { return found }
        }
        return nil
    }

    private static func meansStopped(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return [
            "no such file or directory", "connection refused", "failed to connect",
            "socket not found", "could not connect", "not running",
        ].contains { normalized.contains($0) }
    }

    private static func safeMessage(_ message: String, fallback: String) -> String {
        message.isEmpty ? fallback : String(message.prefix(500))
    }
}
