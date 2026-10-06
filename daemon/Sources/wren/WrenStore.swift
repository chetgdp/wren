import Foundation

enum ConnectionStatus: Equatable, Sendable {
    case connecting
    case connected
    case unreachable(String)
}

struct AudioOutputState: Equatable, Sendable {
    var devices: [AudioOutputDevice]
    var desiredUID: String?
    var desiredName: String?
    var effectiveDevice: AudioOutputDevice?
    var providerError: String?
}

struct LocalPlayerState: Equatable, Sendable {
    var speakingRate: Double
    var isPaused: Bool
}

struct AppState: Equatable, Sendable {
    var host: String
    var status: ConnectionStatus
    var channel: String
    var voices: [VoiceProfile]
    var activeVoice: String?
    var activeClient: ClientInfo?
    var effects: Bool
    var defaultRate: Double
    var localPlayer: LocalPlayerState
    var audioOutput: AudioOutputState
    var loginItem: LoginItemState
    /// Last failed user action, shown in Settings so failures are not
    /// silent. Cleared by the next successful action.
    var lastError: String?

    var isPlayingHere: Bool {
        activeClient?.channel == channel
    }
}

@MainActor
final class WrenStore {
    nonisolated static let rateKey = "playerRate"
    nonisolated static let outputUIDKey = "outputDeviceUID"
    nonisolated static let outputNameKey = "outputDeviceName"

    private(set) var state: AppState {
        didSet {
            if state != oldValue { onState?(state) }
        }
    }
    private var onState: (@MainActor (AppState) -> Void)?

    private(set) var client: DaemonClient
    private var player: SegmentPlayer?
    private let activityMonitor = ActivityMonitor()
    private let endpoint: EndpointPersisting
    private let audioDevices: AudioOutputDeviceProviding
    private let loginItem: LoginItemProviding
    private let userDefaults: UserDefaults
    private let hostname: String
    private let transport: DaemonClient.Transport?
    private let runsServices: Bool

    private var pollTask: Task<Void, Never>?

    /// - Parameter runsServices: false in tests so no poll loop, audio
    ///   player, or HID monitor starts; tests drive `pollState` directly.
    init(
        endpoint: EndpointPersisting = SystemEndpointStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        audioDevices: AudioOutputDeviceProviding =
            CoreAudioOutputDeviceProvider(),
        loginItem: LoginItemProviding = NativeLoginItem(),
        hostname: String = ClientChannel.currentHostname(),
        transport: DaemonClient.Transport? = nil,
        runsServices: Bool = true
    ) {
        self.endpoint = endpoint
        self.userDefaults = userDefaults
        self.audioDevices = audioDevices
        self.loginItem = loginItem
        self.hostname = hostname
        self.transport = transport
        self.runsServices = runsServices

        let host = Endpoint.resolveHost(
            flag: nil,
            environment: environment,
            saved: endpoint.savedHost
        )
        self.client = Self.makeClient(host: host, transport: transport)

        let rate = userDefaults.double(forKey: Self.rateKey)
        let initialRate = rate > 0 ? LocalSpeakingRate.clamped(rate) : 1.0

        self.state = AppState(
            host: host,
            status: .connecting,
            channel: ClientChannel.defaultChannel(hostname: hostname),
            voices: [],
            activeVoice: nil,
            activeClient: nil,
            effects: false,
            defaultRate: 1.0,
            localPlayer: LocalPlayerState(
                speakingRate: initialRate,
                isPaused: false
            ),
            audioOutput: Self.resolveAudioOutput(
                provider: audioDevices,
                userDefaults: userDefaults
            ),
            loginItem: loginItem.refresh()
        )

        guard runsServices else { return }
        setupActivityMonitor()
        setupAudioObserving()
        startMonitoring()
    }

    private static func makeClient(
        host: String,
        transport: DaemonClient.Transport?
    ) -> DaemonClient {
        if let transport {
            return DaemonClient(host: host, transport: transport)
        }
        return DaemonClient(host: host)
    }

    func observe(_ observer: @escaping @MainActor (AppState) -> Void) {
        onState = observer
        observer(state)
    }

    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        activityMonitor.stop()
        audioDevices.stopObserving()
        player?.stop()
        player = nil
    }

    private func startMonitoring() {
        setupPlayer()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var delay: TimeInterval = 1.0
            while !Task.isCancelled {
                guard let self else { break }
                let ok = await self.pollState()
                delay = ok ? 2.0 : min(delay * 1.5, 15.0)
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
        }
    }

    private func setupPlayer() {
        player?.stop()
        player = nil
        guard let url = URL(string: "http://\(state.host)") else { return }
        let newPlayer = SegmentPlayer(base: url, channel: state.channel)
        newPlayer.setRate(state.localPlayer.speakingRate)
        player = newPlayer
        state.localPlayer.isPaused = false
        newPlayer.start()
        // The saved device must apply at launch too, not only when the
        // user picks it from the menu.
        if let uid = state.audioOutput.desiredUID,
           let resolved = try? audioDevices.resolve(uid: uid) {
            Task { try? await newPlayer.setOutputDevice(resolved.objectID) }
        }
    }

    private func setupActivityMonitor() {
        activityMonitor.onActivityDetected = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.claimIfNeeded()
            }
        }
        activityMonitor.start()
    }

    private func setupAudioObserving() {
        try? audioDevices.startObserving { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioOutput()
            }
        }
    }

    func refreshAudioOutput() {
        state.audioOutput = Self.resolveAudioOutput(
            provider: audioDevices,
            userDefaults: userDefaults
        )
    }

    // MARK: Server state

    /// Applies a /state body in one assignment so observers render once.
    private func apply(_ res: DaemonStateResponse) {
        var next = state
        next.status = .connected
        next.voices = res.voices ?? next.voices
        next.activeVoice = res.activeVoice
        next.activeClient = res.activeClient
        next.effects = res.effects ?? next.effects
        next.defaultRate = res.defaultRate ?? next.defaultRate
        state = next
    }

    @discardableResult
    func pollState() async -> Bool {
        let wasConnected = state.status == .connected
        do {
            apply(try await client.state())
        } catch {
            state.status = .unreachable(String(describing: error))
            return false
        }
        // Launch and every reconnect count as "the user is here": a fresh
        // client should not stay silent until the next keystroke.
        if !wasConnected { await claimIfNeeded() }
        return true
    }

    func updateEndpoint(host rawHost: String) {
        let host = Endpoint.normalize(rawHost).isEmpty
            ? Endpoint.defaultHost
            : Endpoint.normalize(rawHost)
        endpoint.savedHost = host

        client = Self.makeClient(host: host, transport: transport)
        var next = state
        next.host = host
        next.status = .connecting
        next.activeClient = nil
        next.lastError = nil
        state = next
        // The poll loop claims once the new server answers.
        if runsServices { startMonitoring() }
    }

    /// Claims only when another client (or nobody) is active, so constant
    /// typing on the active Mac never generates traffic.
    func claimIfNeeded() async {
        guard state.activeClient?.channel != state.channel else { return }
        await claimActive()
    }

    func claimActive() async {
        await perform {
            _ = try await self.client.claimActive(
                channel: self.state.channel,
                label: self.hostname
            )
            self.state.activeClient = ClientInfo(
                channel: self.state.channel,
                label: self.hostname
            )
        }
    }

    func activateVoice(id: String) async {
        await perform {
            self.apply(try await self.client.activateVoice(id))
        }
    }

    func setEffects(_ enabled: Bool) async {
        await perform {
            self.apply(try await self.client.updateSettings(
                SettingsUpdateRequest(effects: enabled, defaultRate: nil)
            ))
        }
    }

    func renameVoice(id: String, displayName: String) async {
        await perform {
            _ = try await self.client.renameVoice(
                id: id,
                displayName: displayName
            )
            await self.pollState()
        }
    }

    func deleteVoice(id: String) async {
        await perform {
            _ = try await self.client.deleteVoice(id: id)
            await self.pollState()
        }
    }

    func addVoice(
        id: String,
        name: String,
        audioURL: URL,
        transcript: String
    ) async -> Bool {
        await perform {
            _ = try await self.client.addVoice(
                id: id,
                name: name,
                audioURL: audioURL,
                transcript: transcript
            )
            await self.pollState()
        }
    }

    /// Runs one user action, recording its failure for display.
    @discardableResult
    private func perform(
        _ body: @MainActor () async throws -> Void
    ) async -> Bool {
        do {
            try await body()
            state.lastError = nil
            return true
        } catch {
            state.lastError = String(describing: error)
            return false
        }
    }

    // MARK: Local playback

    func setSpeakingRate(_ rate: Double) {
        let clamped = LocalSpeakingRate.clamped(rate)
        player?.setRate(clamped)
        userDefaults.set(clamped, forKey: Self.rateKey)
        state.localPlayer.speakingRate = clamped
    }

    /// Pauses this Mac's channel: locally at once, then on the server so
    /// synthesis for this channel stops advancing too.
    func setPaused(_ paused: Bool) async {
        player?.setPaused(paused)
        state.localPlayer.isPaused = paused
        await perform {
            if paused {
                _ = try await self.client.pause(channel: self.state.channel)
            } else {
                _ = try await self.client.resume(channel: self.state.channel)
            }
        }
    }

    func stopSpeaking() async {
        await perform {
            _ = try await self.client.stop(channel: self.state.channel)
        }
    }

    func setOutputDevice(_ device: AudioOutputDevice?) async {
        if let device {
            userDefaults.set(device.uid, forKey: Self.outputUIDKey)
            userDefaults.set(device.name, forKey: Self.outputNameKey)
            if let resolved = try? audioDevices.resolve(uid: device.uid) {
                try? await player?.setOutputDevice(resolved.objectID)
            }
        } else {
            userDefaults.removeObject(forKey: Self.outputUIDKey)
            userDefaults.removeObject(forKey: Self.outputNameKey)
            if let snapshot = try? audioDevices.snapshot() {
                try? await player?.setOutputDevice(
                    snapshot.defaultDevice.objectID
                )
            }
        }
        refreshAudioOutput()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        state.loginItem = loginItem.setEnabled(enabled)
    }

    static func resolveAudioOutput(
        provider: AudioOutputDeviceProviding,
        userDefaults: UserDefaults
    ) -> AudioOutputState {
        let desiredUID = userDefaults.string(forKey: outputUIDKey)
        let desiredName = userDefaults.string(forKey: outputNameKey)
        do {
            let snapshot = try provider.snapshot()
            let effective = snapshot.devices.first { $0.uid == desiredUID }
                ?? snapshot.defaultDevice.device
            return AudioOutputState(
                devices: snapshot.devices,
                desiredUID: desiredUID,
                desiredName: desiredName,
                effectiveDevice: effective,
                providerError: nil
            )
        } catch {
            return AudioOutputState(
                devices: [],
                desiredUID: desiredUID,
                desiredName: desiredName,
                effectiveDevice: nil,
                providerError: error.localizedDescription
            )
        }
    }
}
