import AppKit
import CoreAudio
import Foundation
import XCTest
@testable import wren

@MainActor
final class WrenStoreReducerTests: XCTestCase {
    func testStaleResponsesCannotCrossIndependentRevisionGates() {
        let fixture = makeFixture(startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 10, voice: "old"),
            instanceID: "one")
        fixture.store.acceptVoices(
            makeVoices(revision: 80, ids: ["old"]),
            instanceID: "one")

        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 9, voice: "stale"),
            instanceID: "one")
        fixture.store.acceptVoices(
            makeVoices(revision: 79, ids: ["stale"]),
            instanceID: "one")
        XCTAssertEqual(fixture.store.state.daemon?.revision, 10)
        XCTAssertEqual(fixture.store.state.daemon?.synthesis.activeVoice, "old")
        XCTAssertEqual(fixture.store.state.voices?.revision, 80)

        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 11, voice: "new"),
            instanceID: "one")
        fixture.store.acceptVoices(
            makeVoices(revision: 81, ids: ["old", "new"]),
            instanceID: "one")
        XCTAssertEqual(fixture.store.state.daemon?.revision, 11)
        XCTAssertEqual(fixture.store.state.voices?.revision, 81)
    }

    func testStateVoicePointerRejectsAnOlderVoiceDomain() {
        let fixture = makeFixture(startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        fixture.store.acceptVoices(
            makeVoices(revision: 8, ids: ["old"]),
            instanceID: "one")
        var state = makeDaemonState(revision: 20, voice: "new")
        state.voicesRevision = 9

        fixture.store.acceptDaemonState(state, instanceID: "one")
        XCTAssertNil(fixture.store.state.voices)

        fixture.store.acceptVoices(
            makeVoices(revision: 8, ids: ["old"]),
            instanceID: "one")
        XCTAssertNil(fixture.store.state.voices)

        fixture.store.acceptVoices(
            makeVoices(revision: 9, ids: ["old", "new"]),
            instanceID: "one")
        XCTAssertEqual(fixture.store.state.voices?.revision, 9)
        XCTAssertEqual(
            fixture.store.state.voices?.voices.map(\.id),
            ["old", "new"])
    }

    func testRefreshReloadsVoicesBehindStatePointer() async {
        let client = TestStoreClient()
        client.daemonSnapshot = makeDaemonState(
            revision: 20,
            voice: "new")
        client.daemonSnapshot.voicesRevision = 9
        client.voiceSnapshots = [
            makeVoices(revision: 8, ids: ["old"]),
            makeVoices(revision: 9, ids: ["old", "new"]),
        ]
        let fixture = makeFixture(
            client: client,
            startsSession: false)

        await fixture.store.refresh()

        XCTAssertEqual(client.voicesCalls, 2)
        XCTAssertEqual(fixture.store.state.voices?.revision, 9)
        XCTAssertEqual(
            fixture.store.state.voices?.voices.map(\.id),
            ["old", "new"])
    }

    func testInstanceChangeClearsBothDomainsBeforeRevisionOne() {
        let fixture = makeFixture(startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "old-instance"))
        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 40, voice: "old"),
            instanceID: "old-instance")
        fixture.store.acceptVoices(
            makeVoices(revision: 20, ids: ["old"]),
            instanceID: "old-instance")

        fixture.store.acceptMeta(makeMeta(instance: "new-instance"))
        XCTAssertNil(fixture.store.state.daemon)
        XCTAssertNil(fixture.store.state.voices)
        XCTAssertNil(fixture.store.state.pendingAction)

        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 1, voice: "new"),
            instanceID: "new-instance")
        fixture.store.acceptVoices(
            makeVoices(revision: 1, ids: ["new"]),
            instanceID: "new-instance")
        XCTAssertEqual(fixture.store.state.daemon?.revision, 1)
        XCTAssertEqual(fixture.store.state.voices?.revision, 1)
    }

    func testEqualRevisionUpdatesOnlyPlaybackAndLocalPause() {
        let fixture = makeFixture(startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 10, voice: "durable"),
            instanceID: "one")
        var equal = makeDaemonState(revision: 10, voice: "regressed")
        equal.synthesis.effects = true
        equal.playback = PlaybackState(
            pending: 2,
            speaking: true,
            paused: true)

        fixture.store.acceptDaemonState(equal, instanceID: "one")

        XCTAssertEqual(
            fixture.store.state.daemon?.synthesis.activeVoice,
            "durable")
        XCTAssertEqual(fixture.store.state.daemon?.synthesis.effects, false)
        XCTAssertEqual(fixture.store.state.daemon?.playback, equal.playback)
        XCTAssertTrue(fixture.store.state.localPlayer.isPaused)
        XCTAssertEqual(fixture.player.pausedValues.last, true)
    }

    func testPendingActivationKeepsAuthoritativeActiveVoice() async {
        let client = TestStoreClient()
        client.suspendActivation = true
        let submitted = expectation(description: "activation submitted")
        client.activationSubmitted = submitted
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 2, voice: "old"),
            instanceID: "one")

        let action = Task {
            await fixture.store.activateVoice(id: "new")
        }
        await fulfillment(of: [submitted], timeout: 1)
        XCTAssertEqual(
            fixture.store.state.daemon?.synthesis.activeVoice,
            "old")
        guard case .activateVoice(let id, _) =
            fixture.store.state.pendingAction
        else {
            return XCTFail("activation should remain pending")
        }
        XCTAssertEqual(id, "new")
        XCTAssertEqual(
            fixture.store.state.voiceManagement.activeID,
            "old")
        guard case .activate(let pendingID, _) =
            fixture.store.state.voiceManagement.pendingMutation
        else {
            return XCTFail("derived activation should remain pending")
        }
        XCTAssertEqual(pendingID, "new")

        client.resumeActivation(makeOperation(id: client.lastRequestID))
        await action.value
        XCTAssertEqual(
            fixture.store.state.daemon?.synthesis.activeVoice,
            "old")
        XCTAssertNil(fixture.store.state.pendingAction)
        XCTAssertEqual(
            fixture.store.state.voiceManagement.activeID,
            "old")
        XCTAssertNil(
            fixture.store.state.voiceManagement.pendingMutation)
    }

    func testConflictingMutationIsSerializedAndVisible() async {
        let client = TestStoreClient()
        client.suspendActivation = true
        let submitted = expectation(description: "activation submitted")
        client.activationSubmitted = submitted
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))

        let action = Task {
            await fixture.store.activateVoice(id: "new")
        }
        await fulfillment(of: [submitted], timeout: 1)
        await fixture.store.setEffects(true)
        XCTAssertEqual(client.settingsCalls, 0)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "action_in_progress")

        client.resumeActivation(makeOperation(id: client.lastRequestID))
        await action.value
    }
    func testUnknownLookupRetriesIdenticalActivation() async {
        let client = TestStoreClient()
        client.simulatesUnknownRecovery = true
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))

        await fixture.store.activateVoice(id: "new")

        XCTAssertEqual(client.activationRequestIDs.count, 2)
        XCTAssertEqual(
            Set(client.activationRequestIDs).count,
            1)
        XCTAssertEqual(client.activationVoices, ["new", "new"])
        XCTAssertEqual(client.operationCalls, 1)
        XCTAssertNil(fixture.store.state.actionableError)
    }

    func testManagerBackgroundRefreshRevalidatesRestartedDaemon()
        async {
        let client = TestStoreClient()
        client.metadata = makeMeta(instance: "new")
        client.daemonSnapshot = makeDaemonState(
            revision: 1,
            voice: "new")
        client.voiceSnapshot = makeVoices(revision: 1, ids: ["new"])
        let requested = expectation(description: "background meta")
        client.metaCalled = requested
        let manager = TestStoreManager(
            endpoint: testEndpoint,
            ownership: .managed,
            meta: makeMeta(instance: "old"))
        let player = TestStorePlayer()
        let store = WrenStore(
            endpoint: testEndpoint,
            sessionFactory: SingleSessionFactory(session: WrenSession(
                endpoint: testEndpoint,
                manager: manager,
                client: client,
                player: player)),
            startsRefreshTimer: false)

        await fulfillment(of: [requested], timeout: 1)
        for _ in 0..<100
            where store.state.daemon == nil || store.state.voices == nil {
            await Task.yield()
        }

        XCTAssertEqual(store.state.meta?.instanceID, "new")
        XCTAssertEqual(store.state.daemon?.synthesis.activeVoice, "new")
        XCTAssertEqual(store.state.voices?.voices.map(\.id), ["new"])
    }

    func testConcurrentMetaResponsesUseNewestRefreshGeneration()
        async {
        let client = TestStoreClient()
        let firstRequested = expectation(description: "first meta")
        let secondRequested = expectation(description: "second meta")
        let responses = ControlledMetaResponses(
            expectations: [firstRequested, secondRequested])
        client.controlledMeta = responses
        client.daemonSnapshot = makeDaemonState(
            revision: 1,
            voice: "new")
        client.voiceSnapshot = makeVoices(revision: 1, ids: ["new"])
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "old"))

        let first = Task { await fixture.store.refresh() }
        await fulfillment(of: [firstRequested], timeout: 1)
        let second = Task { await fixture.store.refresh() }
        await fulfillment(of: [secondRequested], timeout: 1)
        responses.resume(at: 1, with: makeMeta(instance: "new"))
        await second.value
        responses.resume(at: 0, with: makeMeta(instance: "old"))
        await first.value

        XCTAssertEqual(fixture.store.state.meta?.instanceID, "new")
        XCTAssertEqual(
            fixture.store.state.daemon?.synthesis.activeVoice,
            "new")
        XCTAssertNil(fixture.store.state.pendingAction)
    }
    func testImportPreparationAwaitsSupersedingRefresh() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let sources = try makeVoiceSources(in: library)
        let client = TestStoreClient()
        let firstMeta = expectation(description: "startup meta")
        let secondMeta = expectation(description: "preparation meta")
        let winningMeta = expectation(description: "winning meta")
        let responses = ControlledMetaResponses(
            expectations: [firstMeta, secondMeta, winningMeta])
        client.controlledMeta = responses
        client.voiceSnapshot = makeVoices(revision: 2, ids: ["taken"])
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await fulfillment(of: [firstMeta], timeout: 1)

        let importTask = Task {
            await fixture.store.importVoice(
                wav: sources.wav,
                transcript: sources.transcript,
                name: "Taken",
                id: "taken")
        }
        await fulfillment(of: [secondMeta], timeout: 1)
        let refreshTask = Task {
            await fixture.store.refresh()
        }
        await fulfillment(of: [winningMeta], timeout: 1)

        responses.resume(at: 2, with: makeMeta(instance: "one"))
        await refreshTask.value
        client.controlledMeta = nil
        responses.resume(at: 1, with: makeMeta(instance: "one"))
        responses.resume(at: 0, with: makeMeta(instance: "one"))
        await importTask.value

        XCTAssertTrue(client.importRequests.isEmpty)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_id_collision")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: library.appendingPathComponent(".staging").path))
    }


    func testAmbiguousPriorInstanceKeyIsNeverLookedUpOrRetried()
        async {
        let client = TestStoreClient()
        client.simulatesUnknownRecovery = true
        client.metadata = makeMeta(instance: "new")
        client.daemonSnapshot = makeDaemonState(
            revision: 1,
            voice: "new")
        client.voiceSnapshot = makeVoices(revision: 1, ids: ["new"])
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "old"))

        await fixture.store.activateVoice(id: "requested")

        XCTAssertEqual(client.activationRequestIDs.count, 1)
        XCTAssertEqual(client.operationCalls, 0)
        XCTAssertEqual(fixture.store.state.meta?.instanceID, "new")
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "daemon_instance_changed")
        XCTAssertNil(fixture.store.state.pendingAction)
    }

    func testRecoveryClearsOnlyItsMatchingTransientError() async {
        let client = TestStoreClient()
        client.metaError = DaemonError.transport(description: "offline")
        let fixture = makeFixture(client: client, startsSession: false)

        await fixture.store.refresh()
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "transport_failure")

        client.metaError = nil
        await fixture.store.refresh()
        XCTAssertNil(fixture.store.state.actionableError)

        client.settingsError = DaemonError.management(
            status: 422,
            error: ManagementErrorDetail(
                code: "settings_persist_failed",
                message: "Settings could not be saved.",
                detail: .string("disk full"),
                recoverable: true))
        await fixture.store.setEffects(true)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "settings_persist_failed")

        client.settingsError = nil
        await fixture.store.refresh()
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "settings_persist_failed")
    }

    func testPauseRetryUsesRequestedBooleanFromController() async {
        let client = TestStoreClient()
        client.pauseError = DaemonError.transport(
            description: "pause timed out")
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        await fixture.store.setPaused(true)
        XCTAssertTrue(fixture.store.state.localPlayer.isPaused)

        client.pauseError = nil
        let resumed = expectation(description: "resume requested")
        client.resumeCalled = resumed
        let menu = TestStoreMenu()
        let controller = AppController(
            store: fixture.store,
            menuBar: menu,
            notificationCenter: NotificationCenter())
        menu.onAction?(.setPaused(false))
        await fulfillment(of: [resumed], timeout: 1)

        XCTAssertEqual(client.pauseCalls, 1)
        XCTAssertEqual(client.resumeCalls, 1)
        XCTAssertEqual(fixture.player.pausedValues.last, false)
        XCTAssertFalse(fixture.store.state.localPlayer.isPaused)
        withExtendedLifetime(controller) {}
    }

    func testStaleStopCompletionCannotClearNewPauseOwner() async {
        let client = TestStoreClient()
        client.suspendStop = true
        let stopSubmitted = expectation(description: "stop submitted")
        client.stopCalled = stopSubmitted
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "old"))
        let stop = Task { await fixture.store.stopSpeaking() }
        await fulfillment(of: [stopSubmitted], timeout: 1)

        client.metadata = makeMeta(instance: "new")
        fixture.store.acceptMeta(makeMeta(instance: "new"))
        client.suspendPause = true
        let pauseSubmitted = expectation(description: "pause submitted")
        client.pauseCalled = pauseSubmitted
        let pause = Task { await fixture.store.setPaused(true) }
        await fulfillment(of: [pauseSubmitted], timeout: 1)

        client.resumeStop()
        await stop.value
        guard case .setPaused(let desired) =
            fixture.store.state.pendingAction
        else {
            return XCTFail("new pause owner must remain pending")
        }
        XCTAssertTrue(desired)

        client.resumePause(paused: true)
        await pause.value
        XCTAssertNil(fixture.store.state.pendingAction)
    }

    func testV2SettingsErrorEnablesOwnedReset() async {
        let fixture = makeFixture(startsSession: true)
        await Task.yield()
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        var invalid = makeDaemonState(revision: 2, voice: "old")
        invalid.lastError = ManagementErrorDetail(
            code: "settings_invalid",
            message: "Settings are invalid.",
            detail: .object(["field": .string("effects")]),
            recoverable: true)
        fixture.store.acceptDaemonState(invalid, instanceID: "one")

        XCTAssertTrue(
            fixture.store.state.managerRecovery
                .canResetInvalidSettings)
        fixture.store.resetInvalidSettings()
        XCTAssertEqual(fixture.manager.resetInvalidSettingsCount, 1)
        guard case .resetInvalidSettings =
            fixture.store.state.pendingAction
        else {
            return XCTFail("reset should remain manager-owned")
        }
    }

    func testManagedDegradedDaemonRetryRestartsOwnedProcess() async {
        let fixture = makeFixture(startsSession: true)
        await Task.yield()
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        var degraded = makeDaemonState(revision: 2, voice: "old")
        degraded.lifecycle = DaemonLifecycle(
            phase: .degraded,
            message: "Engine exited.")
        fixture.store.acceptDaemonState(degraded, instanceID: "one")

        XCTAssertTrue(fixture.store.state.managerRecovery.canRetry)
        fixture.store.retryStartup()

        XCTAssertEqual(fixture.manager.restartCount, 1)
        XCTAssertEqual(fixture.manager.retryCount, 0)
    }

    func testGenericDaemonErrorDoesNotEnableConfigurationReset() async {
        let fixture = makeFixture(startsSession: true)
        await Task.yield()
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        var failed = makeDaemonState(revision: 2, voice: "old")
        failed.lastError = ManagementErrorDetail(
            code: "settings_persist_failed",
            message: "Disk is full.",
            detail: nil,
            recoverable: true)
        fixture.store.acceptDaemonState(failed, instanceID: "one")

        XCTAssertFalse(
            fixture.store.state.managerRecovery
                .canResetInvalidSettings)
    }


    func testLocalRateIsImmediateAndPersisted() throws {
        let suite = "WrenStoreRate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = makeFixture(
            startsSession: false,
            userDefaults: defaults)

        fixture.store.setSpeakingRate(2.25)

        XCTAssertEqual(fixture.store.state.localPlayer.speakingRate, 2.25)
        XCTAssertEqual(fixture.player.rates.last, 2.25)
        XCTAssertEqual(defaults.double(forKey: "playerRate"), 2.25)
    }

    func testEndpointRelaunchReplacesWholeManagedSession() async {
        let firstEndpoint = URL(string: "http://127.0.0.1:8765")!
        let secondEndpoint = URL(string: "http://127.0.0.1:9876")!
        let factory = RecordingSessionFactory(
            ownership: .managed,
            meta: makeMeta(instance: "one"))
        let store = WrenStore(
            endpoint: firstEndpoint,
            sessionFactory: factory,
            startsRefreshTimer: false)
        await Task.yield()
        XCTAssertTrue(store.state.stagedImportAvailable)
        let first = factory.sessions[0]

        store.relaunch(at: secondEndpoint)
        await Task.yield()

        XCTAssertEqual(factory.sessions.count, 2)
        let second = factory.sessions[1]
        XCTAssertFalse(first.manager === second.manager)
        XCTAssertFalse(first.client === second.client)
        XCTAssertFalse(first.player === second.player)
        XCTAssertEqual(first.manager.shutdownCount, 1)
        XCTAssertEqual(first.player.stopCount, 1)
        XCTAssertEqual(second.manager.startCount, 1)
        XCTAssertEqual(second.player.startCount, 1)
        XCTAssertEqual(store.state.endpoint, secondEndpoint)
    }

    func testConnectedSessionIsNeverSentAProcessShutdown() async {
        let firstEndpoint = URL(string: "http://127.0.0.1:8765")!
        let secondEndpoint = URL(string: "http://127.0.0.1:9876")!
        let factory = RecordingSessionFactory(
            ownership: .connected,
            meta: makeMeta(instance: "one"))
        let store = WrenStore(
            endpoint: firstEndpoint,
            sessionFactory: factory,
            startsRefreshTimer: false)
        await Task.yield()
        XCTAssertFalse(store.state.stagedImportAvailable)
        let connected = factory.sessions[0].manager

        store.shutdown()
        store.relaunch(at: secondEndpoint)
        await Task.yield()

        XCTAssertEqual(connected.shutdownCount, 0)
    }

    func testStructuredMutationFailureIsVisible() async {
        let client = TestStoreClient()
        client.settingsError = DaemonError.management(
            status: 422,
            error: ManagementErrorDetail(
                code: "settings_persist_failed",
                message: "Settings could not be saved.",
                detail: .string("disk full"),
                recoverable: true))
        let fixture = makeFixture(client: client, startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))

        await fixture.store.setEffects(true)

        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "settings_persist_failed")
        XCTAssertEqual(
            fixture.store.state.actionableError?.message,
            "Settings could not be saved.")
    }

    func testVoiceManagementKeepsAllIssuesButOnlyReadyActivation() {
        let fixture = makeFixture(startsSession: false)
        fixture.store.acceptMeta(makeMeta(instance: "one"))
        fixture.store.acceptDaemonState(
            makeDaemonState(revision: 2, voice: "ready"),
            instanceID: "one")
        let missing = VoiceIssue(
            code: "transcript_missing",
            field: "transcript",
            message: "Transcript required.")
        let malformed = VoiceIssue(
            code: "profile_invalid",
            field: "profile",
            message: "Profile is invalid.")
        fixture.store.acceptVoices(
            VoiceListResponse(
                revision: 2,
                voices: [
                    VoiceProfile(
                        id: "ready",
                        displayName: "Ready",
                        status: .ready,
                        issues: []),
                    VoiceProfile(
                        id: "incomplete",
                        displayName: "Incomplete",
                        status: .incomplete,
                        issues: [missing]),
                    VoiceProfile(
                        id: "invalid",
                        displayName: "Invalid",
                        status: .invalid,
                        issues: [malformed]),
                ]),
            instanceID: "one")

        let management = fixture.store.state.voiceManagement
        XCTAssertEqual(management.profiles.map(\.id), [
            "ready", "incomplete", "invalid",
        ])
        XCTAssertEqual(management.readyProfiles.map(\.id), ["ready"])
        XCTAssertEqual(
            management.incompleteProfiles.map(\.id),
            ["incomplete"])
        XCTAssertEqual(management.invalidProfiles.map(\.id), ["invalid"])
        XCTAssertEqual(management.activeID, "ready")
        XCTAssertEqual(
            management.profileProblems.map(\.issue.code),
            ["transcript_missing", "profile_invalid"])
    }

    func testManagedAndConnectedSharedLibraryProof() throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let managed = TestStoreManager(
            endpoint: testEndpoint,
            ownership: .managed,
            meta: makeMeta(instance: "managed"),
            library: library).managerState
        XCTAssertEqual(
            SharedVoiceLibrary.prove(
                endpoint: testEndpoint,
                manager: managed,
                daemon: nil,
                configuredLibrary: nil),
            SharedVoiceLibrary.canonical(library))

        let connected = TestStoreManager(
            endpoint: testEndpoint,
            ownership: .connected,
            meta: makeMeta(instance: "connected")).managerState
        let report = makeDaemonState(
            revision: 1,
            voice: "old",
            voicesDirectory: library.path)
        XCTAssertEqual(
            SharedVoiceLibrary.prove(
                endpoint: testEndpoint,
                manager: connected,
                daemon: report,
                configuredLibrary: library),
            SharedVoiceLibrary.canonical(library))
    }

    func testConnectedProofRejectsEveryMissingExactCondition() throws {
        let library = try makeVoiceTestDirectory()
        let other = try makeVoiceTestDirectory()
        let alias = FileManager.default.temporaryDirectory
            .appendingPathComponent("wren-voice-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: other)
        defer {
            try? FileManager.default.removeItem(at: library)
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: alias)
        }
        let connected = TestStoreManager(
            endpoint: testEndpoint,
            ownership: .connected,
            meta: makeMeta(instance: "connected")).managerState
        let matching = makeDaemonState(
            revision: 1,
            voice: "old",
            voicesDirectory: library.path)
        let missing = library.appendingPathComponent("missing")
        let inaccessible = makeDaemonState(
            revision: 1,
            voice: "old",
            voicesDirectory: missing.path)
        let relative = makeDaemonState(
            revision: 1,
            voice: "old",
            voicesDirectory: "voices")
        let symlinkMismatch = makeDaemonState(
            revision: 1,
            voice: "old",
            voicesDirectory: alias.path)

        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: URL(string: "http://192.168.1.3:8765")!,
            manager: connected,
            daemon: matching,
            configuredLibrary: library))
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: connected,
            daemon: makeDaemonState(revision: 1, voice: "old"),
            configuredLibrary: library))
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: connected,
            daemon: matching,
            configuredLibrary: nil))
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: connected,
            daemon: matching,
            configuredLibrary: other))
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: connected,
            daemon: symlinkMismatch,
            configuredLibrary: library))
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: connected,
            daemon: inaccessible,
            configuredLibrary: missing))
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: connected,
            daemon: relative,
            configuredLibrary: library))
        let managedMissing = TestStoreManager(
            endpoint: testEndpoint,
            ownership: .managed,
            meta: makeMeta(instance: "managed-missing"),
            library: missing).managerState
        XCTAssertNil(SharedVoiceLibrary.prove(
            endpoint: testEndpoint,
            manager: managedMissing,
            daemon: nil,
            configuredLibrary: nil))
    }
    func testConnectedStoreReconcilesOnlyAnAccessibleExactPath()
        async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let client = TestStoreClient()
        client.daemonSnapshot = makeDaemonState(
            revision: 2,
            voice: "old",
            voicesDirectory: library.path)
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            ownership: .connected,
            configuredLibrary: library)
        await settleStore(fixture.store)
        XCTAssertEqual(
            fixture.store.state.provenLocalLibrary,
            SharedVoiceLibrary.canonical(library))

        try FileManager.default.removeItem(at: library)
        fixture.store.reconcileSharedLibraryProof()
        XCTAssertNil(fixture.store.state.provenLocalLibrary)
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true)
        fixture.store.reconcileSharedLibraryProof()
        XCTAssertEqual(
            fixture.store.state.provenLocalLibrary,
            SharedVoiceLibrary.canonical(library))
    }


    func testCapabilityWithoutExactProofNeverEnablesMutations() async {
        let library = FileManager.default.temporaryDirectory
        let fixture = makeFixture(
            startsSession: true,
            ownership: .connected,
            configuredLibrary: library)
        await settleStore(fixture.store, requiringProof: false)

        XCTAssertNil(fixture.store.state.provenLocalLibrary)
        XCTAssertFalse(fixture.store.state.stagedImportAvailable)
        XCTAssertFalse(
            fixture.store.state.voiceManagement.mutationsAvailable)
        await fixture.store.renameVoice(id: "old", name: "Renamed")
        XCTAssertTrue(fixture.client.renameRequests.isEmpty)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_library_mutation_unavailable")
    }

    func testExactProofWithoutCapabilityNeverEnablesMutations()
        async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let fixture = makeFixture(
            startsSession: true,
            library: library)
        await settleStore(fixture.store)
        var meta = makeMeta(instance: "one")
        meta.capabilities.removeAll { $0 == .stagedImport }
        fixture.client.metadata = meta

        fixture.store.acceptMeta(meta)

        XCTAssertNotNil(fixture.store.state.provenLocalLibrary)
        XCTAssertFalse(fixture.store.state.stagedImportAvailable)
        await fixture.store.renameVoice(id: "old", name: "Renamed")
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_library_mutation_unavailable")
    }

    func testImportStagesOnlySourcesWithSeparateStableIDs() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let sources = try makeVoiceSources(in: library)
        let client = TestStoreClient()
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)
        let priorStateCalls = client.stateCalls
        let priorVoicesCalls = client.voicesCalls

        await fixture.store.importVoice(
            wav: sources.wav,
            transcript: sources.transcript,
            name: "New Voice",
            id: "new_voice")

        let submitted = try XCTUnwrap(client.importRequests.first)
        let stagingID = submitted.request.stagingID
        XCTAssertTrue(VoiceImportStaging.validateID(stagingID))
        XCTAssertEqual(stagingID.utf8.count, 32)
        XCTAssertTrue(stagingID.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 97 && byte <= 102)
        })
        XCTAssertNotEqual(submitted.requestID, stagingID)
        XCTAssertEqual(submitted.request.id, "new_voice")
        XCTAssertEqual(submitted.request.displayName, "New Voice")
        let stage = library.appendingPathComponent(".staging")
            .appendingPathComponent(submitted.request.stagingID)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stage.appendingPathComponent("reference.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stage.appendingPathComponent("transcript.txt").path))
        XCTAssertEqual(
            try Data(contentsOf: stage.appendingPathComponent(
                "reference.wav")),
            try Data(contentsOf: sources.wav))
        XCTAssertEqual(
            try Data(contentsOf: stage.appendingPathComponent(
                "transcript.txt")),
            try Data(contentsOf: sources.transcript))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: stage.path).sorted(),
            ["reference.wav", "transcript.txt"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: stage.appendingPathComponent("profile.json").path))
        XCTAssertGreaterThan(client.stateCalls, priorStateCalls)
        XCTAssertGreaterThan(client.voicesCalls, priorVoicesCalls)
    }

    func testImportSubmissionFailureCleansStagingDirectory() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let sources = try makeVoiceSources(in: library)
        let client = TestStoreClient()
        client.importError = DaemonError.management(
            status: 422,
            error: ManagementErrorDetail(
                code: "voice_audio_invalid",
                message: "Audio was invalid.",
                detail: nil,
                recoverable: true))
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)

        await settleStore(fixture.store)

        await fixture.store.importVoice(
            wav: sources.wav,
            transcript: sources.transcript,
            name: "Bad Voice",
            id: "bad_voice")

        let submitted = try XCTUnwrap(client.importRequests.first)
        let stage = library.appendingPathComponent(".staging")
            .appendingPathComponent(submitted.request.stagingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_audio_invalid")
    }
    func testLocalCopyFailureRemovesTheCreatedStage() throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let sources = try makeVoiceSources(in: library)
        let stagingID = "copy-failure-stage"
        var copies = 0

        XCTAssertThrowsError(try VoiceImportStaging.stage(
            wav: sources.wav,
            transcript: sources.transcript,
            library: library,
            stagingID: stagingID
        ) { source, destination in
            copies += 1
            if copies == 2 {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.copyItem(
                at: source,
                to: destination)
        })

        let stage = library.appendingPathComponent(".staging")
            .appendingPathComponent(stagingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }

    func testImportRejectsCollisionAndInvalidSourceBeforeStaging()
        async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let sources = try makeVoiceSources(in: library)
        let client = TestStoreClient()
        client.voiceSnapshot = makeVoices(revision: 2, ids: ["taken"])
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)

        await fixture.store.importVoice(
            wav: sources.wav,
            transcript: sources.transcript,
            name: "Taken",
            id: "taken")
        XCTAssertTrue(client.importRequests.isEmpty)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_id_collision")

        await fixture.store.importVoice(
            wav: sources.wav,
            transcript: sources.transcript,
            name: "Unsafe",
            id: "Unsafe ID")
        XCTAssertTrue(client.importRequests.isEmpty)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_id_invalid")

        let invalid = library.appendingPathComponent("invalid.wav")
        try Data("not a wave".utf8).write(to: invalid)
        await fixture.store.importVoice(
            wav: invalid,
            transcript: sources.transcript,
            name: "Invalid",
            id: "invalid")
        XCTAssertTrue(client.importRequests.isEmpty)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_audio_invalid")

        let emptyTranscript = library.appendingPathComponent("empty.txt")
        try Data("  \n".utf8).write(to: emptyTranscript)
        await fixture.store.importVoice(
            wav: sources.wav,
            transcript: emptyTranscript,
            name: "Empty Transcript",
            id: "empty_transcript")
        XCTAssertTrue(client.importRequests.isEmpty)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_transcript_invalid")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: library.appendingPathComponent(".staging").path))
    }

    func testImportAmbiguityRetriesIdenticalRequestAndStage() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let sources = try makeVoiceSources(in: library)
        let client = TestStoreClient()
        client.simulatesUnknownRecovery = true
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)

        await fixture.store.importVoice(
            wav: sources.wav,
            transcript: sources.transcript,
            name: "Retry",
            id: "retry")

        XCTAssertEqual(client.importRequests.count, 2)
        XCTAssertEqual(
            Set(client.importRequests.map { $0.requestID }).count,
            1)
        XCTAssertEqual(
            Set(client.importRequests.map {
                $0.request.stagingID
            }).count,
            1)
    }

    func testRenameAndDeleteAmbiguityReuseTheirRequestIDs() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let client = TestStoreClient()
        client.simulatesUnknownRecovery = true
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)

        await fixture.store.renameVoice(id: "new", name: "Renamed")
        XCTAssertEqual(client.renameRequests.count, 2)
        XCTAssertEqual(
            Set(client.renameRequests.map { $0.requestID }).count,
            1)

        await fixture.store.deleteVoice(id: "new")
        XCTAssertEqual(client.deleteRequests.count, 2)
        XCTAssertEqual(
            Set(client.deleteRequests.map { $0.requestID }).count,
            1)
    }

    func testRenameDeleteAndTerminalPollingReconcileSnapshots()
        async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let client = TestStoreClient()
        client.mutationOperation = OperationResponse(
            id: "ignored",
            kind: "update_voice",
            phase: .pending,
            target: "new",
            progress: nil,
            error: nil,
            response: nil)
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)
        let priorStateCalls = client.stateCalls
        let priorVoicesCalls = client.voicesCalls

        await fixture.store.renameVoice(id: "new", name: "Renamed")
        let renamed = try XCTUnwrap(client.renameRequests.first)
        XCTAssertEqual(renamed.id, "new")
        XCTAssertEqual(renamed.update.displayName, "Renamed")
        XCTAssertGreaterThan(client.operationCalls, 0)
        XCTAssertGreaterThan(client.stateCalls, priorStateCalls)
        XCTAssertGreaterThan(client.voicesCalls, priorVoicesCalls)

        client.mutationOperation = nil
        await fixture.store.deleteVoice(id: "new")
        XCTAssertEqual(client.deleteRequests.map { $0.id }, ["new"])
        let deleted = try XCTUnwrap(client.deleteRequests.first)
        XCTAssertNotEqual(renamed.requestID, deleted.requestID)
        await fixture.store.deleteVoice(id: "old")
        XCTAssertEqual(client.deleteRequests.map { $0.id }, ["new"])
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "active_voice_delete_forbidden")
    }

    func testMutationRejectsAnOperationForAnotherRequest() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let client = TestStoreClient()
        client.returnsMismatchedOperationID = true
        client.mutationOperation = OperationResponse(
            id: "different-request",
            kind: "update_voice",
            phase: .pending,
            target: "new",
            progress: nil,
            error: nil,
            response: nil)
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)

        await fixture.store.renameVoice(id: "new", name: "Renamed")

        XCTAssertEqual(client.operationCalls, 0)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "operation_id_mismatch")
    }

    func testDeleteSurfacesCapturedProfileRejection() async throws {
        let library = try makeVoiceTestDirectory()
        defer { try? FileManager.default.removeItem(at: library) }
        let client = TestStoreClient()
        client.deleteError = DaemonError.management(
            status: 409,
            error: ManagementErrorDetail(
                code: "voice_profile_captured",
                message: "Voice is in use.",
                detail: .string("new"),
                recoverable: true))
        let fixture = makeFixture(
            client: client,
            startsSession: true,
            library: library)
        await settleStore(fixture.store)

        await fixture.store.deleteVoice(id: "new")

        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "voice_profile_captured")
    }

    private func settleStore(
        _ store: WrenStore,
        requiringProof: Bool = true
    ) async {
        for _ in 0..<1_000 {
            let proofReady = !requiringProof
                || store.state.provenLocalLibrary != nil
            if proofReady, store.state.pendingAction == nil {
                return
            }
            await Task.yield()
        }
        XCTFail("store did not finish its initial refresh")
    }

    private func makeFixture(
        client: TestStoreClient = TestStoreClient(),
        startsSession: Bool,
        userDefaults: UserDefaults = .standard,
        ownership: DaemonManager.Ownership = .managed,
        library: URL = FileManager.default.temporaryDirectory,
        configuredLibrary: URL? = nil
    ) -> StoreFixture {
        let manager = TestStoreManager(
            endpoint: testEndpoint,
            ownership: ownership,
            meta: client.metadata,
            library: library)
        let player = TestStorePlayer()
        let factory = SingleSessionFactory(
            session: WrenSession(
                endpoint: testEndpoint,
                manager: manager,
                client: client,
                player: player,
                localLibraryLocation: configuredLibrary))
        let store = WrenStore(
            endpoint: testEndpoint,
            sessionFactory: factory,
            userDefaults: userDefaults,
            startsRefreshTimer: false,
            startsSession: startsSession)
        return StoreFixture(
            store: store,
            manager: manager,
            client: client,
            player: player)
    }
}

@MainActor
final class WrenStoreIntegrationTests: XCTestCase {
    func testAmbiguousMutationRecoversFromOperationEndpoint() async throws {
        let metaRequested = expectation(description: "meta requested")
        metaRequested.expectedFulfillmentCount = 3
        let stateRequested = expectation(description: "state requested")
        let voicesRequested = expectation(description: "voices requested")
        let operationRequested = expectation(description: "operation requested")
        stateRequested.assertForOverFulfill = false
        voicesRequested.assertForOverFulfill = false
        let server = try StubServer { request in
            switch request.path {
            case "/meta":
                metaRequested.fulfill()
                return (200, metaJSON(instance: "stub-instance"))
            case "/state":
                stateRequested.fulfill()
                return (200, stateJSON(revision: 3, voice: "old"))
            case "/voices":
                voicesRequested.fulfill()
                return (200, voicesJSON(revision: 4, ids: ["old", "new"]))
            case let path where path.hasPrefix("/operations/"):
                operationRequested.fulfill()
                let id = String(path.dropFirst("/operations/".count))
                return (200, operationJSON(id: id))
            default:
                return (404, errorJSON(
                    code: "unexpected_route",
                    message: request.path))
            }
        }
        defer { server.stop() }
        let intercept = OneShotMutationTimeout()
        let host = "127.0.0.1:\(server.port)"
        let daemonClient = DaemonClient(
            host: host,
            token: "secret"
        ) { request in
            if request.url?.path == "/voices/activate",
               intercept.take() {
                throw URLError(.timedOut)
            }
            return try await URLSession.shared.data(for: request)
        }
        let endpoint = URL(string: "http://\(host)")!
        let manager = TestStoreManager(
            endpoint: endpoint,
            ownership: .connected,
            meta: makeMeta(instance: "stub-instance"))
        let player = TestStorePlayer()
        let factory = SingleSessionFactory(session: WrenSession(
            endpoint: endpoint,
            manager: manager,
            client: HTTPStoreDaemonClient(client: daemonClient),
            player: player))
        let store = WrenStore(
            endpoint: endpoint,
            sessionFactory: factory,
            startsRefreshTimer: false)
        await fulfillment(
            of: [stateRequested, voicesRequested],
            timeout: 2)

        await store.activateVoice(id: "new")

        await fulfillment(
            of: [metaRequested, operationRequested],
            timeout: 2)
        XCTAssertNil(store.state.actionableError)
        XCTAssertNil(store.state.pendingAction)
        XCTAssertEqual(store.state.daemon?.synthesis.activeVoice, "old")
        let paths = server.requests.map(\.path)
        let metaIndices = paths.indices.filter {
            paths[$0] == "/meta"
        }
        let operationIndices = paths.indices.filter {
            paths[$0].hasPrefix("/operations/")
        }
        XCTAssertEqual(metaIndices.count, 3)
        XCTAssertEqual(operationIndices.count, 1)
        let operationIndex = try XCTUnwrap(operationIndices.first)
        XCTAssertLessThan(metaIndices[0], metaIndices[1])
        XCTAssertLessThan(metaIndices[1], operationIndex)
        XCTAssertLessThan(operationIndex, metaIndices[2])
    }
    func testNonWrenIdentityIsVisibleAndStopsResourceFetch() async throws {
        let server = try StubServer { request in
            if request.path == "/meta" {
                let body = metaJSON(instance: "foreign")
                    .replacingOccurrences(
                        of: "\"service\":\"wren\"",
                        with: "\"service\":\"other\"")
                return (200, body)
            }
            return (500, errorJSON(
                code: "resource_fetch_was_not_gated",
                message: request.path))
        }
        defer { server.stop() }
        let host = "127.0.0.1:\(server.port)"
        let endpoint = URL(string: "http://\(host)")!
        let manager = TestStoreManager(
            endpoint: endpoint,
            ownership: .connected,
            meta: nil)
        let player = TestStorePlayer()
        let client = HTTPStoreDaemonClient(client: DaemonClient(
            host: host,
            token: "secret"))
        let factory = SingleSessionFactory(session: WrenSession(
            endpoint: endpoint,
            manager: manager,
            client: client,
            player: player))
        let store = WrenStore(
            endpoint: endpoint,
            sessionFactory: factory,
            startsRefreshTimer: false)

        await store.refresh()

        XCTAssertEqual(
            store.state.actionableError?.code,
            "endpoint_identity")
        XCTAssertEqual(server.requests.map(\.path), ["/meta"])
        XCTAssertEqual(player.startCount, 0)
    }


    func testBareLaunchWiresActionsAndCleanQuit() async {
        let factory = RecordingSessionFactory(
            ownership: .managed,
            meta: makeMeta(instance: "launch"))
        let store = WrenStore(
            endpoint: testEndpoint,
            sessionFactory: factory,
            startsRefreshTimer: false)
        let menu = TestStoreMenu()
        let notifications = NotificationCenter()
        let controller = AppController(
            store: store,
            menuBar: menu,
            notificationCenter: notifications)
        await Task.yield()
        let session = factory.sessions[0]

        XCTAssertEqual(session.manager.startCount, 1)
        XCTAssertEqual(session.player.startCount, 1)
        let pauseCalled = expectation(description: "pause called")
        let stopCalled = expectation(description: "stop called")
        session.client.pauseCalled = pauseCalled
        session.client.stopCalled = stopCalled

        menu.onAction?(.setPaused(true))
        await fulfillment(of: [pauseCalled], timeout: 1)
        await waitForPendingActionToFinish(store)
        XCTAssertEqual(session.client.pauseCalls, 1)

        menu.onAction?(.stopSpeaking)
        await fulfillment(of: [stopCalled], timeout: 1)
        await waitForPendingActionToFinish(store)
        XCTAssertEqual(session.client.stopCalls, 1)

        notifications.post(
            name: NSApplication.willTerminateNotification,
            object: nil)
        await Task.yield()
        XCTAssertEqual(session.manager.shutdownCount, 1)
        XCTAssertEqual(session.player.stopCount, 1)
        withExtendedLifetime(controller) {}
    }

    private func waitForPendingActionToFinish(
        _ store: WrenStore
    ) async {
        while store.state.pendingAction != nil {
            await Task.yield()
        }
    }
}

private let testEndpoint = URL(string: "http://127.0.0.1:8765")!

private func makeMeta(instance: String) -> MetaResponse {
    MetaResponse(
        service: "wren",
        protocolVersion: 2,
        instanceID: instance,
        startedAt: "2026-08-11T00:00:00Z",
        capabilities: [
            .stateV2,
            .voiceList,
            .voiceActivate,
            .settingsV2,
            .stagedImport,
            .segmentPlayer,
        ])
}

private func makeDaemonState(
    revision: Int,
    voice: String,
    voicesDirectory: String? = nil
) -> DaemonStateResponse {
    DaemonStateResponse(
        revision: revision,
        voicesRevision: revision,
        lifecycle: DaemonLifecycle(phase: .ready, message: nil),
        synthesis: SynthesisState(
            ready: true,
            activeVoice: voice,
            effects: false,
            defaultSynthesisRate: 1.0,
            backend: "qwentts",
            model: "stub",
            host: nil,
            port: nil,
            voicesDirectory: voicesDirectory),
        operation: nil,
        playback: PlaybackState(
            pending: 0,
            speaking: false,
            paused: false),
        lastError: nil)
}

private func makeVoices(
    revision: Int,
    ids: [String]
) -> VoiceListResponse {
    VoiceListResponse(
        revision: revision,
        voices: ids.map {
            VoiceProfile(
                id: $0,
                displayName: $0,
                status: .ready,
                issues: [])
        })
}

private func makeOperation(id: String) -> OperationResponse {
    OperationResponse(
        id: id,
        kind: "activate_voice",
        phase: .succeeded,
        target: "new",
        progress: nil,
        error: nil,
        response: nil)
}

private func makeVoiceTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "wren-voice-management-\(UUID().uuidString)",
            isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    return directory
}

private func makeVoiceSources(
    in directory: URL
) throws -> (wav: URL, transcript: URL) {
    let wav = directory.appendingPathComponent("source.wav")
    let transcript = directory.appendingPathComponent(
        "independent-transcript.data")
    var header = Data("RIFF".utf8)
    header.append(contentsOf: [0, 0, 0, 0])
    header.append(Data("WAVE".utf8))
    try header.write(to: wav)
    try Data("A deterministic transcript.".utf8).write(to: transcript)
    return (wav, transcript)
}

private struct StoreFixture {
    let store: WrenStore
    let manager: TestStoreManager
    let client: TestStoreClient
    let player: TestStorePlayer
}

private final class SingleSessionFactory: WrenSessionMaking {
    let session: WrenSession

    init(session: WrenSession) {
        self.session = session
    }

    func makeSession(endpoint: URL) -> WrenSession {
        session
    }
}

private final class RecordingSessionFactory: WrenSessionMaking {
    struct SessionRecord {
        let endpoint: URL
        let manager: TestStoreManager
        let client: TestStoreClient
        let player: TestStorePlayer
    }

    let ownership: DaemonManager.Ownership
    let initialMeta: MetaResponse
    private(set) var sessions: [SessionRecord] = []

    init(ownership: DaemonManager.Ownership, meta: MetaResponse) {
        self.ownership = ownership
        initialMeta = meta
    }

    func makeSession(endpoint: URL) -> WrenSession {
        let index = sessions.count
        let sessionMeta = makeMeta(
            instance: "\(initialMeta.instanceID)-\(index)")
        let manager = TestStoreManager(
            endpoint: endpoint,
            ownership: ownership,
            meta: sessionMeta)
        let client = TestStoreClient()
        client.metadata = sessionMeta
        client.daemonSnapshot = makeDaemonState(revision: 1, voice: "old")
        client.voiceSnapshot = makeVoices(revision: 1, ids: ["old"])
        let player = TestStorePlayer()
        sessions.append(SessionRecord(
            endpoint: endpoint,
            manager: manager,
            client: client,
            player: player))
        return WrenSession(
            endpoint: endpoint,
            manager: manager,
            client: client,
            player: player)
    }
}

private final class TestStoreManager: AppDaemonManaging,
    @unchecked Sendable {
    var onState: (@Sendable (DaemonManager.State) -> Void)?
    let managerState: DaemonManager.State
    private let ownership: DaemonManager.Ownership
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var retryCount = 0
    private(set) var restartCount = 0
    private(set) var resetInvalidSettingsCount = 0

    func resetInvalidSettings() {
        resetInvalidSettingsCount += 1
    }

    init(
        endpoint: URL,
        ownership: DaemonManager.Ownership,
        meta: MetaResponse?,
        library: URL = FileManager.default.temporaryDirectory
    ) {
        self.ownership = ownership
        managerState = DaemonManager.State(
            phase: .ready,
            ownership: ownership,
            endpoint: endpoint,
            error: nil,
            logLocation: ownership == .managed
                ? URL(fileURLWithPath: "/tmp/wren.log")
                : nil,
            libraryLocation: ownership == .managed ? library : nil,
            meta: meta)
    }

    func start() {
        startCount += 1
        onState?(managerState)
    }

    func shutdown() {
        if ownership == .managed {
            shutdownCount += 1
        }
    }

    func retry() {
        retryCount += 1
    }

    func restart() {
        restartCount += 1
        onState?(managerState)
    }
}

private final class TestStorePlayer: AppSegmentPlaying,
    @unchecked Sendable {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pausedValues: [Bool] = []
    private(set) var rates: [Double] = []

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setPaused(_ paused: Bool) {
        pausedValues.append(paused)
    }

    func setRate(_ rate: Double) {
        rates.append(rate)
    }
    func setOutputDevice(_ deviceID: AudioDeviceID) async throws {}

}

private final class TestStoreClient: StoreDaemonClient,
    @unchecked Sendable {
    var metadata = makeMeta(instance: "one")
    var daemonSnapshot = makeDaemonState(revision: 1, voice: "old")
    var voiceSnapshot = makeVoices(revision: 1, ids: ["old"])
    var voiceSnapshots: [VoiceListResponse] = []
    var controlledMeta: ControlledMetaResponses?
    var metaCalled: XCTestExpectation?
    var metaError: Error?
    var settingsError: Error?
    var pauseError: Error?
    var resumeError: Error?
    var suspendActivation = false
    var suspendPause = false
    var suspendStop = false
    var activationSubmitted: XCTestExpectation?
    var pauseCalled: XCTestExpectation?
    var resumeCalled: XCTestExpectation?
    var stopCalled: XCTestExpectation?
    var simulatesUnknownRecovery = false
    var importError: Error?
    var renameError: Error?
    var deleteError: Error?
    var mutationOperation: OperationResponse?
    var returnsMismatchedOperationID = false
    private(set) var activationRequestIDs: [String] = []
    private(set) var activationVoices: [String] = []
    private(set) var importRequests:
        [(request: ImportVoiceRequest, requestID: String)] = []
    private(set) var renameRequests:
        [(id: String, update: UpdateVoiceRequest, requestID: String)] = []
    private(set) var deleteRequests:
        [(id: String, requestID: String)] = []
    private(set) var operationCalls = 0
    private(set) var settingsCalls = 0
    private(set) var stateCalls = 0
    private(set) var voicesCalls = 0
    private(set) var pauseCalls = 0
    private(set) var resumeCalls = 0
    private(set) var stopCalls = 0
    private(set) var lastRequestID = "missing"

    private let lock = NSLock()
    private var activationContinuation:
        CheckedContinuation<OperationResponse, Error>?
    private var pauseContinuation:
        CheckedContinuation<PauseResponse, Error>?
    private var stopContinuation:
        CheckedContinuation<StopResponse, Error>?

    func meta() async throws -> MetaResponse {
        metaCalled?.fulfill()
        if let controlledMeta {
            return try await controlledMeta.next()
        }
        if let metaError { throw metaError }
        return metadata
    }

    func state() async throws -> DaemonStateResponse {
        stateCalls += 1
        return daemonSnapshot
    }

    func voices() async throws -> VoiceListResponse {
        voicesCalls += 1
        guard !voiceSnapshots.isEmpty else { return voiceSnapshot }
        return voiceSnapshots.removeFirst()
    }

    func operation(requestID: String) async throws -> OperationResponse {
        operationCalls += 1
        if simulatesUnknownRecovery {
            throw DaemonError.management(
                status: 404,
                error: ManagementErrorDetail(
                    code: "operation_result_unknown",
                    message: "Operation is unknown.",
                    detail: nil,
                    recoverable: true))
        }
        return makeOperation(id: requestID)
    }

    func activateVoice(
        _ voice: String,
        requestID: String
    ) async throws -> OperationResponse {
        lastRequestID = requestID
        activationRequestIDs.append(requestID)
        activationVoices.append(voice)
        if simulatesUnknownRecovery,
           activationRequestIDs.count == 1 {
            throw DaemonError.ambiguousSubmittedMutation(
                requestID: requestID,
                description: "timed out")
        }
        activationSubmitted?.fulfill()
        guard suspendActivation else { return makeOperation(id: requestID) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            activationContinuation = continuation
            lock.unlock()
        }
    }

    func resumeActivation(_ result: OperationResponse) {
        lock.lock()
        let continuation = activationContinuation
        activationContinuation = nil
        suspendActivation = false
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func importVoice(
        _ request: ImportVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        importRequests.append((request, requestID))
        if simulatesUnknownRecovery, importRequests.count == 1 {
            throw DaemonError.ambiguousSubmittedMutation(
                requestID: requestID,
                description: "timed out")
        }
        if let importError { throw importError }
        return mutationResult(requestID: requestID)
    }

    func updateVoice(
        id: String,
        update: UpdateVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        renameRequests.append((id, update, requestID))
        if simulatesUnknownRecovery, renameRequests.count == 1 {
            throw DaemonError.ambiguousSubmittedMutation(
                requestID: requestID,
                description: "timed out")
        }
        if let renameError { throw renameError }
        return mutationResult(requestID: requestID)
    }

    func deleteVoice(
        id: String,
        requestID: String
    ) async throws -> OperationResponse {
        deleteRequests.append((id, requestID))
        if simulatesUnknownRecovery, deleteRequests.count == 1 {
            throw DaemonError.ambiguousSubmittedMutation(
                requestID: requestID,
                description: "timed out")
        }
        if let deleteError { throw deleteError }
        return mutationResult(requestID: requestID)
    }

    private func mutationResult(
        requestID: String
    ) -> OperationResponse {
        guard var operation = mutationOperation else {
            return makeOperation(id: requestID)
        }
        if !returnsMismatchedOperationID {
            operation.id = requestID
        }
        return operation
    }

    func updateSettings(
        _ update: SettingsUpdateRequest,
        requestID: String
    ) async throws -> DaemonStateResponse {
        settingsCalls += 1
        if let settingsError { throw settingsError }
        return daemonSnapshot
    }

    func pause() async throws -> PauseResponse {
        pauseCalls += 1
        pauseCalled?.fulfill()
        if let pauseError { throw pauseError }
        guard suspendPause else {
            return PauseResponse(ok: true, paused: true)
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pauseContinuation = continuation
            lock.unlock()
        }
    }

    func resume() async throws -> PauseResponse {
        resumeCalls += 1
        resumeCalled?.fulfill()
        if let resumeError { throw resumeError }
        return PauseResponse(ok: true, paused: false)
    }

    func stopSpeaking() async throws -> StopResponse {
        stopCalls += 1
        stopCalled?.fulfill()
        guard suspendStop else { return StopResponse(ok: true) }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            stopContinuation = continuation
            lock.unlock()
        }
    }

    func resumePause(paused: Bool) {
        lock.lock()
        let continuation = pauseContinuation
        pauseContinuation = nil
        suspendPause = false
        lock.unlock()
        continuation?.resume(returning: PauseResponse(
            ok: true,
            paused: paused))
    }

    func resumeStop() {
        lock.lock()
        let continuation = stopContinuation
        stopContinuation = nil
        suspendStop = false
        lock.unlock()
        continuation?.resume(returning: StopResponse(ok: true))
    }
}

private final class ControlledMetaResponses: @unchecked Sendable {
    private let lock = NSLock()
    private let expectations: [XCTestExpectation]
    private var continuations:
        [CheckedContinuation<MetaResponse, Error>?] = []

    init(expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    func next() async throws -> MetaResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let index = continuations.count
            continuations.append(continuation)
            lock.unlock()
            expectations[index].fulfill()
        }
    }

    func resume(at index: Int, with meta: MetaResponse) {
        lock.lock()
        let continuation = continuations[index]
        continuations[index] = nil
        lock.unlock()
        continuation?.resume(returning: meta)
    }
}

@MainActor
private final class TestStoreMenu: AppMenuPresenting {
    var onAction: ((WrenMenuBar.Action) -> Void)?
    private(set) var states: [AppState] = []

    func render(_ state: AppState) {
        states.append(state)
    }
}

private final class OneShotMutationTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}

private func metaJSON(instance: String) -> String {
    """
    {"service":"wren","protocol_version":2,"instance_id":"\(instance)",
    "started_at":"2026-08-11T00:00:00Z","capabilities":["state-v2",
    "voice-list","voice-activate","settings-v2","segment-player"]}
    """
}

private func stateJSON(revision: Int, voice: String) -> String {
    """
    {"revision":\(revision),"voices_revision":4,
    "lifecycle":{"phase":"ready","message":null},
    "synthesis":{"ready":true,"active_voice":"\(voice)","effects":false,
    "default_synthesis_rate":1.0,"backend":"qwentts","model":"stub"},
    "operation":null,
    "playback":{"pending":0,"speaking":false,"paused":false},
    "last_error":null}
    """
}

private func voicesJSON(revision: Int, ids: [String]) -> String {
    let entries = ids.map {
        "{\"id\":\"\($0)\",\"display_name\":\"\($0)\"," +
            "\"status\":\"ready\",\"issues\":[]}"
    }.joined(separator: ",")
    return "{\"revision\":\(revision),\"voices\":[\(entries)]}"
}

private func operationJSON(id: String) -> String {
    """
    {"id":"\(id)","kind":"activate_voice","phase":"succeeded",
    "target":"new","progress":null,"error":null,"response":null}
    """
}

private func errorJSON(code: String, message: String) -> String {
    """
    {"error":{"code":"\(code)","message":"\(message)",
    "detail":null,"recoverable":false}}
    """
}
