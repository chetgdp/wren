import Combine
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
    var localPlayer: LocalPlayerState
    var audioOutput: AudioOutputState
    var loginItem: LoginItemState
    var localServer: LocalServerState
    /// Last failed user action, shown in Settings so failures are not
    /// silent. Cleared by the next successful action.
    var lastError: String?

    var isPlayingHere: Bool {
        activeClient?.channel == channel
    }
}

@MainActor
final class WrenStore: ObservableObject {
    nonisolated static let rateKey = "playerRate"
    nonisolated static let outputUIDKey = "outputDeviceUID"
    nonisolated static let outputNameKey = "outputDeviceName"

    struct Dependencies {
        var client: DaemonClient
        var defaults: UserDefaults = .standard
        var clock: () -> Date = Date.init
        var endpoint: EndpointPersisting = SystemEndpointStore()
        var audioDevices: AudioOutputDeviceProviding =
            CoreAudioOutputDeviceProvider()
        var loginItem: LoginItemProviding = NativeLoginItem()
        var hostname: String = ClientChannel.currentHostname()
        var runsServices: Bool = true
        var makePlayer: @MainActor (URL, String) -> SegmentPlayer = {
            SegmentPlayer(base: $0, channel: $1)
        }

        static var live: Dependencies {
            let host = Endpoint.resolveHost(
                flag: nil,
                environment: ProcessInfo.processInfo.environment,
                saved: SystemEndpointStore().savedHost
            )
            return Dependencies(client: DaemonClient(host: host))
        }
    }

    @Published private(set) var state: AppState {
        didSet {
            if state != oldValue { onState?(state) }
        }
    }

    private var onState: (@MainActor (AppState) -> Void)?
    private var dependencies: Dependencies

    private(set) var client: DaemonClient {
        get { dependencies.client }
        set { dependencies.client = newValue }
    }

    private var player: SegmentPlayer?
    private let activityMonitor = ActivityMonitor()
    private var pollTask: Task<Void, Never>?
    private var activeGeneration: UInt = 0
    private var pendingEffects: Bool?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies

        let host = dependencies.client.host
        let defaults = dependencies.defaults
        let rate = defaults.double(forKey: Self.rateKey)
        let initialRate = rate > 0 ? LocalSpeakingRate.clamped(rate) : 1.0

        self.state = AppState(
            host: host,
            status: .connecting,
            channel: ClientChannel.defaultChannel(
                hostname: dependencies.hostname
            ),
            voices: [],
            activeVoice: nil,
            activeClient: nil,
            effects: false,
            localPlayer: LocalPlayerState(
                speakingRate: initialRate,
                isPaused: false
            ),
            audioOutput: Self.resolveAudioOutput(
                provider: dependencies.audioDevices,
                userDefaults: defaults
            ),
            loginItem: dependencies.loginItem.refresh(),
            localServer: LocalServerState(
                isEnabled: true,
                status: .disabled
            )
        )

        guard dependencies.runsServices else { return }
        setupActivityMonitor()
        setupAudioObserving()
        startMonitoring()
    }

    /// Backwards-compatible convenience initializer.
    convenience init(
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
        let host = Endpoint.resolveHost(
            flag: nil,
            environment: environment,
            saved: endpoint.savedHost
        )
        let client = DaemonClient(host: host, transport: transport ?? {
            try await URLSession.shared.data(for: $0)
        })
        let deps = Dependencies(
            client: client,
            defaults: userDefaults,
            clock: Date.init,
            endpoint: endpoint,
            audioDevices: audioDevices,
            loginItem: loginItem,
            hostname: hostname,
            runsServices: runsServices
        )
        self.init(dependencies: deps)
    }

    func observe(_ observer: @escaping @MainActor (AppState) -> Void) {
        onState = observer
        observer(state)
    }

    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        activityMonitor.stop()
        dependencies.audioDevices.stopObserving()
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
        let newPlayer = dependencies.makePlayer(url, state.channel)
        newPlayer.setRate(state.localPlayer.speakingRate)
        player = newPlayer
        state.localPlayer.isPaused = false
        Task { [weak self] in
            await self?.flushOwnChannel(for: newPlayer)
            guard let self, self.player === newPlayer else { return }
            newPlayer.start()
        }
        // The saved device must apply at launch too, not only when the
        // user picks it from the menu.
        if let uid = state.audioOutput.desiredUID,
           let resolved = try? dependencies.audioDevices.resolve(uid: uid) {
            Task { try? await newPlayer.setOutputDevice(resolved.objectID) }
        }
    }

    /// The server keeps a channel's clips across client restarts; audio
    /// queued while this Mac was not playing is stale by the time it is.
    private func flushOwnChannel(for owner: SegmentPlayer) async {
        var delay: TimeInterval = 1.0
        while !Task.isCancelled, player === owner {
            do {
                _ = try await client.stop(channel: state.channel)
                return
            } catch {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                delay = min(delay * 1.5, 15.0)
            }
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
        try? dependencies.audioDevices.startObserving { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAudioOutput()
            }
        }
    }

    func refreshAudioOutput() {
        state.audioOutput = Self.resolveAudioOutput(
            provider: dependencies.audioDevices,
            userDefaults: dependencies.defaults
        )
    }

    func refreshLoginItem() {
        state.loginItem = dependencies.loginItem.refresh()
    }

    func setLocalServer(_ localServer: LocalServerState) {
        state.localServer = localServer
    }

    // MARK: - Server state

    /// Applies a /state body in one assignment so observers render once.
    /// Never clobbers activeVoice with nil if we already have one.
    private func apply(_ res: DaemonStateResponse) {
        var next = state
        next.status = .connected
        next.voices = res.voices ?? next.voices
        next.activeVoice = res.activeVoice ?? next.activeVoice
        next.activeClient = res.activeClient
        next.effects = res.effects ?? next.effects
        state = next
    }

    @discardableResult
    func pollState() async -> Bool {
        let currentGen = activeGeneration
        let wasConnected = state.status == .connected
        do {
            let res = try await client.state()
            // Drop stale poll responses if a mutation incremented generation.
            guard activeGeneration == currentGen else { return true }
            apply(res)
        } catch {
            guard activeGeneration == currentGen else { return false }
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
        dependencies.endpoint.savedHost = host

        client = DaemonClient(
            host: host,
            transport: client.transport
        )
        var next = state
        next.host = host
        next.status = .connecting
        next.activeClient = nil
        next.lastError = nil
        state = next
        // The poll loop claims once the new server answers.
        if dependencies.runsServices { startMonitoring() }
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
                label: self.dependencies.hostname
            )
            self.state.activeClient = ClientInfo(
                channel: self.state.channel,
                label: self.dependencies.hostname
            )
        }
    }

    func activateVoice(id: String) async {
        activeGeneration &+= 1
        let gen = activeGeneration
        await perform {
            let res = try await self.client.activateVoice(id)
            guard self.activeGeneration == gen else { return }
            self.apply(res)
        }
    }

    func setEffects(_ enabled: Bool) async {
        // Optimistic-safe toggle: record target state immediately.
        state.effects = enabled
        pendingEffects = enabled
        activeGeneration &+= 1
        let gen = activeGeneration
        await perform {
            let res = try await self.client.updateSettings(
                SettingsUpdateRequest(effects: enabled)
            )
            guard self.activeGeneration == gen else { return }
            self.apply(res)
            self.pendingEffects = nil
        }
    }


    func renameVoice(id: String, displayName: String) async {
        activeGeneration &+= 1
        await perform {
            _ = try await self.client.renameVoice(
                id: id,
                displayName: displayName
            )
            await self.pollState()
        }
    }

    func deleteVoice(id: String) async {
        activeGeneration &+= 1
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
        activeGeneration &+= 1
        return await perform {
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

    // MARK: - Local playback

    func setSpeakingRate(_ rate: Double) {
        let clamped = LocalSpeakingRate.clamped(rate)
        player?.setRate(clamped)
        dependencies.defaults.set(clamped, forKey: Self.rateKey)
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
        let defaults = dependencies.defaults
        if let device {
            defaults.set(device.uid, forKey: Self.outputUIDKey)
            defaults.set(device.name, forKey: Self.outputNameKey)
            if let resolved = try? dependencies.audioDevices.resolve(
                uid: device.uid
            ) {
                try? await player?.setOutputDevice(resolved.objectID)
            }
        } else {
            defaults.removeObject(forKey: Self.outputUIDKey)
            defaults.removeObject(forKey: Self.outputNameKey)
            if let snapshot = try? dependencies.audioDevices.snapshot() {
                try? await player?.setOutputDevice(
                    snapshot.defaultDevice.objectID
                )
            }
        }
        refreshAudioOutput()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        state.loginItem = dependencies.loginItem.setEnabled(enabled)
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
