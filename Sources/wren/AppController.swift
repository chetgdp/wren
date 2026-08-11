import AppKit
import Foundation

/// Wires the pieces of the menu bar app together: DaemonManager owns the
/// child, SegmentPlayer owns the speakers, a 1s /health poll drives the
/// icon and mirrors the daemon's pause flag into the player.
@MainActor
final class AppController {
    private let client: DaemonClient
    private let daemon: DaemonManager
    private let player: SegmentPlayer
    private let menuBar: WrenMenuBar
    private var healthTimer: Timer?
    private var daemonState = DaemonManager.State.starting
    private var terminationObserver: NSObjectProtocol?
    private var controls = WrenMenuBar.ControlsState()
    /// Where the voice picker scans: the config's voices_dir once set, else
    /// the app's own Application Support/voices (seeded on first run).
    private var voicesDirInUse: String

    /// Client-side playback multiplier; it never touches daemon config, so
    /// the app persists it itself.
    private static let rateKey = "playerRate"

    init() {
        let paths = WrenPaths.standard()
        voicesDirInUse = paths.voices.path
        let port = Self.configPort(at: paths.configFile)
        let host = "127.0.0.1:\(port)"
        let token = DaemonClient.resolveToken(flag: nil)
        client = DaemonClient(host: host, token: token)
        let base = URL(string: "http://\(host)")!
        daemon = DaemonManager(paths: paths, baseURL: base)
        player = SegmentPlayer(base: base, token: token)
        menuBar = WrenMenuBar()

        menuBar.onPauseToggle = { [weak self] pause in
            self?.togglePause(pause)
        }
        menuBar.onStop = { [weak self] in
            guard let self else { return }
            Task { let _: StopResponse? = try? await self.client.post("/stop") }
        }
        menuBar.onMenuOpen = { [weak self] in
            guard let self else { return }
            Task { await self.refreshControls() }
        }
        menuBar.onVoiceSelect = { [weak self] voice in
            guard let self else { return }
            // First pick on a fresh config: voice requires voices_dir, and
            // the fallback dir the menu scanned is the one to persist.
            let dir = self.voicesDirInUse
            Task {
                await self.applyConfig(ConfigUpdate(voice: voice, voicesDir: dir))
            }
        }
        menuBar.onSpeedChange = { [weak self] speed in
            guard let self else { return }
            Task { await self.applyConfig(ConfigUpdate(speed: speed)) }
        }
        menuBar.onFxToggle = { [weak self] fx in
            guard let self else { return }
            Task { await self.applyConfig(ConfigUpdate(fx: fx)) }
        }
        menuBar.onRateChange = { [weak self] rate in
            guard let self else { return }
            self.controls.playerRate = rate
            self.player.setRate(rate)
            UserDefaults.standard.set(rate, forKey: Self.rateKey)
        }
        let savedRate = UserDefaults.standard.double(forKey: Self.rateKey)
        controls.playerRate = savedRate > 0 ? savedRate : 1.0
        player.setRate(controls.playerRate)
        daemon.onState = { [weak self] state in
            Task { @MainActor in self?.daemonState = state }
        }
        // Quit must kill a spawned child, whichever way the quit arrives
        // (menu, Cmd-Q, logout).
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [daemon] _ in
            daemon.shutdown()
        }

        daemon.start()
        player.start()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    private func togglePause(_ pause: Bool) {
        // The daemon's flag can't stop audio the player already fetched, so
        // the player pauses locally right now; the POST keeps the daemon's
        // state (and the machine queue's turn) in agreement.
        player.setPaused(pause)
        Task {
            let path = pause ? "/pause" : "/resume"
            let _: PauseResponse? = try? await client.post(path)
        }
    }

    private func tick() async {
        guard let health: HealthResponse = try? await client.get("/health") else {
            menuBar.setState(stateWhileUnreachable())
            return
        }
        if !health.ready {
            menuBar.setState(.loading)
            return
        }
        // The top-level paused/speaking are the local channel's view, which
        // is exactly the channel this player owns.
        player.setPaused(health.paused)
        if health.paused {
            menuBar.setState(.paused)
        } else if health.speaking || health.pending > 0 {
            menuBar.setState(.speaking)
        } else {
            menuBar.setState(.idle)
        }
    }

    /// Menu open: pull /config and rescan the voices folder, so the menu
    /// shows the daemon's live truth (another client may have changed it).
    private func refreshControls() async {
        guard let config: ConfigPayload = try? await client.get("/config") else { return }
        show(config)
    }

    private func applyConfig(_ update: ConfigUpdate) async {
        guard let config: ConfigPayload = try? await client.post("/config", body: update)
        else { return }
        show(config)
    }

    /// Reconcile the menu with the daemon's config, and deliver a persisted
    /// change the daemon can't hot-apply (voice: model reload) by restarting
    /// our child. Runs on every /config response, so a change made by any
    /// client (menu, CLI, extension) gets applied on the next menu open.
    private func show(_ config: ConfigPayload) {
        if config.restartRequired, daemonState == .spawned {
            daemon.restart()
        }
        controls.voice = config.voice
        if let dir = config.voicesDir {
            voicesDirInUse = dir
        }
        controls.voices = VoiceLibrary.voices(in: VoiceLibrary.expand(voicesDirInUse))
        controls.speed = config.speed
        controls.fx = config.fx
        // Auto-restart covers our own child; an adopted daemon's pending
        // change is the user's to deliver.
        controls.restartPending = config.restartRequired && daemonState != .spawned
        menuBar.setControls(controls)
    }

    /// /health said nothing; the daemon manager knows why (provisioning, a
    /// crashed child, or nothing to manage at all).
    private func stateWhileUnreachable() -> WrenMenuBar.DisplayState {
        switch daemonState {
        case .provisioning(let message):
            return .provisioning(message)
        case .failed(let message):
            return .down(detail: message)
        case .starting, .spawned:
            return .loading
        case .adopted:
            return .down(detail: "daemon stopped")
        }
    }

    /// serve.py owns config.json; the app only needs the port to find it.
    private static func configPort(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = json["port"] as? Int
        else { return 8765 }
        return port
    }
}
