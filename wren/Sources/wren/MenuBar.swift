import AppKit

/// Menu bar presence: the icon is the daemon's liveness indicator, the menu
/// the control surface (voice, speed, player rate, fx, pause, stop, quit).
@MainActor
final class WrenMenuBar: NSObject {
    enum DisplayState: Equatable {
        case down(detail: String?)
        case provisioning(String)
        case loading
        case idle
        case speaking
        case paused
    }

    /// Snapshot of everything the controls display; the app controller
    /// rebuilds it from GET /config plus a voices_dir scan on menu open.
    struct ControlsState: Equatable {
        var voice: String?
        var voices: [String] = []
        var speed = 1.0
        var fx = false
        var playerRate = 1.0
        /// A persisted voice change the running daemon has not applied and
        /// the app cannot fix by restarting (adopted daemon, not our child).
        var restartPending = false
    }

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateLabel = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
    private let voiceMenu = NSMenu()
    private let restartNote = NSMenuItem(
        title: "restart daemon to apply voice", action: nil, keyEquivalent: "")
    private let speedSlider = SliderMenuView(title: "Speed", min: 0.5, max: 3.0)
    private let rateSlider = SliderMenuView(title: "Player rate", min: 0.5, max: 3.0)
    private let fxItem: NSMenuItem
    private let pauseItem: NSMenuItem
    private let stopItem: NSMenuItem
    private var state = DisplayState.down(detail: nil)
    private var controls = ControlsState()

    var onPauseToggle: ((_ pause: Bool) -> Void)?
    var onStop: (() -> Void)?
    var onVoiceSelect: ((String) -> Void)?
    var onSpeedChange: ((Double) -> Void)?
    var onRateChange: ((Double) -> Void)?
    var onFxToggle: ((Bool) -> Void)?
    /// Fired when the menu opens: the moment to refresh config and voices.
    var onMenuOpen: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        fxItem = NSMenuItem(title: "Effects", action: nil, keyEquivalent: "")
        pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
        stopItem = NSMenuItem(title: "Stop speaking", action: nil, keyEquivalent: "")
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        stateLabel.isEnabled = false

        voiceItem.submenu = voiceMenu
        restartNote.isEnabled = false
        restartNote.isHidden = true

        let speedItem = NSMenuItem()
        speedItem.view = speedSlider
        speedSlider.onChange = { [weak self] value in self?.onSpeedChange?(value) }
        let rateItem = NSMenuItem()
        rateItem.view = rateSlider
        rateSlider.onChange = { [weak self] value in self?.onRateChange?(value) }

        fxItem.target = self
        fxItem.action = #selector(fxClicked)
        pauseItem.target = self
        pauseItem.action = #selector(pauseClicked)
        stopItem.target = self
        stopItem.action = #selector(stopClicked)

        menu.addItem(stateLabel)
        menu.addItem(.separator())
        menu.addItem(voiceItem)
        menu.addItem(restartNote)
        menu.addItem(speedItem)
        menu.addItem(rateItem)
        menu.addItem(fxItem)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Wren", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.image = Self.logoImage()
        statusItem.button?.imagePosition = .imageLeft
        apply()
        setControls(controls)
    }

    func setState(_ new: DisplayState) {
        guard new != state else { return }
        state = new
        apply()
    }

    func setControls(_ new: ControlsState) {
        controls = new
        voiceMenu.removeAllItems()
        if new.voices.isEmpty {
            let empty = NSMenuItem(title: "no voices found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            voiceMenu.addItem(empty)
        }
        for name in new.voices {
            let item = NSMenuItem(title: name, action: #selector(voiceClicked), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == new.voice ? .on : .off
            voiceMenu.addItem(item)
        }
        // The current voice reads off the closed row, macOS-style ("Voice"
        // left, name right-aligned in grey) via the badge slot.
        voiceItem.badge = new.voice.map { NSMenuItemBadge(string: $0) }
        restartNote.isHidden = !new.restartPending
        speedSlider.value = new.speed
        rateSlider.value = new.playerRate
        fxItem.state = new.fx ? .on : .off
        apply()
    }

    private func apply() {
        let button = statusItem.button
        button?.appearsDisabled = false
        button?.title = ""
        switch state {
        case .down(let detail):
            stateLabel.title = detail ?? "daemon not running"
            button?.appearsDisabled = true
        case .provisioning(let message):
            stateLabel.title = message
            // Progress next to the icon so a 2 GB first-run download is
            // visible without opening the menu (the otis pattern).
            if let percent = message.split(separator: " ").last, percent.hasSuffix("%") {
                button?.title = " \(percent)"
            }
        case .loading:
            stateLabel.title = "loading model…"
        case .idle:
            stateLabel.title = "idle"
        case .speaking:
            stateLabel.title = "● speaking"
        case .paused:
            stateLabel.title = "paused"
        }
        let ready = [.idle, .speaking, .paused].contains(state)
        voiceItem.isEnabled = ready
        fxItem.isEnabled = ready
        speedSlider.isEnabled = ready
        // The player rate is client-side; it works whenever the app does.
        rateSlider.isEnabled = true
        // Pause/stop act on audio; with nothing queued or playing they are
        // dead buttons, so show them that way.
        let active = [.speaking, .paused].contains(state)
        pauseItem.isEnabled = active
        stopItem.isEnabled = active
        pauseItem.title = state == .paused ? "Resume" : "Pause"
    }

    @objc private func voiceClicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              name != controls.voice else { return }
        onVoiceSelect?(name)
    }

    @objc private func fxClicked() {
        onFxToggle?(fxItem.state != .on)
    }

    @objc private func pauseClicked() {
        onPauseToggle?(state != .paused)
    }

    @objc private func stopClicked() {
        onStop?()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // assets/logo.svg is stamped into Logo.generated.swift by
    // scripts/stamp-logo.sh, so the executable stays single-file.
    private static func logoImage() -> NSImage? {
        guard let data = Logo.svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }
}

extension WrenMenuBar: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onMenuOpen?()
    }
}
