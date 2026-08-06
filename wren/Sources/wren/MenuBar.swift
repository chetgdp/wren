import AppKit

/// Menu bar presence: the icon is the daemon's liveness indicator, the menu
/// the minimal control surface (pause, stop, quit). Voice picker, speed
/// slider, and the rest of /config arrive with step 6.
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

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let stateLabel = NSMenuItem(title: "starting…", action: nil, keyEquivalent: "")
    private let pauseItem: NSMenuItem
    private let stopItem: NSMenuItem
    private var state = DisplayState.down(detail: nil)

    var onPauseToggle: ((_ pause: Bool) -> Void)?
    var onStop: (() -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
        stopItem = NSMenuItem(title: "Stop speaking", action: nil, keyEquivalent: "")
        super.init()

        menu.autoenablesItems = false
        stateLabel.isEnabled = false
        pauseItem.target = self
        pauseItem.action = #selector(pauseClicked)
        stopItem.target = self
        stopItem.action = #selector(stopClicked)

        menu.addItem(stateLabel)
        menu.addItem(.separator())
        menu.addItem(pauseItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Wren", action: #selector(quitClicked), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.image = Self.icon()
        statusItem.button?.imagePosition = .imageLeft
        apply()
    }

    func setState(_ new: DisplayState) {
        guard new != state else { return }
        state = new
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
        pauseItem.isEnabled = ready
        stopItem.isEnabled = ready
        pauseItem.title = state == .paused ? "Resume" : "Pause"
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

    private static func icon() -> NSImage? {
        // No drawn logo yet; the SF bird stands in until gen-icons lands.
        let image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Wren")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Wren")
        image?.isTemplate = true
        return image
    }
}
