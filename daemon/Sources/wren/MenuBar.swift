import AppKit

/// Native menu-bar control surface rendered from one immutable AppState.
@MainActor
final class WrenMenuBar: NSObject {
    enum Action: Equatable {
        case refresh
        case activateVoice(id: String)
        case setSpeakingRate(Double)
        case setEffects(Bool)
        case setOutputDevice(AudioOutputDevice?)
        case setPaused(Bool)
        case stopSpeaking
        case setLaunchAtLogin(Bool)
        case showSettings
        case addVoice
        case manageVoices
        case retryStartup
        case resetInvalidSettings
        case revealLogs(URL)
        case quit
    }

    struct PersistentRowIDs: Equatable {
        let statusItem: ObjectIdentifier
        let statusView: ObjectIdentifier
        let progressItem: ObjectIdentifier
        let progressView: ObjectIdentifier
        let loginItem: ObjectIdentifier
        let loginView: ObjectIdentifier
    }

    private struct VisibleItems {
        let voiceParent: NSMenuItem
        let voiceChoices: [String: NSMenuItem]
        let addVoice: NSMenuItem?
        let manageVoices: NSMenuItem
        let effects: NSMenuItem
        let outputParent: NSMenuItem
        let outputChoices: [String: NSMenuItem]
        let outputMessage: WrenMenuMessageView?
        let pause: NSMenuItem
        let stop: NSMenuItem
        let loginMessage: WrenMenuMessageView?
        let recoveries: [NSMenuItem]
    }

    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private let statusView = WrenMenuStatusView()
    private let statusRow = NSMenuItem()
    private let progressView = WrenMenuProgressView()
    private let progressRow = NSMenuItem()
    private let loginView = WrenMenuLoginView()
    private let loginRow = NSMenuItem()
    private let rateView = SliderMenuView(
        title: "Speaking Rate",
        min: LocalSpeakingRate.minimum,
        max: LocalSpeakingRate.maximum
    )
    private let rateRow = NSMenuItem()
    private var model: WrenMenuModel?
    private var visibleItems: VisibleItems?

    var onAction: ((Action) -> Void)?

    var persistentRowIDs: PersistentRowIDs {
        PersistentRowIDs(
            statusItem: ObjectIdentifier(statusRow),
            statusView: ObjectIdentifier(statusView),
            progressItem: ObjectIdentifier(progressRow),
            progressView: ObjectIdentifier(progressView),
            loginItem: ObjectIdentifier(loginRow),
            loginView: ObjectIdentifier(loginView)
        )
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusRow.view = statusView
        progressRow.view = progressView
        loginRow.view = loginView
        rateRow.view = rateView
        statusItem.menu = menu
        configureStatusButton()

        rateView.onChange = { [weak self] value in
            self?.onAction?(.setSpeakingRate(value))
        }
        loginView.onToggle = { [weak self] enabled in
            self?.onAction?(.setLaunchAtLogin(enabled))
        }
        statusView.render(WrenMenuModel.Status(
            title: "Starting Wren",
            detail: "Connecting to the speech service",
            tone: .normal
        ))
        rebuild()
    }

    func render(_ state: AppState) {
        let model = WrenMenuModel(state: state)
        self.model = model
        updatePersistentRows(model)
        updateStatusButton(model)
        updateVisibleItems(model)
    }

    func rebuild() {
        menu.removeAllItems()
        visibleItems = nil
        guard let model else {
            menu.addItem(statusRow)
            menu.addItem(.separator())
            menu.addItem(quitItem())
            resizeCustomRows()
            return
        }

        updatePersistentRows(model)
        menu.addItem(statusRow)
        if model.progress != nil {
            menu.addItem(progressRow)
        }
        menu.addItem(.separator())

        let voice = buildVoiceItem(model)
        menu.addItem(voice.parent)
        menu.addItem(rateRow)
        let effects = buildEffectsItem(model)
        menu.addItem(effects)
        let output = buildOutputItem(model)
        menu.addItem(output.parent)

        menu.addItem(.separator())
        let pause = actionItem(
            title: model.pause.title,
            action: #selector(pauseClicked),
            symbol: model.pause.title == "Resume"
                ? "play.fill"
                : "pause.fill",
            enabled: model.pause.isEnabled
        )
        let stop = actionItem(
            title: model.stop.title,
            action: #selector(stopClicked),
            symbol: "stop.fill",
            enabled: model.stop.isEnabled
        )
        menu.addItem(pause)
        menu.addItem(stop)

        menu.addItem(.separator())
        var loginMessage: WrenMenuMessageView?
        if model.login.isVisible {
            menu.addItem(loginRow)
            if let error = model.login.error {
                let message = messageItem(error, tone: .warning)
                loginMessage = message.view
                    as? WrenMenuMessageView
                menu.addItem(message)
            }
        }
        menu.addItem(actionItem(
            title: "Settings…",
            action: #selector(settingsClicked),
            symbol: "gearshape",
            enabled: true
        ))

        var recoveries: [NSMenuItem] = []
        if !model.recoveryActions.isEmpty {
            menu.addItem(.separator())
            for recovery in model.recoveryActions {
                let item = recoveryItem(recovery)
                recoveries.append(item)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(quitItem())
        Self.applyCheckmarks(menu)
        resizeCustomRows()
        visibleItems = VisibleItems(
            voiceParent: voice.parent,
            voiceChoices: voice.choices,
            addVoice: voice.add,
            manageVoices: voice.manage,
            effects: effects,
            outputParent: output.parent,
            outputChoices: output.choices,
            outputMessage: output.message,
            pause: pause,
            stop: stop,
            loginMessage: loginMessage,
            recoveries: recoveries
        )
        updateVisibleItems(model)
    }
}

private extension WrenMenuBar {
    typealias VoiceItems = (
        parent: NSMenuItem,
        choices: [String: NSMenuItem],
        add: NSMenuItem?,
        manage: NSMenuItem
    )

    typealias OutputItems = (
        parent: NSMenuItem,
        choices: [String: NSMenuItem],
        message: WrenMenuMessageView?
    )

    func buildVoiceItem(_ model: WrenMenuModel) -> VoiceItems {
        let parent = NSMenuItem(
            title: "Voice",
            action: nil,
            keyEquivalent: ""
        )
        parent.image = Self.symbol("waveform", description: "Voice")
        parent.badge = NSMenuItemBadge(string: model.voiceBadge)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var choices: [String: NSMenuItem] = [:]
        if model.voices.isEmpty {
            submenu.addItem(messageItem(
                "No ready voices. Add or repair one in Settings.",
                tone: .normal
            ))
        } else {
            for choice in model.voices {
                let item = actionItem(
                    title: choice.title,
                    action: #selector(voiceClicked(_:)),
                    symbol: "waveform",
                    enabled: choice.isEnabled,
                    representedObject: choice.id
                )
                item.state = choice.isChecked ? .on : .off
                choices[choice.id] = item
                submenu.addItem(item)
            }
        }
        submenu.addItem(.separator())
        var add: NSMenuItem?
        if model.addVoiceVisible {
            let item = actionItem(
                title: "Add Voice…",
                action: #selector(addVoiceClicked),
                symbol: "plus",
                enabled: model.addVoiceEnabled
            )
            if !model.addVoiceEnabled {
                item.toolTip = "Another action is in progress."
            }
            submenu.addItem(item)
            add = item
        }
        let manage = actionItem(
            title: "Manage Voices…",
            action: #selector(manageVoicesClicked),
            symbol: "slider.horizontal.3",
            enabled: model.manageVoicesEnabled
        )
        submenu.addItem(manage)
        parent.submenu = submenu
        return (parent, choices, add, manage)
    }

    func buildEffectsItem(_ model: WrenMenuModel) -> NSMenuItem {
        let item = actionItem(
            title: "Effects",
            action: #selector(effectsClicked),
            symbol: "waveform.path.ecg",
            enabled: model.effectsEnabled
        )
        item.state = model.effectsOn ? .on : .off
        return item
    }

    func buildOutputItem(_ model: WrenMenuModel) -> OutputItems {
        let parent = NSMenuItem(
            title: "Output",
            action: nil,
            keyEquivalent: ""
        )
        parent.image = Self.symbol(
            "speaker.wave.2",
            description: "Output"
        )
        parent.badge = NSMenuItemBadge(string: model.outputBadge)
        parent.isEnabled = true
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        var choices: [String: NSMenuItem] = [:]
        for choice in model.outputChoices {
            let symbolName: String
            switch choice.target {
            case .systemDefault:
                symbolName = "speaker.wave.2"
            case .device:
                symbolName = "hifispeaker"
            case .unavailable:
                symbolName = "speaker.slash"
            }
            let item = actionItem(
                title: choice.title,
                action: #selector(outputClicked(_:)),
                symbol: symbolName,
                enabled: choice.isEnabled,
                representedObject: choice.target
            )
            item.state = choice.isChecked ? .on : .off
            let key = Self.outputKey(choice.target)
            choices[key] = item
            submenu.addItem(item)
        }
        var messageView: WrenMenuMessageView?
        if let message = model.outputMessage {
            submenu.addItem(.separator())
            let item = messageItem(message, tone: .warning)
            messageView = item.view as? WrenMenuMessageView
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return (parent, choices, messageView)
    }

    func actionItem(
        title: String,
        action: Selector,
        symbol: String,
        enabled: Bool,
        representedObject: Any? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.image = Self.symbol(symbol, description: title)
        item.isEnabled = enabled
        item.representedObject = representedObject
        return item
    }

    func messageItem(
        _ text: String,
        tone: WrenMenuModel.Tone
    ) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = WrenMenuMessageView(text: text, tone: tone)
        return item
    }

    func recoveryItem(
        _ recovery: WrenMenuModel.RecoveryAction
    ) -> NSMenuItem {
        let symbolName: String
        switch recovery.kind {
        case .retryStartup:
            symbolName = "arrow.clockwise"
        case .resetInvalidSettings:
            symbolName = "arrow.counterclockwise"
        case .revealLogs:
            symbolName = "doc.text.magnifyingglass"
        }
        return actionItem(
            title: recovery.title,
            action: #selector(recoveryClicked(_:)),
            symbol: symbolName,
            enabled: recovery.isEnabled,
            representedObject: recovery.kind
        )
    }

    func quitItem() -> NSMenuItem {
        let item = actionItem(
            title: "Quit Wren",
            action: #selector(quitClicked),
            symbol: "power",
            enabled: true
        )
        item.keyEquivalent = "q"
        return item
    }

    func updatePersistentRows(_ model: WrenMenuModel) {
        statusView.render(model.status)
        progressView.render(model.progress)
        loginView.render(model.login)
        rateView.value = model.speakingRate
        rateView.isEnabled = model.speakingRateEnabled
    }

    func updateVisibleItems(_ model: WrenMenuModel) {
        guard let items = visibleItems else { return }
        items.voiceParent.badge = NSMenuItemBadge(
            string: model.voiceBadge
        )
        for choice in model.voices {
            guard let item = items.voiceChoices[choice.id] else {
                continue
            }
            item.title = choice.title
            item.state = choice.isChecked ? .on : .off
            item.isEnabled = choice.isEnabled
        }
        items.addVoice?.isEnabled = model.addVoiceEnabled
        items.manageVoices.isEnabled = model.manageVoicesEnabled
        items.effects.state = model.effectsOn ? .on : .off
        items.effects.isEnabled = model.effectsEnabled
        items.outputParent.badge = NSMenuItemBadge(
            string: model.outputBadge
        )
        for choice in model.outputChoices {
            let key = Self.outputKey(choice.target)
            guard let item = items.outputChoices[key] else {
                continue
            }
            item.title = choice.title
            item.state = choice.isChecked ? .on : .off
            item.isEnabled = choice.isEnabled
        }
        if let messageView = items.outputMessage {
            messageView.render(
                text: model.outputMessage ?? "",
                tone: .warning
            )
        }
        items.pause.title = model.pause.title
        items.pause.image = Self.symbol(
            model.pause.title == "Resume"
                ? "play.fill"
                : "pause.fill",
            description: model.pause.title
        )
        items.pause.isEnabled = model.pause.isEnabled
        items.stop.isEnabled = model.stop.isEnabled
        if let messageView = items.loginMessage {
            messageView.render(
                text: model.login.error ?? "",
                tone: .warning
            )
        }
        for item in items.recoveries {
            guard let kind = item.representedObject
                as? WrenMenuModel.RecoveryKind,
                let recovery = model.recoveryActions.first(
                    where: { $0.kind == kind }
                )
            else {
                item.isEnabled = false
                continue
            }
            item.title = recovery.title
            item.isEnabled = recovery.isEnabled
        }
    }

    func resizeCustomRows() {
        let width = max(menu.size.width, WrenMenuMetrics.minimumWidth)
        statusView.setMenuWidth(width)
        progressView.setMenuWidth(width)
        loginView.setMenuWidth(width)
        rateView.setMenuWidth(width)
    }

    func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.logoImage()
        button.image?.isTemplate = true
        button.imagePosition = .imageLeft
        button.title = ""
    }

    func updateStatusButton(_ model: WrenMenuModel) {
        statusItem.button?.appearsDisabled = model.statusItemDimmed
        statusItem.button?.title = model.statusBarBadge.map {
            " \($0)"
        } ?? ""
    }

    @objc func voiceClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              model?.voices.first(
                where: { $0.id == id }
              )?.isChecked == false
        else { return }
        onAction?(.activateVoice(id: id))
    }

    @objc func addVoiceClicked() {
        onAction?(.addVoice)
    }

    @objc func manageVoicesClicked() {
        onAction?(.manageVoices)
    }

    @objc func effectsClicked() {
        guard let model else { return }
        onAction?(.setEffects(!model.effectsOn))
    }

    @objc func outputClicked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject
            as? WrenMenuModel.OutputTarget
        else { return }
        switch target {
        case .systemDefault:
            onAction?(.setOutputDevice(nil))
        case .device(let device):
            onAction?(.setOutputDevice(device))
        case .unavailable:
            return
        }
    }

    @objc func pauseClicked() {
        guard let model else { return }
        onAction?(.setPaused(model.pause.title != "Resume"))
    }

    @objc func stopClicked() {
        onAction?(.stopSpeaking)
    }

    @objc func settingsClicked() {
        onAction?(.showSettings)
    }

    @objc func recoveryClicked(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject
            as? WrenMenuModel.RecoveryKind
        else { return }
        switch kind {
        case .retryStartup:
            onAction?(.retryStartup)
        case .resetInvalidSettings:
            onAction?(.resetInvalidSettings)
        case .revealLogs(let url):
            onAction?(.revealLogs(url))
        }
    }

    @objc func quitClicked() {
        onAction?(.quit)
    }

    static func outputKey(
        _ target: WrenMenuModel.OutputTarget
    ) -> String {
        switch target {
        case .systemDefault:
            return "default"
        case .device(let device):
            return "device:\(device.uid)"
        case .unavailable(let uid):
            return "unavailable:\(uid)"
        }
    }

    static func applyCheckmarks(_ menu: NSMenu) {
        for item in menu.items {
            item.onStateImage = checkmark
            if let submenu = item.submenu {
                applyCheckmarks(submenu)
            }
        }
    }

    static func symbol(
        _ name: String,
        description: String
    ) -> NSImage? {
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: description
        )?.withSymbolConfiguration(
            .init(paletteColors: [.secondaryLabelColor])
        )
        image?.isTemplate = false
        return image
    }

    static let checkmark: NSImage? = {
        guard let base = NSImage(
            systemSymbolName: "checkmark",
            accessibilityDescription: "Selected"
        )?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .semibold)
        ) else { return nil }
        let padding = WrenMenuMetrics.space2
        let size = NSSize(
            width: base.size.width + padding * 2,
            height: base.size.height
        )
        let image = NSImage(
            size: size,
            flipped: false
        ) { _ in
            base.draw(
                at: NSPoint(x: padding, y: 0),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func logoImage() -> NSImage? {
        guard let data = Logo.svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}

extension WrenMenuBar: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        rebuild()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        onAction?(.refresh)
    }
}
