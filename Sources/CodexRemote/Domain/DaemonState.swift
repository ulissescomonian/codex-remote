import Foundation

public enum DaemonState: Equatable, Sendable {
    case stopped
    case running(cliVersion: String?, appServerVersion: String?)
    case unknown(String)
}
