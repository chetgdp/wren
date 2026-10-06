import AppKit

@MainActor
final class WrenMenuBar: NSObject {
    enum Action: Equatable {
        case refresh
        case claimActive
        case activateVoice(id: String)
        case setSpeakingRate(Double)
        case setEffects(Bool)
        case setOutputDevice(AudioOutputDevice?)
        case setPaused(Bool)
        case stopSpeaking
        case setLaunchAtLogin(Bool)
        case showSettings
        case quit
    }

    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private let statusView = WrenMenuStatusView()
    private let statusRow = NSMenuItem()
    private let loginView = WrenMenuLoginView()
    private let loginRow = NSMenuItem()
    private let rateView = SliderMenuView(
        title: "Speaking Rate",
        min: LocalSpeakingRate.minimum,
        max: LocalSpeakingRate.maximum
    )
    private let rateRow = NSMenuItem()

    // Persistent menu items to avoid rebuild & flicker
    private let clientItem = NSMenuItem()
    private let playHereItem = NSMenuItem()
    private let voiceParent = NSMenuItem()
    private let voiceSubmenu = NSMenu()
    private let effectsItem = NSMenuItem()
    private let outputParent = NSMenuItem()
    private let outputSubmenu = NSMenu()
    private let pauseItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let settingsItem = NSMenuItem()

    private var model: WrenMenuModel?
    var onAction: ((Action) -> Void)?

    override init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusRow.view = statusView
        loginRow.view = loginView
        rateRow.view = rateView
        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.logoImage()
            button.imagePosition = .imageOnly
        }

        rateView.onChange = { [weak self] value in
            self?.onAction?(.setSpeakingRate(value))
        }
        loginView.onToggle = { [weak self] enabled in
            self?.onAction?(.setLaunchAtLogin(enabled))
        }

        buildMenuStructure()
    }

    private func buildMenuStructure() {
        menu.removeAllItems()

        menu.addItem(statusRow)
        menu.addItem(.separator())

        clientItem.title = "Connecting"
        clientItem.isEnabled = false
        menu.addItem(clientItem)

        playHereItem.title = "Play here"
        playHereItem.target = self
        playHereItem.action = #selector(playHereClicked)
        menu.addItem(playHereItem)

        menu.addItem(.separator())

        voiceParent.title = "Voice"
        voiceParent.image = Self.symbol("waveform")
        voiceParent.submenu = voiceSubmenu
        voiceSubmenu.autoenablesItems = false
        menu.addItem(voiceParent)

        menu.addItem(rateRow)

        effectsItem.title = "Effects"
        effectsItem.image = Self.symbol("waveform.path.ecg")
        effectsItem.target = self
        effectsItem.action = #selector(effectsClicked)
        menu.addItem(effectsItem)

        outputParent.title = "Output"
        outputParent.image = Self.symbol("speaker.wave.2")
        outputParent.submenu = outputSubmenu
        outputSubmenu.autoenablesItems = false
        menu.addItem(outputParent)

        menu.addItem(.separator())

        pauseItem.title = "Pause"
        pauseItem.image = Self.symbol("pause.fill")
        pauseItem.target = self
        pauseItem.action = #selector(pauseClicked)
        menu.addItem(pauseItem)

        stopItem.title = "Stop"
        stopItem.image = Self.symbol("stop.fill")
        stopItem.target = self
        stopItem.action = #selector(stopClicked)
        menu.addItem(stopItem)

        menu.addItem(.separator())

        menu.addItem(loginRow)

        settingsItem.title = "Settings…"
        settingsItem.image = Self.symbol("gearshape")
        settingsItem.target = self
        settingsItem.action = #selector(settingsClicked)
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Wren",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
    }

    /// Counts submenu rebuilds so tests can prove unchanged structure
    /// never re-creates items.
    private(set) var voiceRebuilds = 0
    private(set) var outputRebuilds = 0
    private var voiceItems: [String: NSMenuItem] = [:]
    private var outputItems: [String: NSMenuItem] = [:]

    func render(_ state: AppState) {
        let next = WrenMenuModel(state: state)
        guard next != model else { return }
        let previous = model
        model = next
        apply(next, previous: previous)
    }

    /// Diff render: each row is touched only when its slice of the model
    /// changed, and submenus are rebuilt only when items appear or vanish.
    /// Re-setting unchanged values on an open menu (or re-adding items)
    /// makes AppKit redraw the rows, which shows as flicker.
    private func apply(_ model: WrenMenuModel, previous: WrenMenuModel?) {
        if previous?.status != model.status {
            statusView.render(model.status)
        }
        if previous?.clientTitle != model.clientTitle {
            clientItem.title = model.clientTitle
        }
        if previous?.showsPlayHere != model.showsPlayHere {
            playHereItem.isHidden = !model.showsPlayHere
        }

        if previous?.structure.voiceIDs != model.structure.voiceIDs {
            rebuildVoices(model.voices)
        }
        if previous?.voices != model.voices {
            for voice in model.voices {
                guard let item = voiceItems[voice.id] else { continue }
                if item.title != voice.title { item.title = voice.title }
                let state: NSControl.StateValue = voice.isChecked ? .on : .off
                if item.state != state { item.state = state }
            }
        }
        if previous?.voiceBadge != model.voiceBadge {
            voiceParent.badge = NSMenuItemBadge(string: model.voiceBadge)
        }

        if previous?.effectsOn != model.effectsOn {
            effectsItem.state = model.effectsOn ? .on : .off
        }
        if previous?.isConnected != model.isConnected {
            effectsItem.isEnabled = model.isConnected
            voiceParent.isEnabled = model.isConnected
        }
        if previous?.speakingRate != model.speakingRate {
            rateView.value = model.speakingRate
        }

        if previous?.structure.outputKeys != model.structure.outputKeys {
            rebuildOutputs(model.outputChoices)
        }
        if previous?.outputChoices != model.outputChoices {
            for choice in model.outputChoices {
                guard let item = outputItems[choice.target.key] else {
                    continue
                }
                if item.title != choice.title { item.title = choice.title }
                item.representedObject = choice.target
                let state: NSControl.StateValue = choice.isChecked ? .on : .off
                if item.state != state { item.state = state }
            }
        }
        if previous?.outputBadge != model.outputBadge {
            outputParent.badge = NSMenuItemBadge(string: model.outputBadge)
        }

        if previous?.isPaused != model.isPaused {
            pauseItem.title = model.isPaused ? "Resume" : "Pause"
            pauseItem.image = Self.symbol(
                model.isPaused ? "play.fill" : "pause.fill"
            )
        }
        if previous?.login != model.login {
            loginView.render(model.login)
        }
    }

    private func rebuildVoices(_ voices: [WrenMenuModel.VoiceChoice]) {
        voiceRebuilds += 1
        voiceSubmenu.removeAllItems()
        voiceItems = [:]
        guard !voices.isEmpty else {
            let item = NSMenuItem(
                title: "No voices",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            voiceSubmenu.addItem(item)
            return
        }
        for voice in voices {
            let item = NSMenuItem(
                title: voice.title,
                action: #selector(voiceClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = voice.id
            item.state = voice.isChecked ? .on : .off
            voiceSubmenu.addItem(item)
            voiceItems[voice.id] = item
        }
    }

    private func rebuildOutputs(_ choices: [WrenMenuModel.OutputChoice]) {
        outputRebuilds += 1
        outputSubmenu.removeAllItems()
        outputItems = [:]
        for choice in choices {
            let item = NSMenuItem(
                title: choice.title,
                action: #selector(outputClicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice.target
            item.state = choice.isChecked ? .on : .off
            outputSubmenu.addItem(item)
            outputItems[choice.target.key] = item
        }
    }

    /// Custom-view rows do not track the menu's width on their own.
    private func resizeCustomRows() {
        let width = max(menu.size.width, WrenMenuMetrics.minimumWidth)
        statusView.setMenuWidth(width)
        loginView.setMenuWidth(width)
        rateView.setMenuWidth(width)
    }

    @objc private func playHereClicked() {
        onAction?(.claimActive)
    }

    @objc private func voiceClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onAction?(.activateVoice(id: id))
    }

    @objc private func effectsClicked() {
        guard let model else { return }
        onAction?(.setEffects(!model.effectsOn))
    }

    @objc private func outputClicked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject
            as? WrenMenuModel.OutputTarget else { return }
        switch target {
        case .systemDefault:
            onAction?(.setOutputDevice(nil))
        case .device(let dev):
            onAction?(.setOutputDevice(dev))
        }
    }

    @objc private func pauseClicked() {
        guard let model else { return }
        onAction?(.setPaused(!model.isPaused))
    }

    @objc private func stopClicked() {
        onAction?(.stopSpeaking)
    }

    @objc private func settingsClicked() {
        onAction?(.showSettings)
    }

    @objc private func quitClicked() {
        onAction?(.quit)
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func logoImage() -> NSImage? {
        guard let data = Logo.svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

extension WrenMenuBar: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        resizeCustomRows()
        onAction?(.refresh)
    }
}
