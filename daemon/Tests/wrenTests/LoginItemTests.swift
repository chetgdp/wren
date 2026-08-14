import Foundation
import XCTest
@testable import wren

final class LoginItemTests: XCTestCase {
    func testRefreshReadsExternalStatusChanges() {
        let service = TestLoginItemService(status: .notRegistered)
        let item = makeLoginItem(service: service)
        XCTAssertFalse(item.refresh().isEnabled)

        service.status = .enabled

        XCTAssertTrue(item.refresh().isEnabled)
    }

    func testRefreshMigratesLegacyAfterNativeIsEnabled() {
        let service = TestLoginItemService(status: .notRegistered)
        let legacy = LegacyLoginPlist()
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.refresh()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(legacy.removeCount, 1)
        XCTAssertFalse(legacy.exists)
        XCTAssertTrue(state.isEnabled)
        XCTAssertNil(state.error)
    }

    func testApprovalKeepsLegacyEnabledWithMigrationWarning() {
        let service = TestLoginItemService(status: .requiresApproval)
        let legacy = LegacyLoginPlist()
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.refresh()

        XCTAssertTrue(legacy.exists)
        XCTAssertEqual(legacy.removeCount, 0)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.error?.contains("remains active") == true)
        XCTAssertTrue(state.error?.contains("System Settings") == true)
    }

    func testRegistrationFailureKeepsLegacyEnabled() {
        let service = TestLoginItemService(status: .notRegistered)
        service.registerError = TestLoginError.register
        let legacy = LegacyLoginPlist()
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.refresh()

        XCTAssertTrue(legacy.exists)
        XCTAssertEqual(legacy.removeCount, 0)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.error?.contains("migration failed") == true)
    }

    func testRetirementFailureKeepsNativeEnabledAndWarns() {
        let service = TestLoginItemService(status: .notRegistered)
        let legacy = LegacyLoginPlist()
        legacy.removeError = TestLoginError.retire
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.refresh()

        XCTAssertEqual(service.status, .enabled)
        XCTAssertTrue(legacy.exists)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.error?.contains("remains active") == true)
    }

    func testTurningOffDisablesNativeThenLegacy() {
        let service = TestLoginItemService(status: .enabled)
        let legacy = LegacyLoginPlist()
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.setEnabled(false)

        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(legacy.exists)
        XCTAssertFalse(state.isEnabled)
        XCTAssertNil(state.error)
    }

    func testRegisterErrorWithoutLegacyIsVisible() {
        let service = TestLoginItemService(status: .notRegistered)
        service.registerError = TestLoginError.register
        let item = makeLoginItem(service: service)

        let state = item.setEnabled(true)

        XCTAssertFalse(state.isEnabled)
        XCTAssertTrue(state.error?.contains("register") == true)
    }

    func testUnregisterErrorKeepsEffectiveStateEnabled() {
        let service = TestLoginItemService(status: .enabled)
        service.unregisterError = TestLoginError.unregister
        let legacy = LegacyLoginPlist()
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.setEnabled(false)

        XCTAssertTrue(legacy.exists)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.error?.contains("unregister") == true)
    }

    func testRequiresApprovalWithoutLegacyIsActionable() {
        let service = TestLoginItemService(status: .requiresApproval)
        let state = makeLoginItem(service: service).refresh()

        XCTAssertTrue(state.isAvailable)
        XCTAssertFalse(state.isEnabled)
        XCTAssertTrue(state.error?.contains("System Settings") == true)
    }

    func testUnbundledAppIsUnavailable() {
        let item = makeLoginItem(service: nil)

        let state = item.setEnabled(true)

        XCTAssertFalse(state.isAvailable)
        XCTAssertFalse(state.isEnabled)
        XCTAssertNotNil(state.error)
    }

    func testNotFoundIsAvailableAndRegistrationCanEnableIt() {
        let service = TestLoginItemService(status: .notFound)
        let item = makeLoginItem(service: service)

        let initial = item.refresh()

        XCTAssertTrue(initial.isAvailable)
        XCTAssertFalse(initial.isEnabled)
        XCTAssertNil(initial.error)

        let enabled = item.setEnabled(true)

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(enabled.isAvailable)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertNil(enabled.error)
    }

    func testNotFoundRegistrationFailureKeepsLegacyEnabled() {
        let service = TestLoginItemService(status: .notFound)
        service.registerError = TestLoginError.register
        let legacy = LegacyLoginPlist()
        let item = makeLoginItem(service: service, legacy: legacy)

        let state = item.refresh()

        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(legacy.exists)
        XCTAssertTrue(state.isAvailable)
        XCTAssertTrue(state.isEnabled)
        XCTAssertTrue(state.error?.contains("migration failed") == true)
    }

    private func makeLoginItem(
        service: LoginItemService?,
        legacy: LegacyLoginPlist? = nil
    ) -> NativeLoginItem {
        NativeLoginItem(
            service: service,
            legacyPlistURL: URL(
                fileURLWithPath: "/tmp/legacy.plist"),
            legacyPlistExists: { _ in legacy?.exists == true },
            removeLegacyPlist: { _ in try legacy?.remove() })
    }
}

private enum TestLoginError: Error {
    case register
    case unregister
    case retire
}

private final class LegacyLoginPlist {
    var exists = true
    var removeError: Error?
    private(set) var removeCount = 0

    func remove() throws {
        removeCount += 1
        if let removeError { throw removeError }
        exists = false
    }
}

private final class TestLoginItemService: LoginItemService {
    var status: LoginItemServiceStatus
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    init(status: LoginItemServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}
