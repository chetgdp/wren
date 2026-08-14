import CoreAudio
import Foundation
import XCTest
@testable import wren

@MainActor
final class NativePreferencesStoreTests: XCTestCase {
    func testSelectionPersistsStableUIDAndName() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        let selected = AudioOutputDevice(uid: "desk", name: "Desk DAC")
        fixture.devices.resolutions["desk"] = ResolvedAudioOutputDevice(
            device: selected,
            objectID: 10)

        await fixture.store.setOutputDevice(selected)

        XCTAssertEqual(
            fixture.defaults.string(forKey: "outputDeviceUID"),
            "desk")
        XCTAssertEqual(
            fixture.defaults.string(forKey: "outputDeviceName"),
            "Desk DAC")
        XCTAssertEqual(fixture.store.state.audioOutput.desiredUID, "desk")
        XCTAssertEqual(
            fixture.store.state.audioOutput.effectiveDevice,
            selected)
        XCTAssertEqual(fixture.player.deviceIDs, [10])
    }

    func testHotPlugKeepsIntentAndFallsBackToDefault() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        let selected = AudioOutputDevice(uid: "desk", name: "Desk DAC")
        fixture.devices.resolutions["desk"] = ResolvedAudioOutputDevice(
            device: selected,
            objectID: 10)
        await fixture.store.setOutputDevice(selected)
        fixture.devices.resolutions["desk"] = nil
        fixture.devices.currentSnapshot = snapshot(
            devices: [systemDevice],
            defaultDevice: systemDevice,
            defaultID: 20)
        let fallback = expectation(description: "default fallback")
        fixture.player.onDevice = { id in
            if id == 20 { fallback.fulfill() }
        }

        fixture.devices.emit(.devices)
        await fulfillment(of: [fallback], timeout: 1)
        await Task.yield()

        let state = fixture.store.state.audioOutput
        XCTAssertEqual(state.desiredUID, "desk")
        XCTAssertEqual(state.desiredName, "Desk DAC")
        XCTAssertEqual(state.effectiveDevice, systemDevice)
        XCTAssertTrue(state.fallbackWarning?.contains("disconnected") == true)
    }

    func testDefaultChangeUpdatesConcreteFallbackRoute() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        let missing = AudioOutputDevice(uid: "missing", name: "Travel DAC")
        await fixture.store.setOutputDevice(missing)
        let headphones = AudioOutputDevice(
            uid: "headphones",
            name: "Headphones")
        fixture.devices.currentSnapshot = snapshot(
            devices: [headphones],
            defaultDevice: headphones,
            defaultID: 30)
        let changed = expectation(description: "new concrete default")
        fixture.player.onDevice = { id in
            if id == 30 { changed.fulfill() }
        }

        fixture.devices.emit(.defaultOutput)
        await fulfillment(of: [changed], timeout: 1)
        await Task.yield()

        XCTAssertEqual(
            fixture.store.state.audioOutput.effectiveDevice,
            headphones)
        XCTAssertEqual(fixture.store.state.audioOutput.desiredUID, "missing")
        XCTAssertNotNil(fixture.store.state.audioOutput.fallbackWarning)
    }

    func testSelectionFailureUsesDefaultAndKeepsIntent() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        let selected = AudioOutputDevice(uid: "desk", name: "Desk DAC")
        fixture.devices.resolutions["desk"] = ResolvedAudioOutputDevice(
            device: selected,
            objectID: 10)
        fixture.player.errors[10] = AudioOutputError.osStatus(
            operation: "Selecting output device",
            status: -50)

        await fixture.store.setOutputDevice(selected)

        let state = fixture.store.state.audioOutput
        XCTAssertEqual(state.desiredUID, "desk")
        XCTAssertEqual(state.effectiveDevice, systemDevice)
        XCTAssertNotNil(state.fallbackWarning)
        XCTAssertEqual(fixture.player.deviceIDs, [10, 20])
    }

    func testRefreshPreservesListAndSurfacesProviderError() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        fixture.devices.snapshotError = AudioOutputError.osStatus(
            operation: "Enumerating audio devices",
            status: -50)

        await fixture.store.refreshLocalPreferences()

        XCTAssertEqual(
            fixture.store.state.audioOutput.devices,
            [systemDevice])
        XCTAssertTrue(
            fixture.store.state.audioOutput.providerError?
                .contains("-50") == true)
    }

    func testExternalLoginStatusAppearsOnRefresh() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        fixture.login.current = LoginItemState(
            isAvailable: true,
            isEnabled: true,
            error: nil)

        await fixture.store.refreshLocalPreferences()

        XCTAssertTrue(fixture.store.state.loginItem.isEnabled)
    }

    func testConnectedRecoveryIsVisibleButProcessActionsAreBlocked() async {
        let failure = DaemonManager.Failure(
            kind: .transport,
            message: "Connection failed.",
            canRetry: true,
            canResetInvalidSettings: true)
        let manager = NativeTestManager(state: DaemonManager.State(
            phase: .failed,
            ownership: .connected,
            endpoint: testEndpoint,
            error: failure,
            logLocation: nil,
            libraryLocation: nil,
            meta: nil))
        let fixture = makeFixture(manager: manager, startsSession: true)
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        let managerVisible = expectation(description: "manager state visible")
        managerVisible.assertForOverFulfill = false
        fixture.store.observe { state in
            if state.manager != nil {
                managerVisible.fulfill()
            }
        }
        await fulfillment(of: [managerVisible], timeout: 1)

        XCTAssertFalse(fixture.store.state.managerRecovery.canRetry)
        XCTAssertFalse(
            fixture.store.state.managerRecovery.canResetInvalidSettings)
        XCTAssertNil(
            fixture.store.state.managerRecovery.revealLogURL)
        fixture.store.retryStartup()
        fixture.store.resetInvalidSettings()

        XCTAssertEqual(manager.retryCount, 0)
        XCTAssertEqual(manager.restartCount, 0)
        XCTAssertEqual(manager.resetCount, 0)
        XCTAssertEqual(
            fixture.store.state.actionableError?.code,
            "settings_reset_unavailable")
    }

    func testManagedRecoveryExposesOwnedActionsAndLogURL() async {
        let failure = DaemonManager.Failure(
            kind: .launch,
            message: "Launch failed.",
            canRetry: true,
            canResetInvalidSettings: true)
        let manager = NativeTestManager(state: DaemonManager.State(
            phase: .failed,
            ownership: .managed,
            endpoint: testEndpoint,
            error: failure,
            logLocation: URL(fileURLWithPath: "/tmp/wren.log"),
            libraryLocation: FileManager.default.temporaryDirectory,
            meta: nil))
        let fixture = makeFixture(manager: manager, startsSession: true)
        defer { fixture.defaults.removePersistentDomain(
            forName: fixture.defaultsSuite) }
        let managerVisible = expectation(description: "manager state visible")
        managerVisible.assertForOverFulfill = false
        fixture.store.observe { state in
            if state.manager != nil {
                managerVisible.fulfill()
            }
        }
        await fulfillment(of: [managerVisible], timeout: 1)

        XCTAssertTrue(fixture.store.state.managerRecovery.canRetry)
        XCTAssertTrue(
            fixture.store.state.managerRecovery.canResetInvalidSettings)
        XCTAssertEqual(
            fixture.store.state.managerRecovery.revealLogURL?.path,
            "/tmp/wren.log")
        fixture.store.resetInvalidSettings()
        let resetFinished = expectation(description: "reset finished")
        resetFinished.assertForOverFulfill = false
        fixture.store.observe { state in
            if manager.resetCount == 1, state.pendingAction == nil {
                resetFinished.fulfill()
            }
        }
        await fulfillment(of: [resetFinished], timeout: 1)
        fixture.store.retryStartup()

        XCTAssertEqual(manager.resetCount, 1)
        XCTAssertEqual(manager.retryCount, 1)
    }

    private func makeFixture(
        manager: NativeTestManager = NativeTestManager(),
        startsSession: Bool = false
    ) -> NativeStoreFixture {
        let suite = "NativePreferencesStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let devices = NativeTestAudioDevices(
            snapshot: snapshot(
                devices: [systemDevice],
                defaultDevice: systemDevice,
                defaultID: 20))
        let login = NativeTestLoginItem()
        let player = NativeTestPlayer()
        let session = WrenSession(
            endpoint: testEndpoint,
            manager: manager,
            client: NativeTestClient(),
            player: player)
        let store = WrenStore(
            endpoint: testEndpoint,
            sessionFactory: NativeTestSessionFactory(session: session),
            userDefaults: defaults,
            audioDevices: devices,
            loginItem: login,
            startsRefreshTimer: false,
            startsSession: startsSession)
        return NativeStoreFixture(
            store: store,
            defaults: defaults,
            defaultsSuite: suite,
            devices: devices,
            login: login,
            player: player)
    }
}

private let testEndpoint = URL(string: "http://127.0.0.1:8765")!
private let systemDevice = AudioOutputDevice(
    uid: "system",
    name: "Built-in Output")

private func snapshot(
    devices: [AudioOutputDevice],
    defaultDevice: AudioOutputDevice,
    defaultID: AudioDeviceID
) -> AudioOutputDeviceSnapshot {
    AudioOutputDeviceSnapshot(
        devices: devices,
        defaultDevice: ResolvedAudioOutputDevice(
            device: defaultDevice,
            objectID: defaultID))
}

@MainActor
private struct NativeStoreFixture {
    let store: WrenStore
    let defaults: UserDefaults
    let defaultsSuite: String
    let devices: NativeTestAudioDevices
    let login: NativeTestLoginItem
    let player: NativeTestPlayer
}

private final class NativeTestSessionFactory: WrenSessionMaking {
    let session: WrenSession

    init(session: WrenSession) {
        self.session = session
    }

    func makeSession(endpoint: URL) -> WrenSession {
        session
    }
}

private final class NativeTestAudioDevices: AudioOutputDeviceProviding {
    var currentSnapshot: AudioOutputDeviceSnapshot
    var resolutions: [String: ResolvedAudioOutputDevice] = [:]
    var snapshotError: Error?
    private var handler:
        (@Sendable (AudioOutputDeviceChange) -> Void)?

    init(snapshot: AudioOutputDeviceSnapshot) {
        currentSnapshot = snapshot
    }

    func snapshot() throws -> AudioOutputDeviceSnapshot {
        if let snapshotError { throw snapshotError }
        return currentSnapshot
    }

    func resolve(uid: String) throws -> ResolvedAudioOutputDevice? {
        resolutions[uid]
    }

    func startObserving(
        _ handler: @escaping @Sendable (AudioOutputDeviceChange) -> Void
    ) throws {
        self.handler = handler
    }

    func stopObserving() {
        handler = nil
    }

    func emit(_ change: AudioOutputDeviceChange) {
        handler?(change)
    }
}

private final class NativeTestLoginItem: LoginItemProviding {
    var current = LoginItemState(
        isAvailable: true,
        isEnabled: false,
        error: nil)

    func refresh() -> LoginItemState {
        current
    }

    func setEnabled(_ enabled: Bool) -> LoginItemState {
        current = LoginItemState(
            isAvailable: true,
            isEnabled: enabled,
            error: nil)
        return current
    }
}

private final class NativeTestPlayer: AppSegmentPlaying,
    @unchecked Sendable {
    var deviceIDs: [AudioDeviceID] = []
    var errors: [AudioDeviceID: Error] = [:]
    var onDevice: ((AudioDeviceID) -> Void)?

    func start() {}
    func stop() {}
    func setPaused(_ paused: Bool) {}
    func setRate(_ rate: Double) {}

    func setOutputDevice(_ deviceID: AudioDeviceID) async throws {
        deviceIDs.append(deviceID)
        onDevice?(deviceID)
        if let error = errors[deviceID] { throw error }
    }
}

private final class NativeTestManager: AppDaemonManaging,
    @unchecked Sendable {
    var onState: (@Sendable (DaemonManager.State) -> Void)?
    let state: DaemonManager.State?
    private(set) var retryCount = 0
    private(set) var restartCount = 0
    private(set) var resetCount = 0

    init(state: DaemonManager.State? = nil) {
        self.state = state
    }

    func start() {
        if let state { onState?(state) }
    }

    func shutdown() {}

    func retry() {
        retryCount += 1
    }

    func restart() {
        restartCount += 1
    }

    func resetInvalidSettings() {
        resetCount += 1
        if let state { onState?(state) }
    }
}

private enum NativeTestError: Error {
    case unused
}

private final class NativeTestClient: StoreDaemonClient,
    @unchecked Sendable {
    func meta() async throws -> MetaResponse { throw NativeTestError.unused }
    func state() async throws -> DaemonStateResponse {
        throw NativeTestError.unused
    }
    func voices() async throws -> VoiceListResponse {
        throw NativeTestError.unused
    }
    func operation(requestID: String) async throws -> OperationResponse {
        throw NativeTestError.unused
    }
    func activateVoice(
        _ voice: String,
        requestID: String
    ) async throws -> OperationResponse {
        throw NativeTestError.unused
    }
    func importVoice(
        _ request: ImportVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        throw NativeTestError.unused
    }
    func updateVoice(
        id: String,
        update: UpdateVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        throw NativeTestError.unused
    }
    func deleteVoice(
        id: String,
        requestID: String
    ) async throws -> OperationResponse {
        throw NativeTestError.unused
    }
    func updateSettings(
        _ update: SettingsUpdateRequest,
        requestID: String
    ) async throws -> DaemonStateResponse {
        throw NativeTestError.unused
    }
    func pause() async throws -> PauseResponse {
        throw NativeTestError.unused
    }
    func resume() async throws -> PauseResponse {
        throw NativeTestError.unused
    }
    func stopSpeaking() async throws -> StopResponse {
        throw NativeTestError.unused
    }
}
