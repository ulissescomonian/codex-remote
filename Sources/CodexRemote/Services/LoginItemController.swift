import Combine
import Foundation

@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var desiredEnabled: Bool
    @Published public private(set) var status: LoginItemStatus
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isBusy = false

    public var requiresApproval: Bool {
        status == .requiresApproval
    }

    private let service: any LoginItemServicing
    private let userDefaults: UserDefaults
    private let preferenceKey: String

    public init(
        service: any LoginItemServicing = LoginItemService(),
        userDefaults: UserDefaults = .standard,
        preferenceKey: String = AppPreferenceKey.launchAtLogin
    ) {
        self.service = service
        self.userDefaults = userDefaults
        self.preferenceKey = preferenceKey
        desiredEnabled = userDefaults.object(forKey: preferenceKey) as? Bool
            ?? AppPreferenceDefault.launchAtLogin
        status = service.status
    }

    public func reconcileOnLaunch() {
        isBusy = true
        defer { isBusy = false }

        errorMessage = nil
        status = service.status

        do {
            if desiredEnabled {
                switch status {
                case .notRegistered, .notFound:
                    try service.setEnabled(true)
                case .enabled:
                    break
                case .requiresApproval:
                    errorMessage = Self.approvalMessage
                }
            } else if status == .enabled || status == .requiresApproval {
                try service.setEnabled(false)
            }

            status = service.status
            if status == .requiresApproval {
                errorMessage = Self.approvalMessage
            } else if status == .notFound {
                errorMessage = Self.notFoundMessage
            }
        } catch {
            status = service.status
            errorMessage = error.localizedDescription
        }
    }

    public func setDesiredEnabled(_ enabled: Bool) {
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil

        do {
            try service.setEnabled(enabled)
            desiredEnabled = enabled
            userDefaults.set(enabled, forKey: preferenceKey)
            status = service.status
            if status == .requiresApproval {
                errorMessage = Self.approvalMessage
            } else if status == .notFound {
                errorMessage = Self.notFoundMessage
            }
        } catch {
            status = service.status
            errorMessage = error.localizedDescription
        }
    }

    public func refresh() {
        status = service.status
        if status == .requiresApproval {
            errorMessage = Self.approvalMessage
        } else if status == .notFound {
            errorMessage = Self.notFoundMessage
        } else {
            errorMessage = nil
        }
    }

    public func openSystemSettings() {
        service.openSystemSettings()
    }

    private static let approvalMessage =
        "O macOS precisa da sua aprovação para abrir o Codex Remote ao iniciar a sessão."

    private static let notFoundMessage =
        "O macOS não encontrou o Codex Remote instalado para configurá-lo como item de início."
}
