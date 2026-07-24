import Foundation

public enum CodexLocatorError: LocalizedError, Equatable, Sendable {
    case notFound
    case invalidOverride(String)

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Codex CLI nao encontrado. Configure o caminho do executavel nas preferencias."
        case .invalidOverride(let path):
            return "O caminho configurado para o Codex nao e executavel: \(path)"
        }
    }
}

public protocol CodexLocating: Sendable {
    func locate() throws -> URL
}

public protocol ExecutableFileChecking: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

public struct LocalExecutableFileChecker: ExecutableFileChecking, Sendable {
    public init() {}

    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

public final class CodexLocator: CodexLocating, @unchecked Sendable {
    public static let overrideKey = "codexExecutablePath"

    private let defaults: UserDefaults
    private let fileChecker: any ExecutableFileChecking
    private let environment: [String: String]
    private let homeDirectory: URL

    public init(
        defaults: UserDefaults = .standard,
        fileChecker: any ExecutableFileChecking = LocalExecutableFileChecker(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.defaults = defaults
        self.fileChecker = fileChecker
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    public var overridePath: String? {
        get { defaults.string(forKey: Self.overrideKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: Self.overrideKey)
            } else {
                defaults.removeObject(forKey: Self.overrideKey)
            }
        }
    }

    public func locate() throws -> URL {
        if let overridePath, !overridePath.isEmpty {
            let expanded = NSString(string: overridePath).expandingTildeInPath
            guard isExecutable(expanded) else { throw CodexLocatorError.invalidOverride(overridePath) }
            return URL(fileURLWithPath: expanded)
        }

        for path in candidatePaths() where isExecutable(path) {
            return URL(fileURLWithPath: path)
        }
        throw CodexLocatorError.notFound
    }

    private func candidatePaths() -> [String] {
        let home = homeDirectory.path
        let known = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
        ]
        let fromPath = environment["PATH", default: ""]
            .split(separator: ":")
            .map { String($0) + "/codex" }
        return known + fromPath
    }

    private func isExecutable(_ path: String) -> Bool {
        fileChecker.isExecutableFile(atPath: path)
    }
}
