import Foundation
import OSLog

public enum RemoteControlError: LocalizedError, Equatable, Sendable {
    case commandFailed(action: String, exitCode: Int32, message: String)
    case invalidPairingResponse

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let action, let exitCode, let message):
            let detail = message.isEmpty ? "codigo \(exitCode)" : message
            return "Nao foi possivel \(action) o Remote Control: \(detail)"
        case .invalidPairingResponse:
            return "O Codex nao retornou um codigo de pareamento valido."
        }
    }

    var isRemoteConnectionFailure: Bool {
        guard case .commandFailed(let action, _, let message) = self, action == "iniciar" else {
            return false
        }

        let normalizedMessage = message
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard normalizedMessage.contains("remote control is enabled on") else { return false }
        return normalizedMessage.contains("the connection is errored")
            || normalizedMessage.contains("the remote connection is errored")
    }
}

public actor RemoteControlService: RemoteControlServicing {
    private static let appServerNotReadyFriendlyMessage = "O servidor local do Codex não ficou pronto. A recuperação automática não foi concluída; clique em Reiniciar. Se persistir após uma atualização do Codex, feche e abra o Codex novamente."
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CodexRemote",
        category: "remote-control"
    )

    private let runner: any ProcessRunning
    private let locator: any CodexLocating
    private let probe: any DaemonStatusProbing
    private let staleUpdaterRecovery: any StaleUpdaterRecovering
    private let commandTimeout: TimeInterval

    public init() {
        let runner = ProcessRunner()
        self.runner = runner
        self.locator = CodexLocator()
        self.probe = DaemonStatusProbe(runner: runner)
        self.staleUpdaterRecovery = StaleUpdaterRecovery(runner: runner)
        self.commandTimeout = 15
    }

    public init(
        runner: any ProcessRunning,
        locator: any CodexLocating,
        probe: any DaemonStatusProbing,
        staleUpdaterRecovery: (any StaleUpdaterRecovering)? = nil,
        commandTimeout: TimeInterval = 15
    ) {
        self.runner = runner
        self.locator = locator
        self.probe = probe
        self.staleUpdaterRecovery = staleUpdaterRecovery ?? StaleUpdaterRecovery(runner: runner)
        self.commandTimeout = commandTimeout
    }

    public func status() async -> DaemonState {
        do {
            return await probe.status(codexURL: try locator.locate())
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    public func start() async throws -> DaemonState {
        if let state = try await startRecoveringStaleUpdaterOnce() {
            return state
        }
        return await status()
    }

    public func stop() async throws -> DaemonState {
        try await execute(action: "parar", subcommand: "stop")
        return await status()
    }

    public func restart() async throws -> DaemonState {
        try await execute(action: "parar", subcommand: "stop")
        if let state = try await startRecoveringStaleUpdaterOnce() {
            return state
        }
        return await status()
    }

    public func pair() async throws -> PairingCode {
        let codexURL = try locator.locate()
        let result = try await runner.run(
            executable: codexURL,
            arguments: ["remote-control", "pair", "--json"],
            environment: nil,
            timeout: commandTimeout
        )
        guard result.exitCode == 0 else {
            throw commandError(action: "parear", result: result)
        }
        // The raw pairing response deliberately has no lifetime beyond this stack frame.
        guard let pairing = Self.parsePairingCode(result.stdout) else {
            throw RemoteControlError.invalidPairingResponse
        }
        return pairing
    }

    private func startRecoveringStaleUpdaterOnce() async throws -> DaemonState? {
        let codexURL = try locator.locate()

        do {
            try await execute(action: "iniciar", subcommand: "start", codexURL: codexURL)
        } catch let originalTimeout as ProcessRunnerError {
            guard case .timedOut = originalTimeout else { throw originalTimeout }

            let state = await probe.status(codexURL: codexURL)
            if case .running = state {
                return state
            }

            do {
                try await staleUpdaterRecovery.recover(codexURL: codexURL)
            } catch {
                Self.logger.error(
                    "Automatic recovery after Start timeout failed: \(error.localizedDescription, privacy: .private)"
                )
                // Recovery diagnostics must not replace the original Start timeout.
                throw originalTimeout
            }

            try await execute(action: "iniciar", subcommand: "start", codexURL: codexURL)
        } catch let originalError as RemoteControlError {
            guard Self.isStaleUpdaterStartFailure(originalError) else { throw originalError }

            do {
                try await staleUpdaterRecovery.recover(codexURL: codexURL)
            } catch {
                Self.logger.error(
                    "Automatic recovery after app-server failure failed: \(error.localizedDescription, privacy: .private)"
                )
                // Recovery diagnostics must not replace the original, user-safe Start error.
                throw originalError
            }

            try await execute(action: "iniciar", subcommand: "start", codexURL: codexURL)
        }

        return nil
    }

    private func execute(action: String, subcommand: String, codexURL: URL? = nil) async throws {
        let result = try await runner.run(
            executable: try codexURL ?? locator.locate(),
            arguments: ["remote-control", subcommand, "--json"],
            environment: nil,
            timeout: commandTimeout
        )
        guard result.exitCode == 0 else { throw commandError(action: action, result: result) }
    }

    private static func isStaleUpdaterStartFailure(_ error: RemoteControlError) -> Bool {
        guard case .commandFailed(_, _, let message) = error else { return false }
        return isAppServerNotReadyMessage(message)
            || message == appServerNotReadyFriendlyMessage
    }

    private func commandError(action: String, result: ProcessResult) -> RemoteControlError {
        let message = Self.userSafeErrorMessage(
            for: action,
            stderr: result.stderrString
        )
        return .commandFailed(action: action, exitCode: result.exitCode, message: message)
    }

    /// Converts CLI stderr into a bounded, display-safe diagnostic. The app-server
    /// startup failure may include a second, stale log stream with ANSI codes,
    /// local paths and unrelated historical errors, so it intentionally gets a
    /// fixed actionable message instead of being surfaced verbatim.
    private static func userSafeErrorMessage(for action: String, stderr: String) -> String {
        let withoutANSI = stripANSI(from: stderr)
        let normalized = normalizeWhitespace(in: withoutANSI)

        if action == "iniciar", isAppServerNotReadyMessage(normalized) {
            return appServerNotReadyFriendlyMessage
        }

        let withoutSecrets = redactSecrets(in: normalized)
        let withoutPaths = redactAbsolutePaths(in: withoutSecrets)
        let bounded = String(withoutPaths.prefix(320))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return bounded.isEmpty ? "O Codex nao informou detalhes sobre a falha." : bounded
    }

    private static func isAppServerNotReadyMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("app server did not become ready")
            && normalized.contains("app-server-control.sock")
    }

    private static func stripANSI(from value: String) -> String {
        value.replacingOccurrences(
            of: "\u{001B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
    }

    private static func normalizeWhitespace(in value: String) -> String {
        value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func redactSecrets(in value: String) -> String {
        var result = value.replacingOccurrences(
            of: #"(?i)\b(token|secret|password|authorization|api[_-]?key)\s*([:=])\s*[^\s,;]+"#,
            with: "$1$2[redacted]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\bbearer\s+[^\s,;]+"#,
            with: "Bearer [redacted]",
            options: .regularExpression
        )
        return result
    }

    private static func redactAbsolutePaths(in value: String) -> String {
        value.replacingOccurrences(
            of: #"(?<!\S)/(?:[^\s,:;()\[\]{}])+"#,
            with: "[caminho local]",
            options: .regularExpression
        )
    }

    private static func parsePairingCode(_ data: Data) -> PairingCode? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else { return nil }

        let pairingCode = nonEmptyString(
            findString(in: dictionary, keys: ["pairingCode", "pairing_code"])
        )
        let manualCode = nonEmptyString(
            findString(
                in: dictionary,
                keys: ["manualPairingCode", "manual_pairing_code", "manualCode", "manual_code", "code"]
            )
        )
        let qrPayload = pairingCode.flatMap(makePairingURL)
        guard qrPayload != nil || manualCode != nil else { return nil }

        let expiresAt = parseExpiration(in: dictionary)
        return PairingCode(qrPayload: qrPayload, manualCode: manualCode, expiresAt: expiresAt)
    }

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func makePairingURL(for pairingCode: String) -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chatgpt.com"
        components.path = "/codex/pair"

        let queryItem = URLQueryItem(name: "pairing_code", value: pairingCode)
        components.queryItems = [queryItem]

        // URLComponents deliberately leaves some RFC 3986 query characters unescaped.
        // Pairing codes are opaque, so encode the entire value as a query component to
        // avoid form decoders treating characters such as `+` as data transformations.
        guard let encodedValue = pairingCode.addingPercentEncoding(withAllowedCharacters: strictQueryValueAllowed) else {
            return nil
        }
        components.percentEncodedQuery = "pairing_code=\(encodedValue)"
        return components.url?.absoluteString
    }

    private static let strictQueryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func findString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        for value in dictionary.values {
            if let nested = value as? [String: Any], let found = findString(in: nested, keys: keys) { return found }
        }
        return nil
    }

    private static func parseExpiration(in dictionary: [String: Any]) -> Date? {
        let absoluteKeys = ["expiresAt", "expires_at", "expiration", "expirationTime", "expiration_time"]
        for key in absoluteKeys {
            if let value = dictionary[key] as? String {
                if let date = ISO8601DateFormatter().date(from: value) { return date }
            } else if let value = dictionary[key] as? TimeInterval {
                return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
            }
        }
        let relativeKeys = ["expiresIn", "expires_in", "expiresInSeconds", "expires_in_seconds"]
        for key in relativeKeys {
            if let seconds = dictionary[key] as? TimeInterval { return Date().addingTimeInterval(seconds) }
        }
        for value in dictionary.values {
            if let nested = value as? [String: Any], let date = parseExpiration(in: nested) { return date }
        }
        return nil
    }
}
