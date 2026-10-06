import Foundation
import XCTest
@testable import wren

@MainActor
final class StoreTests: XCTestCase {
    private var model: ContractModel!
    private var server: FakeServer!
    private var endpoint: MemoryEndpointStore!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        model = ContractModel()
        let model = model!
        server = FakeServer { model.handle($0) }
        endpoint = MemoryEndpointStore(host: "saved:1")
        suite = "wren-store-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeStore(
        environment: [String: String] = [:]
    ) -> WrenStore {
        WrenStore(
            endpoint: endpoint,
            environment: environment,
            userDefaults: defaults,
            audioDevices: FakeAudioProvider(),
            loginItem: FakeLoginItem(),
            hostname: "Studio.local",
            transport: server.transport,
            runsServices: false
        )
    }

    func testChannelAndEndpointFromSavedSettings() {
        let store = makeStore()
        XCTAssertEqual(store.state.channel, "mac-studio")
        XCTAssertEqual(store.state.host, "saved:1")
        XCTAssertEqual(store.state.status, .connecting)
    }

    func testEnvironmentOverridesSavedEndpoint() {
        let store = makeStore(environment: ["WREN_HOST": "env:2"])
        XCTAssertEqual(store.state.host, "env:2")
    }

    func testFirstConnectClaimsActiveWithHostnameLabel() async {
        let store = makeStore()
        let ok = await store.pollState()
        XCTAssertTrue(ok)
        XCTAssertEqual(store.state.status, .connected)
        let claims = server.requests("POST", "/clients/active")
        XCTAssertEqual(claims.count, 1)
        XCTAssertEqual(
            jsonBody(claims[0]) as NSDictionary,
            ["channel": "mac-studio", "label": "Studio.local"]
        )
        XCTAssertTrue(store.state.isPlayingHere)

        await store.pollState()
        XCTAssertEqual(
            server.requests("POST", "/clients/active").count,
            1,
            "steady polling never re-claims"
        )
    }

    func testClaimSkippedWhenAlreadyActive() async {
        model.activeClient = ["channel": "mac-studio", "label": "x"]
        let store = makeStore()
        await store.pollState()
        await store.claimIfNeeded()
        XCTAssertTrue(server.requests("POST", "/clients/active").isEmpty)
    }

    func testInputAfterAnotherMacClaimedReclaims() async {
        let store = makeStore()
        await store.pollState()
        model.activeClient = ["channel": "mac-other", "label": "Other"]
        await store.pollState()
        XCTAssertFalse(store.state.isPlayingHere)
        XCTAssertEqual(
            SettingsViewModel.activeClientText(store.state),
            "Playing on Other"
        )

        await store.claimIfNeeded()
        XCTAssertEqual(server.requests("POST", "/clients/active").count, 2)
        XCTAssertTrue(store.state.isPlayingHere)
    }

    func testReconnectAfterOutageClaimsAgain() async {
        let store = makeStore()
        await store.pollState()
        let model = model!
        server.route = { _ in
            FakeServer.Reply(status: 500, json: "down")
        }
        await store.pollState()
        guard case .unreachable = store.state.status else {
            return XCTFail("expected unreachable")
        }
        model.activeClient = nil
        server.route = { model.handle($0) }
        await store.pollState()
        XCTAssertEqual(server.requests("POST", "/clients/active").count, 2)
    }

    func testUpdateEndpointPersistsAndReconnects() async {
        let store = makeStore()
        store.updateEndpoint(host: "http://new:5/")
        XCTAssertEqual(endpoint.savedHost, "new:5")
        XCTAssertEqual(store.state.host, "new:5")
        XCTAssertEqual(store.state.status, .connecting)

        await store.pollState()
        XCTAssertEqual(store.state.status, .connected)
        XCTAssertEqual(server.requests.last?.url?.host, "new")
    }

    func testEmptyHostFallsBackToDefault() {
        let store = makeStore()
        store.updateEndpoint(host: "")
        XCTAssertEqual(store.state.host, Endpoint.defaultHost)
    }

    func testVoiceActivationFollowsServerState() async {
        let store = makeStore()
        await store.pollState()
        XCTAssertEqual(store.state.activeVoice, "c3po")

        await store.activateVoice(id: "r2")
        XCTAssertEqual(store.state.activeVoice, "r2")
        XCTAssertEqual(
            jsonBody(server.requests("PUT", "/voice")[0]) as NSDictionary,
            ["voice": "r2"]
        )
        XCTAssertEqual(WrenMenuModel(state: store.state).voiceBadge, "R2")
        XCTAssertNil(store.state.lastError)
    }

    func testNewlyAddedVoiceCanBeActivated() async throws {
        let store = makeStore()
        await store.pollState()
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("wren-\(UUID().uuidString).wav")
        try Data("RIFF".utf8).write(to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }

        let added = await store.addVoice(
            id: "added",
            name: "Added",
            audioURL: wav,
            transcript: "hi"
        )
        XCTAssertTrue(added)
        XCTAssertTrue(store.state.voices.contains { $0.id == "added" })

        await store.activateVoice(id: "added")
        XCTAssertEqual(store.state.activeVoice, "added")
        let row = SettingsViewModel(state: store.state).voices
            .first { $0.id == "added" }
        XCTAssertEqual(row?.isActive, true)
    }

    func testFailedActivationIsReported() async {
        let store = makeStore()
        await store.pollState()
        await store.activateVoice(id: "ghost")
        XCTAssertEqual(store.state.activeVoice, "c3po")
        XCTAssertTrue(store.state.lastError?.contains("unknown_voice") ?? false)
    }

    func testEffectsRoundTrip() async {
        let store = makeStore()
        await store.pollState()
        await store.setEffects(true)
        XCTAssertTrue(store.state.effects)
        XCTAssertTrue(model.effects)
        XCTAssertEqual(
            jsonBody(server.requests("PATCH", "/settings")[0])
                as NSDictionary,
            ["effects": true]
        )
        await store.setEffects(false)
        XCTAssertFalse(store.state.effects)
    }

    func testMenuControlsTargetThisMacsChannel() async {
        let store = makeStore()
        await store.setPaused(true)
        await store.stopSpeaking()
        XCTAssertTrue(store.state.localPlayer.isPaused)
        XCTAssertEqual(
            jsonBody(server.requests("POST", "/pause")[0]) as NSDictionary,
            ["channel": "mac-studio"]
        )
        XCTAssertEqual(
            jsonBody(server.requests("POST", "/stop")[0]) as NSDictionary,
            ["channel": "mac-studio"]
        )
    }

    func testRenameAndDeleteHitVoiceRoutes() async {
        let store = makeStore()
        await store.renameVoice(id: "r2", displayName: "Artoo")
        await store.deleteVoice(id: "r2")
        XCTAssertEqual(server.requests("PATCH", "/voices/r2").count, 1)
        XCTAssertEqual(server.requests("DELETE", "/voices/r2").count, 1)
    }

    func testObserverFiresOncePerPoll() async {
        let store = makeStore()
        model.activeClient = ["channel": "mac-studio"]
        var renders = 0
        store.observe { _ in renders += 1 }
        XCTAssertEqual(renders, 1)
        await store.pollState()
        XCTAssertEqual(renders, 2, "one batched update per poll")
        await store.pollState()
        XCTAssertEqual(renders, 2, "unchanged state does not notify")
    }

    func testSpeakingRatePersistsLocally() {
        let store = makeStore()
        store.setSpeakingRate(1.4)
        XCTAssertEqual(defaults.double(forKey: WrenStore.rateKey), 1.4)
        XCTAssertEqual(makeStore().state.localPlayer.speakingRate, 1.4)
    }

    func testOutputDeviceSelectionPersists() async {
        let store = makeStore()
        let device = AudioOutputDevice(uid: "speakers", name: "Speakers")
        await store.setOutputDevice(device)
        XCTAssertEqual(store.state.audioOutput.desiredUID, "speakers")
        XCTAssertEqual(store.state.audioOutput.effectiveDevice, device)
        await store.setOutputDevice(nil)
        XCTAssertNil(store.state.audioOutput.desiredUID)
    }
}

@MainActor
final class FakeMenu: AppMenuPresenting {
    var onAction: ((WrenMenuBar.Action) -> Void)?
    var rendered: [AppState] = []
    func render(_ state: AppState) { rendered.append(state) }
}

@MainActor
final class AppControllerTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testMenuActionsReachServerAndRenderBack() async throws {
        let model = ContractModel()
        let server = FakeServer { model.handle($0) }
        let suite = "wren-app-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WrenStore(
            endpoint: MemoryEndpointStore(host: "h:1"),
            environment: [:],
            userDefaults: defaults,
            audioDevices: FakeAudioProvider(),
            loginItem: FakeLoginItem(),
            hostname: "studio",
            transport: server.transport,
            runsServices: false
        )
        let menu = FakeMenu()
        var quit = false
        let controller = AppController(
            store: store,
            menuBar: menu,
            notificationCenter: NotificationCenter(),
            terminate: { quit = true }
        )
        XCTAssertEqual(menu.rendered.count, 1, "initial render")

        // Sequential on purpose: the two actions race on the wire, and a
        // stale /settings body may land last; the poll loop reconciles
        // that in the app, but this test asserts routing, not ordering.
        menu.onAction?(.activateVoice(id: "r2"))
        try await waitUntil { store.state.activeVoice == "r2" }
        menu.onAction?(.setEffects(true))
        try await waitUntil { store.state.effects }
        XCTAssertEqual(menu.rendered.last?.activeVoice, "r2")
        XCTAssertEqual(menu.rendered.last?.effects, true)

        menu.onAction?(.quit)
        XCTAssertTrue(quit)
        withExtendedLifetime(controller) {}
    }
}
