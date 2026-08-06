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

    init() {
        let paths = WrenPaths.standard()
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
