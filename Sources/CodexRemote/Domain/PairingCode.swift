import Foundation

public struct PairingCode: Equatable, Sendable {
    public let qrPayload: String?
    public let manualCode: String?
    public let expiresAt: Date?

    public init(qrPayload: String? = nil, manualCode: String?, expiresAt: Date?) {
        self.qrPayload = qrPayload
        self.manualCode = manualCode
        self.expiresAt = expiresAt
    }
}
