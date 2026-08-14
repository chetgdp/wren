import CoreAudio
import Foundation

protocol AppDaemonManaging: AnyObject, Sendable {
    var onState: (@Sendable (DaemonManager.State) -> Void)? { get set }
    func start()
    func shutdown()
    func retry()
    func restart()
    func resetInvalidSettings()
}

extension DaemonManager: AppDaemonManaging {}

protocol AppSegmentPlaying: AnyObject, Sendable {
    func start()
    func stop()
    func setPaused(_ paused: Bool)
    func setRate(_ rate: Double)
    func setOutputDevice(_ deviceID: AudioDeviceID) async throws
}

extension SegmentPlayer: AppSegmentPlaying {}

protocol StoreDaemonClient: AnyObject, Sendable {
    func meta() async throws -> MetaResponse
    func state() async throws -> DaemonStateResponse
    func voices() async throws -> VoiceListResponse
    func operation(requestID: String) async throws -> OperationResponse
    func activateVoice(
        _ voice: String,
        requestID: String
    ) async throws -> OperationResponse
    func importVoice(
        _ request: ImportVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse
    func updateVoice(
        id: String,
        update: UpdateVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse
    func deleteVoice(
        id: String,
        requestID: String
    ) async throws -> OperationResponse
    func updateSettings(
        _ update: SettingsUpdateRequest,
        requestID: String
    ) async throws -> DaemonStateResponse
    func pause() async throws -> PauseResponse
    func resume() async throws -> PauseResponse
    func stopSpeaking() async throws -> StopResponse
}

final class HTTPStoreDaemonClient: StoreDaemonClient,
    @unchecked Sendable {
    let client: DaemonClient

    init(client: DaemonClient) {
        self.client = client
    }

    func meta() async throws -> MetaResponse {
        let meta = try await client.meta()
        try DaemonClient.validateIdentity(
            meta,
            requiredCapabilities: [
                .stateV2,
                .voiceList,
                .voiceActivate,
                .settingsV2,
                .segmentPlayer,
            ])
        return meta
    }

    func state() async throws -> DaemonStateResponse {
        try await client.state()
    }

    func voices() async throws -> VoiceListResponse {
        try await client.voices()
    }

    func operation(requestID: String) async throws -> OperationResponse {
        try await client.operation(requestID: requestID)
    }

    func activateVoice(
        _ voice: String,
        requestID: String
    ) async throws -> OperationResponse {
        try await client.activateVoice(voice, requestID: requestID)
    }
    func importVoice(
        _ request: ImportVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        try await client.importVoice(request, requestID: requestID)
    }

    func updateVoice(
        id: String,
        update: UpdateVoiceRequest,
        requestID: String
    ) async throws -> OperationResponse {
        try await client.updateVoice(
            id: id,
            update: update,
            requestID: requestID)
    }

    func deleteVoice(
        id: String,
        requestID: String
    ) async throws -> OperationResponse {
        try await client.deleteVoice(id: id, requestID: requestID)
    }


    func updateSettings(
        _ update: SettingsUpdateRequest,
        requestID: String
    ) async throws -> DaemonStateResponse {
        try await client.updateSettings(update, requestID: requestID)
    }

    func pause() async throws -> PauseResponse {
        try await client.pause()
    }

    func resume() async throws -> PauseResponse {
        try await client.resume()
    }

    func stopSpeaking() async throws -> StopResponse {
        try await client.stopSpeaking()
    }
}

struct WrenSession {
    let endpoint: URL
    let manager: AppDaemonManaging
    let client: StoreDaemonClient
    let player: AppSegmentPlaying
    let localLibraryLocation: URL?

    init(
        endpoint: URL,
        manager: AppDaemonManaging,
        client: StoreDaemonClient,
        player: AppSegmentPlaying,
        localLibraryLocation: URL? = nil
    ) {
        self.endpoint = endpoint
        self.manager = manager
        self.client = client
        self.player = player
        self.localLibraryLocation = localLibraryLocation
    }
}

protocol WrenSessionMaking: AnyObject {
    func makeSession(endpoint: URL) -> WrenSession
}

final class WrenSessionFactory: WrenSessionMaking {
    private let paths: WrenPaths
    private let token: String?

    init(paths: WrenPaths, token: String?) {
        self.paths = paths
        self.token = token
    }

    func makeSession(endpoint: URL) -> WrenSession {
        let host = Self.hostString(for: endpoint)
        let daemonClient = DaemonClient(host: host, token: token)
        return WrenSession(
            endpoint: endpoint,
            manager: DaemonManager(
                paths: paths,
                baseURL: endpoint,
                token: token),
            client: HTTPStoreDaemonClient(client: daemonClient),
            player: SegmentPlayer(base: endpoint, token: token),
            localLibraryLocation: paths.voices)
    }

    private static func hostString(for endpoint: URL) -> String {
        guard let host = endpoint.host else {
            return DaemonClient.defaultHost
        }
        guard let port = endpoint.port else { return host }
        return "\(host):\(port)"
    }
}

struct LocalPlayerState: Equatable, Sendable {
    let speakingRate: Double
    let isPaused: Bool
    let outputDeviceUID: String?
}

struct AudioOutputState: Equatable, Sendable {
    let devices: [AudioOutputDevice]
    let desiredUID: String?
    let desiredName: String?
    let effectiveDevice: AudioOutputDevice?
    let fallbackWarning: String?
    let providerError: String?
}

enum PendingAction: Equatable, Sendable {
    case activateVoice(id: String, requestID: String)
    case importVoice(id: String, requestID: String, stagingID: String)
    case renameVoice(id: String, requestID: String)
    case deleteVoice(id: String, requestID: String)
    case setEffects(value: Bool, requestID: String)
    case setPaused(paused: Bool)
    case stopSpeaking
    case retryStartup
    case resetInvalidSettings
    case setOutputDevice(uid: String?)
    case setLaunchAtLogin(enabled: Bool)
    case refresh
    case relaunch(endpoint: URL)
}

struct ActionableError: Equatable, Sendable {
    let code: String
    let message: String
    let detail: String?
    let recoverable: Bool
}

struct ManagerRecoveryState: Equatable, Sendable {
    let canRetry: Bool
    let canResetInvalidSettings: Bool
    let revealLogURL: URL?
}

/// One immutable snapshot for every value rendered by the macOS app.
struct AppState: Equatable, Sendable {
    let endpoint: URL
    let manager: DaemonManager.State?
    let meta: MetaResponse?
    let daemon: DaemonStateResponse?
    let voices: VoiceListResponse?
    let localPlayer: LocalPlayerState
    let pendingAction: PendingAction?
    let stagedImportAvailable: Bool
    let provenLocalLibrary: URL?
    let audioOutput: AudioOutputState
    let loginItem: LoginItemState
    let actionableError: ActionableError?

    var voiceManagement: VoiceManagementState {
        VoiceManagementState(appState: self)
    }

    var managerRecovery: ManagerRecoveryState {
        let ownership = manager?.ownership
        let resettableCodes: Set<String> = [
            "legacy_active_voice_missing",
            "legacy_config_invalid",
            "settings_active_voice_not_ready",
            "settings_invalid",
            "settings_path_unsafe",
            "voice_migration_incomplete",
        ]
        let daemonResettable = daemon?.lastError.map {
            resettableCodes.contains($0.code)
        } ?? false
        let daemonNeedsRestart = daemon.map {
            $0.lifecycle.phase == .degraded
                || $0.lifecycle.phase == .failed
        } ?? false
        let managerCanRetry = ownership != .connected
            && manager?.error?.canRetry == true
        return ManagerRecoveryState(
            canRetry: managerCanRetry
                || (ownership == .managed && daemonNeedsRestart),
            canResetInvalidSettings: ownership == .managed
                && (manager?.error?.canResetInvalidSettings == true
                    || daemonResettable),
            revealLogURL: manager?.logLocation)
    }
}

@MainActor
final class WrenStore {
    nonisolated private static let rateKey = "playerRate"
    nonisolated static let outputUIDKey = "outputDeviceUID"
    nonisolated static let outputNameKey = "outputDeviceName"

    private(set) var state: AppState {
        didSet { onState?(state) }
    }
    var onState: ((AppState) -> Void)?

    private let sessionFactory: WrenSessionMaking
    private let userDefaults: UserDefaults
    private let automaticallyRefresh: Bool
    private let audioDevices: AudioOutputDeviceProviding
    private let loginItem: LoginItemProviding
    private var session: WrenSession
    private var sessionID = UUID()
    private var stateRevision: Int?
    private var voicesRevision: Int?
    private var refreshTimer: Timer?
    private var playerStarted = false
    private var audioGeneration = 0
    private var refreshGeneration: UInt64 = 0
    private var completedRefreshGeneration: UInt64 = 0
    private var refreshCompletionWaiters: [RefreshCompletionWaiter] = []
    private var managerGeneration: UInt64 = 0
    private var pendingOwner: ActionOwner?
    private var errorOwner: ErrorOwner?

    init(
        endpoint: URL,
        sessionFactory: WrenSessionMaking,
        userDefaults: UserDefaults = .standard,
        audioDevices: AudioOutputDeviceProviding =
            CoreAudioOutputDeviceProvider(),
        loginItem: LoginItemProviding = NativeLoginItem(),
        startsRefreshTimer: Bool = true,
        startsSession: Bool = true
    ) {
        self.sessionFactory = sessionFactory
        self.userDefaults = userDefaults
        self.audioDevices = audioDevices
        self.loginItem = loginItem
        automaticallyRefresh = startsRefreshTimer
        session = sessionFactory.makeSession(endpoint: endpoint)
        let savedRate = userDefaults.double(forKey: Self.rateKey)
        let rate = savedRate > 0 ? savedRate : 1.0
        let savedUID = userDefaults.string(forKey: Self.outputUIDKey)
        state = AppState(
            endpoint: endpoint,
            manager: nil,
            meta: nil,
            daemon: nil,
            voices: nil,
            localPlayer: LocalPlayerState(
                speakingRate: rate,
                isPaused: false,
                outputDeviceUID: savedUID),
            pendingAction: nil,
            stagedImportAvailable: false,
            provenLocalLibrary: nil,
            audioOutput: Self.initialAudioOutputState(
                provider: audioDevices,
                userDefaults: userDefaults),
            loginItem: loginItem.refresh(),
            actionableError: nil)
        startObservingAudioDevices()
        if startsSession {
            startCurrentSession()
        }
    }

    func observe(_ observer: @escaping (AppState) -> Void) {
        onState = observer
        observer(state)
    }

    func activateVoice(id: String) async {
        let requestID = UUID().uuidString
        guard let owner = begin(
            .activateVoice(id: id, requestID: requestID)
        ) else { return }
        let expectedInstance = state.meta?.instanceID
        let expectedSession = sessionID
        let client = session.client
        var terminalError: Error?
        do {
            let operation: OperationResponse
            do {
                operation = try await client.activateVoice(
                    id,
                    requestID: requestID)
            } catch {
                operation = try await recoverActivation(
                    voice: id,
                    requestID: requestID,
                    instanceID: expectedInstance,
                    sessionID: expectedSession,
                    client: client,
                    submissionError: error)
            }
            try await awaitOperation(
                operation,
                requestID: requestID,
                instanceID: expectedInstance,
                sessionID: expectedSession,
                client: client)
        } catch {
            terminalError = error
        }
        await reconcileVoiceMutation(
            instanceID: expectedInstance,
            sessionID: expectedSession,
            client: client)
        if expectedSession == sessionID,
           expectedInstance == state.meta?.instanceID,
           let terminalError {
            setError(terminalError, owner: .action(owner))
        }
        end(owner)
    }
    func importVoice(
        wav: URL,
        transcript: URL,
        name: String,
        id: String
    ) async {
        let snapshotsReady = await prepareVoiceManagementSnapshots()
        let requestID = UUID().uuidString.lowercased()
        let stagingID = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard let owner = begin(.importVoice(
            id: id,
            requestID: requestID,
            stagingID: stagingID))
        else { return }
        let expectedInstance = state.meta?.instanceID
        let expectedSession = sessionID
        let client = session.client
        var stage: VoiceImportStage?
        var preserveStageForAmbiguousResult = false
        var didSubmit = false
        var terminalError: Error?
        do {
            guard snapshotsReady else {
                throw unavailableVoiceStateFailure()
            }
            guard VoiceImportStaging.validateID(id) else {
                throw voiceFailure(
                    code: "voice_id_invalid",
                    message: "Voice IDs must use 1-32 lowercase letters, "
                        + "digits, '-' or '_'.",
                    detail: id)
            }
            guard !name.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty, name.count <= 128 else {
                throw voiceFailure(
                    code: "voice_display_name_invalid",
                    message: "Voice display name must contain 1-128 "
                        + "characters.",
                    detail: name)
            }
            guard state.voices?.voices.contains(
                where: { $0.id == id }
            ) != true else {
                throw voiceFailure(
                    code: "voice_id_collision",
                    message: "A voice with that ID already exists.",
                    detail: id)
            }
            guard state.meta?.capabilities.contains(.stagedImport) == true,
                  let library = state.provenLocalLibrary
            else {
                throw unavailableLibraryFailure()
            }
            stage = try VoiceImportStaging.stage(
                wav: wav,
                transcript: transcript,
                library: library,
                stagingID: stagingID)
            let request = ImportVoiceRequest(
                stagingID: stagingID,
                id: id,
                displayName: name.trimmingCharacters(
                    in: .whitespacesAndNewlines))
            let operation: OperationResponse
            didSubmit = true
            do {
                operation = try await client.importVoice(
                    request,
                    requestID: requestID)
            } catch {
                preserveStageForAmbiguousResult = isAmbiguous(error)
                operation = try await recoverMutation(
                    requestID: requestID,
                    instanceID: expectedInstance,
                    sessionID: expectedSession,
                    client: client,
                    submissionError: error
                ) {
                    try await client.importVoice(
                        request,
                        requestID: requestID)
                }
            }
            try await awaitOperation(
                operation,
                requestID: requestID,
                instanceID: expectedInstance,
                sessionID: expectedSession,
                client: client)
        } catch {
            terminalError = error
            if !preserveStageForAmbiguousResult, let stage {
                VoiceImportStaging.cleanup(stage)
            }
        }
        await reconcileVoiceMutation(
            instanceID: expectedInstance,
            sessionID: expectedSession,
            client: client)
        if expectedSession == sessionID,
           let terminalError,
           !didSubmit || expectedInstance == state.meta?.instanceID {
            setError(terminalError, owner: .action(owner))
        }
        end(owner)
    }

    func renameVoice(id: String, name: String) async {
        let snapshotsReady = await prepareVoiceManagementSnapshots()
        let requestID = UUID().uuidString.lowercased()
        guard let owner = begin(
            .renameVoice(id: id, requestID: requestID)
        ) else { return }
        let expectedInstance = state.meta?.instanceID
        let expectedSession = sessionID
        let client = session.client
        var terminalError: Error?
        var didSubmit = false
        do {
            guard snapshotsReady else {
                throw unavailableVoiceStateFailure()
            }
            guard state.stagedImportAvailable else {
                throw unavailableLibraryFailure()
            }
            let update = UpdateVoiceRequest(displayName: name)
            let operation: OperationResponse
            didSubmit = true
            do {
                operation = try await client.updateVoice(
                    id: id,
                    update: update,
                    requestID: requestID)
            } catch {
                operation = try await recoverMutation(
                    requestID: requestID,
                    instanceID: expectedInstance,
                    sessionID: expectedSession,
                    client: client,
                    submissionError: error
                ) {
                    try await client.updateVoice(
                        id: id,
                        update: update,
                        requestID: requestID)
                }
            }
            try await awaitOperation(
                operation,
                requestID: requestID,
                instanceID: expectedInstance,
                sessionID: expectedSession,
                client: client)
        } catch {
            terminalError = error
        }
        await reconcileVoiceMutation(
            instanceID: expectedInstance,
            sessionID: expectedSession,
            client: client)
        if expectedSession == sessionID,
           let terminalError,
           !didSubmit || expectedInstance == state.meta?.instanceID {
            setError(terminalError, owner: .action(owner))
        }
        end(owner)
    }

    func deleteVoice(id: String) async {
        let snapshotsReady = await prepareVoiceManagementSnapshots()
        let requestID = UUID().uuidString.lowercased()
        guard let owner = begin(
            .deleteVoice(id: id, requestID: requestID)
        ) else { return }
        let expectedInstance = state.meta?.instanceID
        let expectedSession = sessionID
        let client = session.client
        var terminalError: Error?
        var didSubmit = false
        do {
            guard snapshotsReady else {
                throw unavailableVoiceStateFailure()
            }
            guard state.daemon?.synthesis.activeVoice != id else {
                throw voiceFailure(
                    code: "active_voice_delete_forbidden",
                    message: "Select another active voice before deleting "
                        + "this voice.",
                    detail: id)
            }
            guard state.stagedImportAvailable else {
                throw unavailableLibraryFailure()
            }
            let operation: OperationResponse
            didSubmit = true
            do {
                operation = try await client.deleteVoice(
                    id: id,
                    requestID: requestID)
            } catch {
                operation = try await recoverMutation(
                    requestID: requestID,
                    instanceID: expectedInstance,
                    sessionID: expectedSession,
                    client: client,
                    submissionError: error
                ) {
                    try await client.deleteVoice(
                        id: id,
                        requestID: requestID)
                }
            }
            try await awaitOperation(
                operation,
                requestID: requestID,
                instanceID: expectedInstance,
                sessionID: expectedSession,
                client: client)
        } catch {
            terminalError = error
        }
        await reconcileVoiceMutation(
            instanceID: expectedInstance,
            sessionID: expectedSession,
            client: client)
        if expectedSession == sessionID,
           let terminalError,
           !didSubmit || expectedInstance == state.meta?.instanceID {
            setError(terminalError, owner: .action(owner))
        }
        end(owner)
    }


    func setEffects(_ enabled: Bool) async {
        let requestID = UUID().uuidString
        guard let owner = begin(
            .setEffects(value: enabled, requestID: requestID)
        ) else { return }
        let expectedInstance = state.meta?.instanceID
        let expectedSession = sessionID
        let client = session.client
        let update = SettingsUpdateRequest(
            effects: enabled,
            defaultSynthesisRate: nil)
        do {
            do {
                let snapshot = try await client.updateSettings(
                    update,
                    requestID: requestID)
                acceptDaemonState(
                    snapshot,
                    instanceID: expectedInstance,
                    sessionID: expectedSession)
            } catch {
                let operation = try await recoverSettings(
                    update: update,
                    requestID: requestID,
                    instanceID: expectedInstance,
                    sessionID: expectedSession,
                    client: client,
                    submissionError: error)
                try await awaitOperation(
                    operation,
                    requestID: requestID,
                    instanceID: expectedInstance,
                    sessionID: expectedSession,
                    client: client)
            }
            guard expectedSession == sessionID else { return }
            await performRefresh(resources: .all)
        } catch {
            if expectedSession == sessionID,
               expectedInstance == state.meta?.instanceID {
                setError(error, owner: .action(owner))
            }
        }
        end(owner)
    }

    func setSpeakingRate(_ rate: Double) {
        let clamped = LocalSpeakingRate.clamped(rate)
        session.player.setRate(clamped)
        userDefaults.set(clamped, forKey: Self.rateKey)
        replaceState(
            localPlayer: LocalPlayerState(
                speakingRate: clamped,
                isPaused: state.localPlayer.isPaused,
                outputDeviceUID: state.localPlayer.outputDeviceUID))
    }

    func setOutputDevice(_ device: AudioOutputDevice?) async {
        guard let owner = begin(
            .setOutputDevice(uid: device?.uid)
        ) else { return }
        if let device {
            userDefaults.set(device.uid, forKey: Self.outputUIDKey)
            userDefaults.set(device.name, forKey: Self.outputNameKey)
        } else {
            userDefaults.removeObject(forKey: Self.outputUIDKey)
            userDefaults.removeObject(forKey: Self.outputNameKey)
        }
        let desiredName = device?.name
        replaceState(
            localPlayer: LocalPlayerState(
                speakingRate: state.localPlayer.speakingRate,
                isPaused: state.localPlayer.isPaused,
                outputDeviceUID: device?.uid),
            audioOutput: AudioOutputState(
                devices: state.audioOutput.devices,
                desiredUID: device?.uid,
                desiredName: desiredName,
                effectiveDevice: state.audioOutput.effectiveDevice,
                fallbackWarning: state.audioOutput.fallbackWarning,
                providerError: nil))
        await reconcileAudioOutput()
        end(owner)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard let owner = begin(
            .setLaunchAtLogin(enabled: enabled)
        ) else { return }
        replaceState(loginItem: loginItem.setEnabled(enabled))
        end(owner)
    }

    func refreshLocalPreferences() async {
        replaceState(loginItem: loginItem.refresh())
        await reconcileAudioOutput()
    }

    func resetInvalidSettings() {
        guard state.managerRecovery.canResetInvalidSettings else {
            setError(ActionableError(
                code: "settings_reset_unavailable",
                message: state.manager?.ownership == .connected
                    ? "Settings reset is unavailable for a connected daemon."
                    : "There are no invalid managed settings to reset.",
                detail: nil,
                recoverable: false))
            return
        }
        guard begin(.resetInvalidSettings) != nil else { return }
        session.manager.resetInvalidSettings()
    }

    func setPaused(_ desired: Bool) async {
        guard let owner = begin(.setPaused(paused: desired)) else {
            return
        }
        let expectedSession = sessionID
        let expectedInstance = state.meta?.instanceID
        let client = session.client
        session.player.setPaused(desired)
        replaceState(
            localPlayer: LocalPlayerState(
                speakingRate: state.localPlayer.speakingRate,
                isPaused: desired,
                outputDeviceUID: state.localPlayer.outputDeviceUID))
        do {
            if desired {
                _ = try await client.pause()
            } else {
                _ = try await client.resume()
            }
            if expectedSession == sessionID,
               expectedInstance == state.meta?.instanceID {
                await performRefresh(resources: .state)
            }
        } catch {
            if expectedSession == sessionID,
               expectedInstance == state.meta?.instanceID {
                setError(error, owner: .action(owner))
            }
        }
        end(owner)
    }

    func stopSpeaking() async {
        guard let owner = begin(.stopSpeaking) else { return }
        let expectedSession = sessionID
        let expectedInstance = state.meta?.instanceID
        let client = session.client
        do {
            _ = try await client.stopSpeaking()
            if expectedSession == sessionID,
               expectedInstance == state.meta?.instanceID {
                await performRefresh(resources: .state)
            }
        } catch {
            if expectedSession == sessionID,
               expectedInstance == state.meta?.instanceID {
                setError(error, owner: .action(owner))
            }
        }
        end(owner)
    }

    func retryStartup() {
        guard state.managerRecovery.canRetry else {
            setError(ActionableError(
                code: "daemon_retry_unavailable",
                message: state.manager?.ownership == .connected
                    ? "The connected daemon must be restarted by its owner."
                    : "There is no managed daemon failure to retry.",
                detail: nil,
                recoverable: false))
            return
        }
        guard begin(.retryStartup) != nil else { return }
        let lifecycle = state.daemon?.lifecycle.phase
        if state.manager?.ownership == .managed,
           lifecycle == .degraded || lifecycle == .failed {
            session.manager.restart()
        } else {
            session.manager.retry()
        }
    }

    func refresh() async {
        guard let owner = begin(.refresh, supersedingRefresh: true) else {
            return
        }
        await performRefresh(resources: .all)
        end(owner)
    }

    /// Deployment endpoint changes replace every endpoint-bound component.
    func relaunch(at endpoint: URL) {
        guard endpoint != state.endpoint else { return }
        let owner = begin(
            .relaunch(endpoint: endpoint),
            supersedingAll: true)
        guard owner != nil else { return }
        let oldSession = session
        let replacement = sessionFactory.makeSession(endpoint: endpoint)

        refreshTimer?.invalidate()
        refreshTimer = nil
        oldSession.manager.shutdown()
        oldSession.player.stop()

        session = replacement
        sessionID = UUID()
        refreshGeneration &+= 1
        finishRefreshGeneration(refreshGeneration)
        pendingOwner = nil
        errorOwner = nil
        playerStarted = false
        stateRevision = nil
        voicesRevision = nil
        state = AppState(
            endpoint: endpoint,
            manager: nil,
            meta: nil,
            daemon: nil,
            voices: nil,
            localPlayer: state.localPlayer,
            pendingAction: nil,
            stagedImportAvailable: false,
            provenLocalLibrary: nil,
            audioOutput: state.audioOutput,
            loginItem: state.loginItem,
            actionableError: nil)
        startCurrentSession()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        session.player.stop()
        session.manager.shutdown()
        audioDevices.stopObserving()
    }

    @discardableResult
    func acceptMeta(_ meta: MetaResponse) -> Bool {
        let priorInstance = state.meta?.instanceID
        let changed = priorInstance != meta.instanceID
        if changed {
            stateRevision = nil
            voicesRevision = nil
            let replacesInstance = priorInstance != nil
            let interruptedOwner = replacesInstance ? pendingOwner : nil
            if replacesInstance {
                pendingOwner = nil
            }
            let library = SharedVoiceLibrary.prove(
                endpoint: state.endpoint,
                manager: state.manager,
                daemon: nil,
                configuredLibrary: session.localLibraryLocation)
            var nextError = state.actionableError
            if priorInstance != nil, let interruptedOwner {
                nextError = ActionableError(
                    code: "daemon_instance_changed",
                    message: "The daemon restarted while reconciling "
                        + "an action.",
                    detail: "The prior operation was not retried.",
                    recoverable: true)
                errorOwner = .action(interruptedOwner)
            }
            state = AppState(
                endpoint: state.endpoint,
                manager: state.manager,
                meta: meta,
                daemon: nil,
                voices: nil,
                localPlayer: state.localPlayer,
                pendingAction: replacesInstance
                    ? nil
                    : state.pendingAction,
                stagedImportAvailable: library != nil
                    && meta.capabilities.contains(.stagedImport),
                provenLocalLibrary: library,
                audioOutput: state.audioOutput,
                loginItem: state.loginItem,
                actionableError: nextError)
            return true
        }
        replaceState(meta: meta)
        return false
    }

    func acceptDaemonState(
        _ snapshot: DaemonStateResponse,
        instanceID: String?,
        sessionID expectedSession: UUID? = nil
    ) {
        if let expectedSession, expectedSession != sessionID { return }
        guard instanceID == state.meta?.instanceID else { return }
        if let revision = stateRevision {
            guard snapshot.revision >= revision else { return }
            if snapshot.revision == revision, var current = state.daemon {
                current.playback = snapshot.playback
                session.player.setPaused(snapshot.playback.paused)
                replaceState(
                    daemon: current,
                    localPlayer: LocalPlayerState(
                        speakingRate: state.localPlayer.speakingRate,
                        isPaused: snapshot.playback.paused,
                        outputDeviceUID:
                            state.localPlayer.outputDeviceUID))
                return
            }
        }
        stateRevision = snapshot.revision
        session.player.setPaused(snapshot.playback.paused)
        let retainedVoices = state.voices.flatMap {
            $0.revision >= snapshot.voicesRevision ? $0 : nil
        }
        replaceState(
            daemon: snapshot,
            voices: .some(retainedVoices),
            localPlayer: LocalPlayerState(
                speakingRate: state.localPlayer.speakingRate,
                isPaused: snapshot.playback.paused,
                outputDeviceUID: state.localPlayer.outputDeviceUID))
    }

    func acceptVoices(
        _ snapshot: VoiceListResponse,
        instanceID: String?,
        sessionID expectedSession: UUID? = nil
    ) {
        if let expectedSession, expectedSession != sessionID { return }
        guard instanceID == state.meta?.instanceID else { return }
        guard snapshot.revision
            >= (state.daemon?.voicesRevision ?? 0) else {
            return
        }
        if let revision = voicesRevision, snapshot.revision <= revision {
            return
        }
        voicesRevision = snapshot.revision
        replaceState(voices: snapshot)
    }

    func reconcileSharedLibraryProof() {
        replaceState()
    }

    private func startCurrentSession() {
        let expectedSession = sessionID
        session.manager.onState = { [weak self] managerState in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == expectedSession else {
                    return
                }
                self.acceptManagerState(managerState)
            }
        }
        session.player.setRate(state.localPlayer.speakingRate)
        session.manager.start()
        Task { @MainActor [weak self] in
            await self?.refreshLocalPreferences()
        }
    }

    private func acceptManagerState(_ manager: DaemonManager.State) {
        managerGeneration &+= 1
        let generation = managerGeneration
        replaceState(manager: manager)
        if let failure = manager.error {
            setError(
                ActionableError(
                    code: String(describing: failure.kind),
                    message: failure.message,
                    detail: manager.logLocation?.path,
                    recoverable: failure.canRetry),
                owner: .manager(
                    sessionID: sessionID,
                    generation: generation))
        } else if manager.phase == .ready {
            clearRecoveredManagerError(generation: generation)
        }
        if manager.phase == .ready || manager.phase == .failed,
           let owner = pendingOwner,
           owner.action == .retryStartup
                || owner.action == .resetInvalidSettings {
            end(owner)
        }
        guard manager.phase == .ready, let meta = manager.meta else {
            return
        }
        acceptMeta(meta)
        if !playerStarted {
            playerStarted = true
            session.player.start()
        }
        startRefreshTimerIfNeeded()
        Task { @MainActor [weak self] in
            await self?.performRefresh(resources: .all)
        }
    }

    private func startRefreshTimerIfNeeded() {
        guard automaticallyRefresh, refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.performRefresh(resources: .state)
            }
        }
    }

    @discardableResult
    private func performRefresh(
        resources: RefreshResources
    ) async -> RefreshOutcome {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        defer { finishRefreshGeneration(generation) }
        let expectedSession = sessionID
        let client = session.client
        do {
            let meta = try await client.meta()
            guard isCurrentRefresh(
                generation,
                sessionID: expectedSession
            ) else { return .superseded }
            acceptMeta(meta)
            clearRecoveredResourceError(
                .meta,
                generation: generation,
                sessionID: expectedSession)
            await refreshResources(
                resources,
                instanceID: meta.instanceID,
                sessionID: expectedSession,
                generation: generation,
                client: client)
            return isCurrentRefresh(
                generation,
                sessionID: expectedSession
            ) ? .completed : .superseded
        } catch {
            guard isCurrentRefresh(
                generation,
                sessionID: expectedSession
            ) else { return .superseded }
            setError(
                error,
                owner: .resource(
                    sessionID: expectedSession,
                    generation: generation,
                    resource: .meta))
            return .completed
        }
    }

    private func refreshResources(
        _ resources: RefreshResources,
        instanceID: String,
        sessionID expectedSession: UUID,
        generation: UInt64,
        client: StoreDaemonClient
    ) async {
        if resources.includesState {
            do {
                let snapshot = try await client.state()
                guard isCurrentRefresh(
                    generation,
                    sessionID: expectedSession
                ) else { return }
                acceptDaemonState(
                    snapshot,
                    instanceID: instanceID,
                    sessionID: expectedSession)
                clearRecoveredResourceError(
                    .state,
                    generation: generation,
                    sessionID: expectedSession)
            } catch {
                guard isCurrentRefresh(
                    generation,
                    sessionID: expectedSession
                ) else { return }
                setError(
                    error,
                    owner: .resource(
                        sessionID: expectedSession,
                        generation: generation,
                        resource: .state))
            }
        }
        if resources.includesVoices {
            do {
                var snapshot = try await client.voices()
                guard isCurrentRefresh(
                    generation,
                    sessionID: expectedSession
                ) else { return }
                if snapshot.revision
                    < (state.daemon?.voicesRevision ?? 0) {
                    snapshot = try await client.voices()
                    guard isCurrentRefresh(
                        generation,
                        sessionID: expectedSession
                    ) else { return }
                }
                acceptVoices(
                    snapshot,
                    instanceID: instanceID,
                    sessionID: expectedSession)
                clearRecoveredResourceError(
                    .voices,
                    generation: generation,
                    sessionID: expectedSession)
            } catch {
                guard isCurrentRefresh(
                    generation,
                    sessionID: expectedSession
                ) else { return }
                setError(
                    error,
                    owner: .resource(
                        sessionID: expectedSession,
                        generation: generation,
                        resource: .voices))
            }
        }
    }

    private func isCurrentRefresh(
        _ generation: UInt64,
        sessionID expectedSession: UUID
    ) -> Bool {
        generation == refreshGeneration && expectedSession == sessionID
    }
    private func prepareVoiceManagementSnapshots() async -> Bool {
        if state.pendingAction != nil {
            return true
        }
        while true {
            let outcome = await performRefresh(resources: .all)
            if outcome == .completed {
                return !hasCurrentResourceFailure
                    && voiceManagementSnapshotsAreReady
            }
            while completedRefreshGeneration < refreshGeneration {
                await awaitRefreshCompletion(refreshGeneration)
            }
            if hasCurrentResourceFailure {
                return false
            }
            if voiceManagementSnapshotsAreReady {
                return true
            }
        }
    }

    private var voiceManagementSnapshotsAreReady: Bool {
        state.meta != nil && state.daemon != nil && state.voices != nil
    }

    private var hasCurrentResourceFailure: Bool {
        guard case .resource(
            let failedSession,
            let failedGeneration,
            _
        ) = errorOwner else { return false }
        return failedSession == sessionID
            && failedGeneration == refreshGeneration
    }

    private func awaitRefreshCompletion(_ generation: UInt64) async {
        guard completedRefreshGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            if completedRefreshGeneration >= generation {
                continuation.resume()
            } else {
                refreshCompletionWaiters.append(RefreshCompletionWaiter(
                    generation: generation,
                    continuation: continuation))
            }
        }
    }

    private func finishRefreshGeneration(_ generation: UInt64) {
        completedRefreshGeneration = max(
            completedRefreshGeneration,
            generation)
        for index in refreshCompletionWaiters.indices.reversed()
            where refreshCompletionWaiters[index].generation
                <= completedRefreshGeneration {
            let waiter = refreshCompletionWaiters.remove(at: index)
            waiter.continuation.resume()
        }
    }

    private func reconcileVoiceMutation(
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient
    ) async {
        guard expectedSession == sessionID else { return }
        await performRefresh(resources: .all)
    }

    private func recoverMutation(
        requestID: String,
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient,
        submissionError: Error,
        resubmit: () async throws -> OperationResponse
    ) async throws -> OperationResponse {
        guard isAmbiguous(submissionError) else { throw submissionError }
        do {
            return try await validatedOperation(
                requestID: requestID,
                instanceID: instanceID,
                sessionID: expectedSession,
                client: client)
        } catch {
            guard isUnknownOperation(error) else { throw error }
        }
        _ = try await revalidateMutationInstance(
            requestID: requestID,
            instanceID: instanceID,
            sessionID: expectedSession,
            client: client)
        do {
            return try await resubmit()
        } catch {
            guard isAmbiguous(error) else { throw error }
            do {
                return try await validatedOperation(
                    requestID: requestID,
                    instanceID: instanceID,
                    sessionID: expectedSession,
                    client: client)
            } catch {
                if isUnknownOperation(error) {
                    throw unknownResult(requestID: requestID)
                }
                throw error
            }
        }
    }

    private func unavailableVoiceStateFailure() -> VoiceManagementFailure {
        voiceFailure(
            code: "voice_state_unavailable",
            message: "Voice changes require current daemon state and voice "
                + "snapshots.",
            detail: nil)
    }

    private func unavailableLibraryFailure() -> VoiceManagementFailure {
        voiceFailure(
            code: "voice_library_mutation_unavailable",
            message: "Voice library changes require staged-import support "
                + "and verified access to the daemon's local voice library.",
            detail: nil)
    }

    private func voiceFailure(
        code: String,
        message: String,
        detail: String?
    ) -> VoiceManagementFailure {
        VoiceManagementFailure(error: ActionableError(
            code: code,
            message: message,
            detail: detail,
            recoverable: true))
    }


    private func recoverActivation(
        voice: String,
        requestID: String,
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient,
        submissionError: Error
    ) async throws -> OperationResponse {
        try await recoverMutation(
            requestID: requestID,
            instanceID: instanceID,
            sessionID: expectedSession,
            client: client,
            submissionError: submissionError
        ) {
            try await client.activateVoice(
                voice,
                requestID: requestID)
        }

    }

    private func recoverSettings(
        update: SettingsUpdateRequest,
        requestID: String,
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient,
        submissionError: Error
    ) async throws -> OperationResponse {
        try await recoverMutation(
            requestID: requestID,
            instanceID: instanceID,
            sessionID: expectedSession,
            client: client,
            submissionError: submissionError
        ) {
            _ = try await client.updateSettings(
                update,
                requestID: requestID)
            return OperationResponse(
                id: requestID,
                kind: "update_settings",
                phase: .succeeded,
                target: nil,
                progress: nil,
                error: nil,
                response: nil)
        }

    }

    private func awaitOperation(
        _ initial: OperationResponse,
        requestID: String,
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient
    ) async throws {
        var operation = initial
        guard operation.id == requestID else {
            throw operationMismatch(
                expected: requestID,
                actual: operation.id)
        }
        while !operation.phase.isTerminal {
            try await Task<Never, Never>.sleep(
                nanoseconds: 250_000_000)
            operation = try await validatedOperation(
                requestID: requestID,
                instanceID: instanceID,
                sessionID: expectedSession,
                client: client)
        }
        if operation.phase == .failed {
            if let error = operation.error {
                throw ActionFailure(detail: error)
            }
            throw ActionFailure(error: ActionableError(
                code: "operation_failed",
                message: "The daemon operation failed.",
                detail: nil,
                recoverable: true))
        }
    }

    private func validatedOperation(
        requestID: String,
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient
    ) async throws -> OperationResponse {
        try await revalidateMutationInstance(
            requestID: requestID,
            instanceID: instanceID,
            sessionID: expectedSession,
            client: client)
        let operation = try await client.operation(requestID: requestID)
        guard expectedSession == sessionID,
              instanceID == state.meta?.instanceID else {
            throw unknownResult(requestID: requestID)
        }
        guard operation.id == requestID else {
            throw operationMismatch(
                expected: requestID,
                actual: operation.id)
        }
        return operation
    }

    private func revalidateMutationInstance(
        requestID: String,
        instanceID: String?,
        sessionID expectedSession: UUID,
        client: StoreDaemonClient
    ) async throws {
        guard expectedSession == sessionID else {
            throw unknownResult(requestID: requestID)
        }
        let meta = try await client.meta()
        guard expectedSession == sessionID else {
            throw unknownResult(requestID: requestID)
        }
        let changed = acceptMeta(meta)
        guard !changed, instanceID == meta.instanceID else {
            await performRefresh(resources: .all)
            throw instanceChanged(requestID: requestID)
        }
    }

    private func begin(
        _ action: PendingAction,
        supersedingRefresh: Bool = false,
        supersedingAll: Bool = false
    ) -> ActionOwner? {
        if let current = state.pendingAction, !supersedingAll {
            guard supersedingRefresh,
                  case .refresh = current,
                  case .refresh = action
            else {
                setError(ActionableError(
                    code: "action_in_progress",
                    message: "Wait for the current action to finish.",
                    detail: nil,
                    recoverable: true))
                return nil
            }
        }
        let owner = ActionOwner(
            token: UUID(),
            sessionID: sessionID,
            action: action)
        if case .action(let failedOwner) = errorOwner,
           failedOwner.action.isSameKind(as: action) {
            errorOwner = nil
            replaceState(
                pendingAction: action,
                actionableError: .some(nil))
        } else {
            replaceState(pendingAction: action)
        }
        pendingOwner = owner
        return owner
    }

    private func end(_ owner: ActionOwner) {
        guard pendingOwner == owner,
              owner.sessionID == sessionID
        else { return }
        pendingOwner = nil
        replaceState(pendingAction: .some(nil))
    }


    private func isAmbiguous(_ error: Error) -> Bool {
        guard case .ambiguousSubmittedMutation = error as? DaemonError else {
            return false
        }
        return true
    }

    private func isUnknownOperation(_ error: Error) -> Bool {
        guard case .management(_, let detail) = error as? DaemonError else {
            return false
        }
        return detail.code == "operation_result_unknown"
    }

    private func unknownResult(requestID: String) -> ActionFailure {
        ActionFailure(error: ActionableError(
            code: "operation_result_unknown",
            message: "The result of operation \(requestID) is unknown.",
            detail: nil,
            recoverable: true))
    }

    private func operationMismatch(
        expected: String,
        actual: String
    ) -> ActionFailure {
        ActionFailure(error: ActionableError(
            code: "operation_id_mismatch",
            message: "The daemon returned an operation for a different "
                + "request.",
            detail: "Expected \(expected), received \(actual).",
            recoverable: true))
    }

    private func instanceChanged(requestID: String) -> ActionFailure {
        ActionFailure(error: ActionableError(
            code: "daemon_instance_changed",
            message: "The daemon restarted while reconciling an action.",
            detail: "Operation \(requestID) was not sent to the new daemon.",
            recoverable: true))
    }

    private static func initialAudioOutputState(
        provider: AudioOutputDeviceProviding,
        userDefaults: UserDefaults
    ) -> AudioOutputState {
        let desiredUID = userDefaults.string(forKey: outputUIDKey)
        let desiredName = userDefaults.string(forKey: outputNameKey)
        do {
            let snapshot = try provider.snapshot()
            return AudioOutputState(
                devices: snapshot.devices,
                desiredUID: desiredUID,
                desiredName: desiredName,
                effectiveDevice: nil,
                fallbackWarning: nil,
                providerError: nil)
        } catch {
            return AudioOutputState(
                devices: [],
                desiredUID: desiredUID,
                desiredName: desiredName,
                effectiveDevice: nil,
                fallbackWarning: nil,
                providerError: String(describing: error))
        }
    }

    private func startObservingAudioDevices() {
        do {
            try audioDevices.startObserving { [weak self] change in
                Task { @MainActor [weak self] in
                    await self?.handleAudioDeviceChange(change)
                }
            }
        } catch {
            replaceState(audioOutput: AudioOutputState(
                devices: state.audioOutput.devices,
                desiredUID: state.audioOutput.desiredUID,
                desiredName: state.audioOutput.desiredName,
                effectiveDevice: state.audioOutput.effectiveDevice,
                fallbackWarning: state.audioOutput.fallbackWarning,
                providerError: String(describing: error)))
        }
    }

    private func handleAudioDeviceChange(
        _ change: AudioOutputDeviceChange
    ) async {
        if case .defaultOutput = change,
           let desiredUID = state.audioOutput.desiredUID,
           state.audioOutput.effectiveDevice?.uid == desiredUID {
            refreshAudioDeviceList()
            return
        }
        await reconcileAudioOutput()
    }

    private func refreshAudioDeviceList() {
        do {
            let snapshot = try audioDevices.snapshot()
            replaceState(audioOutput: AudioOutputState(
                devices: snapshot.devices,
                desiredUID: state.audioOutput.desiredUID,
                desiredName: state.audioOutput.desiredName,
                effectiveDevice: state.audioOutput.effectiveDevice,
                fallbackWarning: state.audioOutput.fallbackWarning,
                providerError: nil))
        } catch {
            replaceState(audioOutput: AudioOutputState(
                devices: state.audioOutput.devices,
                desiredUID: state.audioOutput.desiredUID,
                desiredName: state.audioOutput.desiredName,
                effectiveDevice: state.audioOutput.effectiveDevice,
                fallbackWarning: state.audioOutput.fallbackWarning,
                providerError: String(describing: error)))
        }
    }

    private func reconcileAudioOutput() async {
        audioGeneration += 1
        let generation = audioGeneration
        let snapshot: AudioOutputDeviceSnapshot
        do {
            snapshot = try audioDevices.snapshot()
        } catch {
            guard generation == audioGeneration else { return }
            replaceState(audioOutput: AudioOutputState(
                devices: state.audioOutput.devices,
                desiredUID: state.audioOutput.desiredUID,
                desiredName: state.audioOutput.desiredName,
                effectiveDevice: state.audioOutput.effectiveDevice,
                fallbackWarning: state.audioOutput.fallbackWarning,
                providerError: String(describing: error)))
            return
        }

        let desiredUID = state.audioOutput.desiredUID
        let savedName = state.audioOutput.desiredName
        var fallbackWarning: String?
        var providerError: String?
        if let desiredUID {
            do {
                if let desired = try audioDevices.resolve(uid: desiredUID) {
                    do {
                        try await session.player.setOutputDevice(
                            desired.objectID)
                        guard generation == audioGeneration else { return }
                        userDefaults.set(
                            desired.device.name,
                            forKey: Self.outputNameKey)
                        replaceState(audioOutput: AudioOutputState(
                            devices: snapshot.devices,
                            desiredUID: desiredUID,
                            desiredName: desired.device.name,
                            effectiveDevice: desired.device,
                            fallbackWarning: nil,
                            providerError: nil))
                        return
                    } catch {
                        fallbackWarning = fallbackMessage(
                            name: savedName ?? desired.device.name,
                            defaultName: snapshot.defaultDevice.device.name,
                            reason: String(describing: error))
                    }
                } else {
                    fallbackWarning = fallbackMessage(
                        name: savedName ?? desiredUID,
                        defaultName: snapshot.defaultDevice.device.name,
                        reason: "The selected device is disconnected.")
                }
            } catch {
                let detail = String(describing: error)
                providerError = detail
                fallbackWarning = fallbackMessage(
                    name: savedName ?? desiredUID,
                    defaultName: snapshot.defaultDevice.device.name,
                    reason: detail)
            }
        }

        do {
            try await session.player.setOutputDevice(
                snapshot.defaultDevice.objectID)
            guard generation == audioGeneration else { return }
            replaceState(audioOutput: AudioOutputState(
                devices: snapshot.devices,
                desiredUID: desiredUID,
                desiredName: savedName,
                effectiveDevice: snapshot.defaultDevice.device,
                fallbackWarning: fallbackWarning,
                providerError: providerError))
        } catch {
            guard generation == audioGeneration else { return }
            let routeError = String(describing: error)
            replaceState(audioOutput: AudioOutputState(
                devices: snapshot.devices,
                desiredUID: desiredUID,
                desiredName: savedName,
                effectiveDevice: nil,
                fallbackWarning: fallbackWarning,
                providerError: providerError.map {
                    "\($0) Default fallback also failed: \(routeError)"
                } ?? routeError))
        }
    }

    private func fallbackMessage(
        name: String,
        defaultName: String,
        reason: String
    ) -> String {
        "\(name) is unavailable; playing through System Default "
            + "(\(defaultName)). \(reason)"
    }

    private func setError(
        _ error: Error,
        owner: ErrorOwner = .unowned
    ) {
        if let failure = error as? ActionFailure {
            setError(failure.error, owner: owner)
            return
        }
        if let failure = error as? VoiceManagementFailure {
            setError(failure.error, owner: owner)
            return
        }
        if let daemonError = error as? DaemonError {
            let actionable: ActionableError
            switch daemonError {
            case .management(_, let detail):
                actionable = actionError(detail)
            case .authorization(_, let detail):
                actionable = detail.map(actionError)
                    ?? ActionableError(
                        code: "authorization",
                        message: "Daemon authorization failed.",
                        detail: nil,
                        recoverable: false)
            case .originAccess(_, let detail):
                actionable = detail.map(actionError)
                    ?? ActionableError(
                        code: "origin_access",
                        message: "The daemon rejected this request origin.",
                        detail: nil,
                        recoverable: false)
            case .identity(let service):
                actionable = ActionableError(
                    code: "endpoint_identity",
                    message: "The endpoint is \(service), not Wren.",
                    detail: nil,
                    recoverable: false)
            case .identityMetadata(let description):
                actionable = ActionableError(
                    code: "endpoint_identity",
                    message: "The endpoint returned invalid Wren identity.",
                    detail: description,
                    recoverable: false)
            case .compatibility(let version, let missing):
                let names = missing.map(\.rawValue).joined(separator: ", ")
                actionable = ActionableError(
                    code: "incompatible_protocol",
                    message: "Daemon protocol \(version) is incompatible.",
                    detail: names.isEmpty ? nil : names,
                    recoverable: false)
            case .transportRefused(let host), .notRunning(let host):
                actionable = ActionableError(
                    code: "connection_refused",
                    message: "Connection to \(host) was refused.",
                    detail: nil,
                    recoverable: true)
            case .transport(let detail):
                actionable = ActionableError(
                    code: "transport_failure",
                    message: "The daemon connection failed.",
                    detail: detail,
                    recoverable: true)
            case .ambiguousSubmittedMutation(let requestID, let detail):
                actionable = ActionableError(
                    code: "operation_result_unknown",
                    message: "The result of operation \(requestID) is unknown.",
                    detail: detail,
                    recoverable: true)
            case .invalidDecoding(let detail):
                actionable = ActionableError(
                    code: "invalid_response",
                    message: "The daemon response could not be decoded.",
                    detail: detail,
                    recoverable: true)
            case .http(let status, let message):
                actionable = ActionableError(
                    code: "http_\(status)",
                    message: message ?? "The daemon request failed.",
                    detail: nil,
                    recoverable: true)
            case .invalidResponse:
                actionable = ActionableError(
                    code: "invalid_response",
                    message: "The daemon sent an invalid HTTP response.",
                    detail: nil,
                    recoverable: true)
            }
            setError(actionable, owner: owner)
            return
        }
        setError(
            ActionableError(
                code: "network_failure",
                message: String(describing: error),
                detail: nil,
                recoverable: true),
            owner: owner)
    }

    private func actionError(
        _ detail: ManagementErrorDetail
    ) -> ActionableError {
        ActionableError(
            code: detail.code,
            message: detail.message,
            detail: renderManagementDetail(detail.detail),
            recoverable: detail.recoverable ?? false)
    }

    private func setError(
        _ error: ActionableError,
        owner: ErrorOwner = .unowned
    ) {
        errorOwner = owner
        replaceState(actionableError: error)
    }

    private func clearRecoveredManagerError(generation: UInt64) {
        guard case .manager(
            let expectedSession,
            let failedGeneration
        ) = errorOwner,
        expectedSession == sessionID,
        failedGeneration < generation else { return }
        errorOwner = nil
        replaceState(actionableError: .some(nil))
    }

    private func clearRecoveredResourceError(
        _ resource: ErrorResource,
        generation: UInt64,
        sessionID recoveredSession: UUID
    ) {
        guard case .resource(
            let expectedSession,
            let failedGeneration,
            let failedResource
        ) = errorOwner,
        expectedSession == recoveredSession,
        failedGeneration <= generation,
        failedResource == resource else { return }
        errorOwner = nil
        replaceState(actionableError: .some(nil))
    }

    func dismissActionableError() {
        errorOwner = nil
        replaceState(actionableError: .some(nil))
    }


    private func replaceState(
        manager: DaemonManager.State? = nil,
        meta: MetaResponse? = nil,
        daemon: DaemonStateResponse? = nil,
        voices: VoiceListResponse?? = nil,
        localPlayer: LocalPlayerState? = nil,
        pendingAction: PendingAction?? = nil,
        audioOutput: AudioOutputState? = nil,
        loginItem: LoginItemState? = nil,
        actionableError: ActionableError?? = nil
    ) {
        let nextManager = manager ?? state.manager
        let nextMeta = meta ?? state.meta
        let nextDaemon = daemon ?? state.daemon
        let library = SharedVoiceLibrary.prove(
            endpoint: state.endpoint,
            manager: nextManager,
            daemon: nextDaemon,
            configuredLibrary: session.localLibraryLocation)
        state = AppState(
            endpoint: state.endpoint,
            manager: nextManager,
            meta: nextMeta,
            daemon: nextDaemon,
            voices: voices ?? state.voices,
            localPlayer: localPlayer ?? state.localPlayer,
            pendingAction: pendingAction ?? state.pendingAction,
            stagedImportAvailable: library != nil
                && nextMeta?.capabilities.contains(.stagedImport) == true,
            provenLocalLibrary: library,
            audioOutput: audioOutput ?? state.audioOutput,
            loginItem: loginItem ?? state.loginItem,
            actionableError: actionableError ?? state.actionableError)
    }
}

private struct ActionFailure: Error {
    let error: ActionableError

    init(error: ActionableError) {
        self.error = error
    }

    init(detail: ManagementErrorDetail) {
        error = ActionableError(
            code: detail.code,
            message: detail.message,
            detail: renderManagementDetail(detail.detail),
            recoverable: detail.recoverable ?? false)
    }
}

private struct ActionOwner: Equatable {
    let token: UUID
    let sessionID: UUID
    let action: PendingAction
}

private enum ErrorOwner: Equatable {
    case unowned
    case action(ActionOwner)
    case manager(sessionID: UUID, generation: UInt64)
    case resource(
        sessionID: UUID,
        generation: UInt64,
        resource: ErrorResource)
}

private enum ErrorResource: Equatable {
    case meta
    case state
    case voices
}

private enum RefreshOutcome: Equatable {
    case completed
    case superseded
}

private struct RefreshCompletionWaiter {
    let generation: UInt64
    let continuation: CheckedContinuation<Void, Never>
}

private enum RefreshResources {
    case state
    case all

    var includesState: Bool { true }
    var includesVoices: Bool { self == .all }
}

private extension PendingAction {
    func isSameKind(as other: PendingAction) -> Bool {
        switch (self, other) {
        case (.activateVoice, .activateVoice),
             (.importVoice, .importVoice),
             (.renameVoice, .renameVoice),
             (.deleteVoice, .deleteVoice),
             (.setEffects, .setEffects),
             (.setPaused, .setPaused),
             (.stopSpeaking, .stopSpeaking),
             (.retryStartup, .retryStartup),
             (.resetInvalidSettings, .resetInvalidSettings),
             (.setOutputDevice, .setOutputDevice),
             (.setLaunchAtLogin, .setLaunchAtLogin),
             (.refresh, .refresh),
             (.relaunch, .relaunch):
            return true
        default:
            return false
        }
    }
}

private func renderManagementDetail(_ detail: JSONValue?) -> String? {
    guard let detail else { return nil }
    if case .string(let value) = detail { return value }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(detail) else {
        return String(describing: detail)
    }
    return String(data: data, encoding: .utf8)
}
