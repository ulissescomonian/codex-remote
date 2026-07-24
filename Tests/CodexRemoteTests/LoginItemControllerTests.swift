import Foundation
import Testing
@testable import CodexRemote

@Suite("Login Item Controller")
@MainActor
struct LoginItemControllerTests {
    @Test("Missing preference defaults to enabled and registers the app")
    func missingPreferenceDefaultsToEnabledAndRegisters() {
        withIsolatedDefaults { defaults, key in
            let service = FakeLoginItemService(status: .notRegistered)
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.reconcileOnLaunch()

            #expect(controller.desiredEnabled)
            #expect(controller.status == .enabled)
            #expect(service.setEnabledCalls == [true])
            #expect(controller.errorMessage == nil)
        }
    }

    @Test("Missing app registration is retried when launch at login defaults on")
    func notFoundStatusRegistersWhenPreferenceDefaultsToEnabled() {
        withIsolatedDefaults { defaults, key in
            let service = FakeLoginItemService(status: .notFound)
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.reconcileOnLaunch()

            #expect(controller.desiredEnabled)
            #expect(controller.status == .enabled)
            #expect(service.setEnabledCalls == [true])
            #expect(controller.errorMessage == nil)
        }
    }

    @Test("Disabled preference unregisters once and is not reactivated")
    func disabledPreferenceUnregistersWithoutReactivation() {
        withIsolatedDefaults(initialValue: false) { defaults, key in
            let service = FakeLoginItemService(status: .enabled)
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.reconcileOnLaunch()
            controller.reconcileOnLaunch()

            #expect(!controller.desiredEnabled)
            #expect(controller.status == .notRegistered)
            #expect(service.setEnabledCalls == [false])
        }
    }

    @Test("Enabled preference and enabled login item require no operation")
    func enabledPreferenceAndServiceAreNoOp() {
        withIsolatedDefaults(initialValue: true) { defaults, key in
            let service = FakeLoginItemService(status: .enabled)
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.reconcileOnLaunch()

            #expect(controller.desiredEnabled)
            #expect(controller.status == .enabled)
            #expect(service.setEnabledCalls.isEmpty)
        }
    }

    @Test("Disabling persists only after unregister succeeds")
    func disablingPersistsOnlyAfterSuccess() {
        withIsolatedDefaults(initialValue: true) { defaults, key in
            let service = FakeLoginItemService(status: .enabled)
            service.beforeSetEnabled = { enabled in
                #expect(!enabled)
                #expect(defaults.bool(forKey: key))
            }
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.setDesiredEnabled(false)

            #expect(!controller.desiredEnabled)
            #expect(!defaults.bool(forKey: key))
            #expect(controller.status == .notRegistered)
            #expect(service.setEnabledCalls == [false])
        }
    }

    @Test("An operation error keeps the previous intent and exposes the error")
    func operationErrorKeepsIntentAndExposesError() {
        withIsolatedDefaults(initialValue: true) { defaults, key in
            let service = FakeLoginItemService(
                status: .enabled,
                error: FakeLoginItemError.operationFailed
            )
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.setDesiredEnabled(false)

            #expect(controller.desiredEnabled)
            #expect(defaults.bool(forKey: key))
            #expect(controller.status == .enabled)
            #expect(controller.errorMessage == FakeLoginItemError.operationFailed.localizedDescription)
            #expect(service.setEnabledCalls == [false])
        }
    }

    @Test("Approval-required status is preserved without repeated registration")
    func requiresApprovalDoesNotRepeatRegistration() {
        withIsolatedDefaults(initialValue: true) { defaults, key in
            let service = FakeLoginItemService(status: .requiresApproval)
            let controller = LoginItemController(
                service: service,
                userDefaults: defaults,
                preferenceKey: key
            )

            controller.reconcileOnLaunch()
            controller.reconcileOnLaunch()

            #expect(controller.desiredEnabled)
            #expect(controller.status == .requiresApproval)
            #expect(controller.requiresApproval)
            #expect(controller.errorMessage != nil)
            #expect(service.setEnabledCalls.isEmpty)
        }
    }
}

@MainActor
private func withIsolatedDefaults(
    initialValue: Bool? = nil,
    operation: (UserDefaults, String) -> Void
) {
    let suiteName = "CodexRemoteTests.LoginItemController.\(UUID().uuidString)"
    let key = "launchAtLogin"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    if let initialValue {
        defaults.set(initialValue, forKey: key)
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    operation(defaults, key)
}

private final class FakeLoginItemService: LoginItemServicing, @unchecked Sendable {
    private(set) var status: LoginItemStatus
    private(set) var setEnabledCalls: [Bool] = []
    var beforeSetEnabled: ((Bool) -> Void)?

    private let error: Error?

    init(status: LoginItemStatus, error: Error? = nil) {
        self.status = status
        self.error = error
    }

    func setEnabled(_ enabled: Bool) throws {
        setEnabledCalls.append(enabled)
        beforeSetEnabled?(enabled)
        if let error {
            throw error
        }
        status = enabled ? .enabled : .notRegistered
    }

    func openSystemSettings() {}
}

private enum FakeLoginItemError: LocalizedError {
    case operationFailed

    var errorDescription: String? {
        "O macOS recusou a alteração do item de início."
    }
}
