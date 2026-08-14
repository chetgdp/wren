import AppKit
import XCTest
@testable import wren

final class WrenMenuModelTests: XCTestCase {
    func testNormalStateUsesDaemonVoiceAndReadyQuickPicker() {
        var fixture = SettingsStateFixture()
        fixture.activeVoice = "active"
        fixture.speakingRate = 1.5
        fixture.profiles = [
            settingsProfile(
                id: "active",
                name: "Active Voice",
                status: .ready),
            settingsProfile(
                id: "alternate",
                name: "Alternate Voice",
                status: .ready),
            settingsProfile(
                id: "incomplete",
                name: "Incomplete Voice",
                status: .incomplete)
        ]

        let model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Ready")
        XCTAssertEqual(model.activeVoiceName, "Active Voice")
        XCTAssertEqual(model.voices.map(\.id), ["active", "alternate"])
        XCTAssertTrue(model.voices[0].isChecked)
        XCTAssertFalse(model.voices[1].isChecked)
        XCTAssertTrue(model.addVoiceVisible)
        XCTAssertEqual(model.speakingRate, 1.5)
        XCTAssertNil(model.progress)
        XCTAssertFalse(model.pause.isEnabled)
        XCTAssertFalse(model.stop.isEnabled)
    }

    func testPlaybackStateEnablesPauseResumeAndStop() {
        var fixture = SettingsStateFixture()
        fixture.playback = PlaybackState(
            pending: 1,
            speaking: true,
            paused: false)

        var model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Speaking")
        XCTAssertEqual(model.pause.title, "Pause")
        XCTAssertTrue(model.pause.isEnabled)
        XCTAssertTrue(model.stop.isEnabled)

        fixture.playback.paused = true
        model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Paused")
        XCTAssertEqual(model.pause.title, "Resume")
        XCTAssertTrue(model.pause.isEnabled)
    }

    func testActivationKeepsActiveCheckmarkPendingAndFailed() {
        var fixture = SettingsStateFixture()
        fixture.activeVoice = "old"
        fixture.profiles = [
            settingsProfile(id: "old", name: "Old", status: .ready),
            settingsProfile(id: "new", name: "New", status: .ready)
        ]
        fixture.operation = OperationResponse(
            id: "operation",
            kind: "activate_voice",
            phase: .preparing,
            target: "new",
            progress: 0.4,
            error: nil,
            response: nil)

        var model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Switching to New")
        XCTAssertEqual(model.progress?.fraction, 0.4)
        XCTAssertTrue(choice("old", in: model)?.isChecked == true)
        XCTAssertFalse(choice("new", in: model)?.isChecked == true)
        XCTAssertTrue(model.voices.allSatisfy { !$0.isEnabled })

        fixture.operation?.phase = .failed
        fixture.operation?.error = ManagementErrorDetail(
            code: "voice_load_failed",
            message: "New could not be loaded.",
            detail: nil,
            recoverable: true)
        model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Couldn’t switch to New")
        XCTAssertTrue(model.status.detail.contains("Still using Old"))
        XCTAssertTrue(choice("old", in: model)?.isChecked == true)
        XCTAssertFalse(choice("new", in: model)?.isChecked == true)
    }

    func testProvisioningStateHasStableProgressPresentation() {
        var fixture = SettingsStateFixture()
        fixture.managerPhase = .provisioning(
            "Downloading voice resources 37%")

        let model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Preparing Wren")
        XCTAssertEqual(model.progress?.fraction, 0.37)
        XCTAssertEqual(model.statusBarBadge, "37%")
        XCTAssertFalse(model.pause.isEnabled)
        XCTAssertFalse(model.effectsEnabled)
    }

    func testConnectedStateNeverOffersOwnershipRecovery() {
        var fixture = SettingsStateFixture()
        fixture.ownership = .connected
        fixture.provenLibrary = nil
        fixture.stagedImportAvailable = false

        var model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Connected")
        XCTAssertFalse(model.addVoiceVisible)
        XCTAssertTrue(model.recoveryActions.isEmpty)

        fixture.managerPhase = .failed
        fixture.managerFailure = DaemonManager.Failure(
            kind: .transport,
            message: "Connection failed.",
            canRetry: true,
            canResetInvalidSettings: true)
        model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Connection Lost")
        XCTAssertTrue(model.recoveryActions.isEmpty)
    }

    func testActionableFailureStaysVisibleWithCurrentVoice() {
        var fixture = SettingsStateFixture()
        fixture.actionableError = ActionableError(
            code: "settings_persist_failed",
            message: "Settings could not be saved.",
            detail: nil,
            recoverable: true)

        let model = WrenMenuModel(state: fixture.makeState())

        XCTAssertEqual(model.status.title, "Action Didn’t Complete")
        XCTAssertEqual(model.status.tone, .error)
        XCTAssertTrue(model.status.detail.contains(
            "Settings could not be saved."))
        XCTAssertTrue(model.status.detail.contains("Still using C-3PO"))
    }

    private func choice(
        _ id: String,
        in model: WrenMenuModel
    ) -> WrenMenuModel.VoiceChoice? {
        model.voices.first { $0.id == id }
    }
}

@MainActor
final class WrenMenuBarLayoutTests: XCTestCase {
    func testRebuildKeepsOneRateRowAndPersistentRowIdentity() {
        _ = NSApplication.shared
        var fixture = SettingsStateFixture()
        fixture.provenLibrary = nil
        fixture.stagedImportAvailable = false
        let menuBar = WrenMenuBar()
        menuBar.render(fixture.makeState())
        menuBar.rebuild()
        let initialIDs = menuBar.persistentRowIDs

        XCTAssertEqual(rateRowCount(in: menuBar.menu), 1)
        XCTAssertFalse(voiceTitles(in: menuBar.menu).contains(
            "Add Voice…"))

        fixture.managerPhase = .provisioning("Downloading 50%")
        menuBar.render(fixture.makeState())
        menuBar.rebuild()

        XCTAssertEqual(menuBar.persistentRowIDs, initialIDs)
        XCTAssertEqual(rateRowCount(in: menuBar.menu), 1)
    }

    func testMenuOpenEmitsTypedRefresh() {
        _ = NSApplication.shared
        let menuBar = WrenMenuBar()
        var actions: [WrenMenuBar.Action] = []
        menuBar.onAction = { actions.append($0) }

        menuBar.menuWillOpen(menuBar.menu)

        XCTAssertEqual(actions, [.refresh])
    }

    private func rateRowCount(in menu: NSMenu) -> Int {
        menu.items.filter { $0.view is SliderMenuView }.count
    }

    private func voiceTitles(in menu: NSMenu) -> [String] {
        menu.items.first { $0.title == "Voice" }?
            .submenu?.items.map(\.title) ?? []
    }
}
