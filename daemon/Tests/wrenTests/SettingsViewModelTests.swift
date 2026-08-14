import XCTest
@testable import wren

final class SettingsViewModelTests: XCTestCase {
    func testProfilesPreserveStatusIssuesAndAuthoritativeActiveVoice() {
        let issue = VoiceIssue(
            code: "transcript_missing",
            field: "reference_text",
            message: "Add a UTF-8 transcript.")
        var fixture = SettingsStateFixture()
        fixture.profiles = [
            settingsProfile(
                id: "ready",
                name: "Ready Voice",
                status: .ready),
            settingsProfile(
                id: "incomplete",
                name: "Incomplete Voice",
                status: .incomplete,
                issues: [issue]),
            settingsProfile(
                id: "invalid",
                name: "Invalid Voice",
                status: .invalid,
                issues: [VoiceIssue(
                    code: "profile_invalid",
                    field: nil,
                    message: "Profile metadata is invalid.")])
        ]
        fixture.activeVoice = "ready"

        let model = SettingsViewModel(state: fixture.makeState())

        XCTAssertEqual(model.voiceLoadState, .loaded)
        XCTAssertEqual(model.voices.map(\.status), [
            .ready,
            .incomplete,
            .invalid
        ])
        XCTAssertTrue(model.voice(id: "ready")?.isActive == true)
        XCTAssertFalse(model.voice(id: "incomplete")?.isActive == true)
        XCTAssertEqual(
            model.voice(id: "incomplete")?.issues.first?.code,
            "transcript_missing")
        XCTAssertEqual(
            model.voice(id: "incomplete")?.issues.first?.title,
            "Reference Text: Add a UTF-8 transcript.")
        XCTAssertFalse(
            model.voice(id: "incomplete")?.canActivate == true)
        XCTAssertFalse(model.voice(id: "invalid")?.canActivate == true)
        XCTAssertFalse(model.voice(id: "ready")?.canDelete == true)
    }

    func testUnprovenLibraryKeepsReadyActivationButBlocksMutations() {
        var fixture = SettingsStateFixture()
        fixture.activeVoice = "first"
        fixture.provenLibrary = nil
        fixture.stagedImportAvailable = true
        fixture.profiles = [
            settingsProfile(
                id: "first",
                name: "First",
                status: .ready),
            settingsProfile(
                id: "second",
                name: "Second",
                status: .ready)
        ]

        let model = SettingsViewModel(state: fixture.makeState())

        XCTAssertFalse(model.canAddVoice)
        XCTAssertFalse(model.addVoiceVisible)
        XCTAssertTrue(model.voice(id: "second")?.canActivate == true)
        XCTAssertFalse(model.voice(id: "second")?.canRename == true)
        XCTAssertFalse(model.voice(id: "second")?.canDelete == true)
        XCTAssertTrue(
            model.libraryNotice?.contains("exact voice library") == true)
    }

    func testMissingStagedImportCapabilityBlocksLibraryMutations() {
        var fixture = SettingsStateFixture()
        fixture.activeVoice = "first"
        fixture.stagedImportAvailable = false
        fixture.profiles = [
            settingsProfile(id: "first", name: "First", status: .ready),
            settingsProfile(id: "second", name: "Second", status: .ready)
        ]

        let model = SettingsViewModel(state: fixture.makeState())

        XCTAssertFalse(model.addVoiceVisible)
        XCTAssertFalse(model.voice(id: "second")?.canRename == true)
        XCTAssertFalse(model.voice(id: "second")?.canDelete == true)
        XCTAssertTrue(model.voice(id: "second")?.canActivate == true)
    }

    func testPendingActionKeepsProvenImportVisibleButDisabled() {
        var fixture = SettingsStateFixture()
        fixture.pendingAction = .activateVoice(
            id: "c3po",
            requestID: "pending")

        let model = SettingsViewModel(state: fixture.makeState())

        XCTAssertTrue(model.addVoiceVisible)
        XCTAssertFalse(model.canAddVoice)
    }

    func testPendingActivationKeepsOldActiveAndMarksTarget() {
        var fixture = SettingsStateFixture()
        fixture.activeVoice = "old"
        fixture.profiles = [
            settingsProfile(id: "old", name: "Old", status: .ready),
            settingsProfile(id: "new", name: "New", status: .ready)
        ]
        fixture.pendingAction = .activateVoice(
            id: "new",
            requestID: "request")

        let model = SettingsViewModel(state: fixture.makeState())

        XCTAssertEqual(model.activeVoiceID, "old")
        XCTAssertEqual(model.pendingVoiceID, "new")
        XCTAssertTrue(model.voice(id: "old")?.isActive == true)
        XCTAssertEqual(model.voice(id: "new")?.pendingTitle, "Switching…")
        XCTAssertFalse(model.voice(id: "new")?.isActive == true)
        XCTAssertFalse(model.voice(id: "new")?.canActivate == true)
    }

    func testVoiceLoadingAndEmptyStatesAreDistinct() {
        var fixture = SettingsStateFixture()
        fixture.includeVoices = false
        XCTAssertEqual(
            SettingsViewModel(state: fixture.makeState()).voiceLoadState,
            .loading)

        fixture.includeVoices = true
        fixture.profiles = []
        XCTAssertEqual(
            SettingsViewModel(state: fixture.makeState()).voiceLoadState,
            .empty)
    }

    func testWAVSelectionAutofillsTranscriptAndSuggestions() {
        let wav = URL(fileURLWithPath: "/chosen/soft-robot.wav")
        let transcript = URL(fileURLWithPath: "/chosen/soft-robot.txt")
        var draft = SettingsVoiceImportDraft()

        draft.chooseWAV(wav) { $0 == transcript }

        XCTAssertEqual(draft.wavURL, wav)
        XCTAssertEqual(draft.transcriptURL, transcript)
        XCTAssertEqual(draft.displayName, "Soft Robot")
        XCTAssertEqual(draft.id, "soft-robot")
    }

    func testTranscriptSelectionAutofillsWAVAndPreservesEdits() {
        let transcript = URL(fileURLWithPath: "/chosen/voice.txt")
        let wav = URL(fileURLWithPath: "/chosen/voice.wav")
        var draft = SettingsVoiceImportDraft()
        draft.setDisplayName("My Edited Name")
        draft.setID("my_voice")

        draft.chooseTranscript(transcript) { $0 == wav }

        XCTAssertEqual(draft.wavURL, wav)
        XCTAssertEqual(draft.transcriptURL, transcript)
        XCTAssertEqual(draft.displayName, "My Edited Name")
        XCTAssertEqual(draft.id, "my_voice")
    }

    func testImportRejectsUnsafeAndCollidingIDsBeforeSubmission() {
        var draft = importDraft()
        draft.setID("Unsafe ID")
        XCTAssertTrue(
            draft.validate(
                existingIDs: [],
                importAvailable: true).message?
                .contains("lowercase") == true)

        draft.setID("existing")
        XCTAssertTrue(
            draft.validate(
                existingIDs: ["existing"],
                importAvailable: true).message?
                .contains("already exists") == true)

        XCTAssertTrue(
            draft.validate(
                existingIDs: [],
                importAvailable: false).message?
                .contains("proven access") == true)
    }

    func testValidImportProducesTypedSubmissionWithoutActivation() {
        var draft = importDraft()
        draft.setDisplayName("  Nova Voice  ")
        draft.setID("nova_voice")

        let submission = draft.validate(
            existingIDs: ["other"],
            importAvailable: true).submission

        XCTAssertEqual(submission?.displayName, "Nova Voice")
        XCTAssertEqual(submission?.id, "nova_voice")
        XCTAssertEqual(submission?.wav.path, "/chosen/nova.wav")
        XCTAssertEqual(submission?.transcript.path, "/chosen/nova.txt")
    }

    func testOutputKeepsDisconnectedIntentAndShowsEffectiveFallback() {
        var fixture = SettingsStateFixture()
        fixture.audioOutput = AudioOutputState(
            devices: [AudioOutputDevice(
                uid: "system",
                name: "MacBook Speakers")],
            desiredUID: "desk",
            desiredName: "Desk DAC",
            effectiveDevice: AudioOutputDevice(
                uid: "system",
                name: "MacBook Speakers"),
            fallbackWarning: "Desk DAC is disconnected; using default.",
            providerError: nil)

        let output = SettingsViewModel(
            state: fixture.makeState()).output

        XCTAssertEqual(output.desiredUID, "desk")
        XCTAssertEqual(output.desiredTitle, "Desk DAC (Disconnected)")
        XCTAssertEqual(output.effectiveTitle, "MacBook Speakers")
        XCTAssertEqual(output.options.last?.uid, "desk")
        XCTAssertFalse(output.options.last?.isConnected == true)
        XCTAssertNotNil(output.fallbackWarning)
    }

    func testDiagnosticsReportOnlyAuthoritativeDeploymentFacts() {
        let model = SettingsViewModel(
            state: SettingsStateFixture().makeState())
        let rows = Dictionary(
            uniqueKeysWithValues: model.diagnostics.rows.map {
                ($0.label, $0.value)
            })

        XCTAssertEqual(rows["Connection"], "Connected")
        XCTAssertEqual(rows["Ownership"], "Managed by Wren")
        XCTAssertEqual(rows["Endpoint"], "http://127.0.0.1:8765")
        XCTAssertEqual(rows["Protocol"], "2")
        XCTAssertEqual(rows["Backend"], "qwentts")
        XCTAssertEqual(rows["Model"], "Qwen3-TTS-0.6B")
        XCTAssertEqual(rows["Voices Directory"], "/tmp/voices")
        XCTAssertEqual(rows["Logs"], "/tmp/wren/wren.log")
    }

    func testRecoveryActionsRespectManagedAndConnectedOwnership() {
        let failure = DaemonManager.Failure(
            kind: .launch,
            message: "Wren could not start.",
            canRetry: true,
            canResetInvalidSettings: true)
        var fixture = SettingsStateFixture()
        fixture.managerPhase = .failed
        fixture.managerFailure = failure

        var recovery = SettingsViewModel(
            state: fixture.makeState()).recovery
        XCTAssertTrue(recovery.isVisible)
        XCTAssertTrue(recovery.canRetry)
        XCTAssertTrue(recovery.canResetInvalidSettings)
        XCTAssertEqual(recovery.revealLogURL?.path, "/tmp/wren/wren.log")

        fixture.ownership = .connected
        recovery = SettingsViewModel(
            state: fixture.makeState()).recovery
        XCTAssertTrue(recovery.isVisible)
        XCTAssertFalse(recovery.canRetry)
        XCTAssertFalse(recovery.canResetInvalidSettings)
        XCTAssertNil(recovery.revealLogURL)
    }

    func testOnlyStructuredSettingsFailureOffersReset() {
        var fixture = SettingsStateFixture()
        fixture.daemonError = ManagementErrorDetail(
            code: "legacy_config_invalid",
            message: "Legacy settings are invalid.",
            detail: nil,
            recoverable: true)

        var recovery = SettingsViewModel(
            state: fixture.makeState()).recovery
        XCTAssertTrue(recovery.canResetInvalidSettings)

        fixture.daemonError = ManagementErrorDetail(
            code: "port_conflict",
            message: "The port is in use.",
            detail: nil,
            recoverable: true)
        recovery = SettingsViewModel(
            state: fixture.makeState()).recovery

        XCTAssertFalse(recovery.canResetInvalidSettings)
    }

    func testHealthyStateHidesRecoveryControls() {
        let recovery = SettingsViewModel(
            state: SettingsStateFixture().makeState()).recovery

        XCTAssertFalse(recovery.isVisible)
        XCTAssertFalse(recovery.canRetry)
        XCTAssertFalse(recovery.canResetInvalidSettings)
        XCTAssertNil(recovery.revealLogURL)
    }

    private func importDraft() -> SettingsVoiceImportDraft {
        let wav = URL(fileURLWithPath: "/chosen/nova.wav")
        let transcript = URL(fileURLWithPath: "/chosen/nova.txt")
        var draft = SettingsVoiceImportDraft()
        draft.chooseWAV(wav) { _ in false }
        draft.chooseTranscript(transcript) { _ in false }
        return draft
    }
}
