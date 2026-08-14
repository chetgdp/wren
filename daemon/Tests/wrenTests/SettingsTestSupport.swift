import Foundation
@testable import wren

struct SettingsStateFixture {
    var endpoint = URL(string: "http://127.0.0.1:8765")!
    var profiles = [VoiceProfile(
        id: "c3po",
        displayName: "C-3PO",
        status: .ready,
        issues: [])]
    var activeVoice: String? = "c3po"
    var pendingAction: PendingAction?
    var provenLibrary: URL? = URL(fileURLWithPath: "/tmp/voices")
    var stagedImportAvailable = true
    var includeVoices = true
    var includeDaemon = true
    var includeMeta = true
    var managerPhase: DaemonManager.Phase? = .ready
    var ownership: DaemonManager.Ownership? = .managed
    var managerFailure: DaemonManager.Failure?
    var daemonError: ManagementErrorDetail?
    var actionableError: ActionableError?
    var daemonPhase: DaemonLifecyclePhase = .ready
    var daemonMessage: String?
    var operation: OperationResponse?
    var playback = PlaybackState(
        pending: 0,
        speaking: false,
        paused: false)
    var speakingRate = 1.0
    var localPaused = false
    var loginItem = LoginItemState(
        isAvailable: true,
        isEnabled: false,
        error: nil)
    var capabilities: [DaemonCapability] = [
        .stateV2,
        .voiceList,
        .voiceActivate,
        .settingsV2,
        .stagedImport,
        .segmentPlayer
    ]
    var audioOutput = AudioOutputState(
        devices: [AudioOutputDevice(
            uid: "system",
            name: "MacBook Speakers")],
        desiredUID: nil,
        desiredName: nil,
        effectiveDevice: AudioOutputDevice(
            uid: "system",
            name: "MacBook Speakers"),
        fallbackWarning: nil,
        providerError: nil)

    func makeState() -> AppState {
        let meta = includeMeta ? MetaResponse(
            service: "wren",
            protocolVersion: 2,
            instanceID: "settings-tests",
            startedAt: "2026-08-11T00:00:00Z",
            capabilities: capabilities) : nil
        let manager = managerPhase.map {
            DaemonManager.State(
                phase: $0,
                ownership: ownership,
                endpoint: endpoint,
                error: managerFailure,
                logLocation: ownership == .managed
                    ? URL(fileURLWithPath: "/tmp/wren/wren.log")
                    : nil,
                libraryLocation: ownership == .managed
                    ? provenLibrary
                    : nil,
                meta: meta)
        }
        let daemon = includeDaemon ? DaemonStateResponse(
            revision: 4,
            voicesRevision: 7,
            lifecycle: DaemonLifecycle(
                phase: daemonError == nil
                    ? daemonPhase
                    : .failed,
                message: daemonError?.message ?? daemonMessage),
            synthesis: SynthesisState(
                ready: daemonError == nil,
                activeVoice: activeVoice,
                effects: false,
                defaultSynthesisRate: 1,
                backend: "qwentts",
                model: "Qwen3-TTS-0.6B",
                host: "127.0.0.1",
                port: 8765,
                voicesDirectory: "/tmp/voices"),
            operation: operation,
            playback: playback,
            lastError: daemonError) : nil
        return AppState(
            endpoint: endpoint,
            manager: manager,
            meta: meta,
            daemon: daemon,
            voices: includeVoices
                ? VoiceListResponse(revision: 7, voices: profiles)
                : nil,
            localPlayer: LocalPlayerState(
                speakingRate: speakingRate,
                isPaused: localPaused,
                outputDeviceUID: audioOutput.desiredUID),
            pendingAction: pendingAction,
            stagedImportAvailable: stagedImportAvailable,
            provenLocalLibrary: provenLibrary,
            audioOutput: audioOutput,
            loginItem: loginItem,
            actionableError: actionableError)
    }
}

func settingsProfile(
    id: String,
    name: String,
    status: VoiceStatus,
    issues: [VoiceIssue] = []
) -> VoiceProfile {
    VoiceProfile(
        id: id,
        displayName: name,
        status: status,
        issues: issues)
}
