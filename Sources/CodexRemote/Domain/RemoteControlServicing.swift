import Foundation

public protocol RemoteControlServicing: Sendable {
    func status() async -> DaemonState
    func start() async throws -> DaemonState
    func stop() async throws -> DaemonState
    func restart() async throws -> DaemonState
    func pair() async throws -> PairingCode
}
