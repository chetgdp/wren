import AppKit
import UniformTypeIdentifiers

@MainActor
protocol SettingsWindowActionSink: AnyObject {
    func updateEndpoint(host: String)
    func claimActive() async
    func activateVoice(id: String) async
    func renameVoice(id: String, displayName: String) async
    func deleteVoice(id: String) async
    func addVoice(
        id: String,
        name: String,
        audioURL: URL,
        transcript: String
    ) async -> Bool
    func setOutputDevice(_ device: AudioOutputDevice?) async
}

extension WrenStore: SettingsWindowActionSink {}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let actionSink: any SettingsWindowActionSink
    private(set) var model: SettingsViewModel

    let hostField = NSTextField()
    private let saveEndpointButton = NSButton()
    let statusLabel = NSTextField(labelWithString: "")
    let activeClientLabel = NSTextField(labelWithString: "")
    let playHereButton = NSButton()
    let errorLabel = NSTextField(wrappingLabelWithString: "")

    let voiceTable = NSTableView()
    private let voiceScroll = NSScrollView()

    let addIdField = NSTextField()
    let addNameField = NSTextField()
    let addTranscriptField = NSTextField()
    private let addAudioLabel = NSTextField(labelWithString: "No file chosen")
    private let chooseAudioButton = NSButton()
    let addVoiceButton = NSButton()
    var chosenAudioURL: URL?

    let outputPopUp = NSPopUpButton()

    init(
        state: AppState,
        actionSink: any SettingsWindowActionSink
    ) {
        self.actionSink = actionSink
        self.model = SettingsViewModel(state: state)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wren Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        buildUI()
        hostField.stringValue = model.serverHost
        apply(model, previous: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(state: AppState) {
        let next = SettingsViewModel(state: state)
        guard next != model else { return }
        let previous = model
        model = next
        apply(next, previous: previous)
    }

    /// Touches only what changed. The poll loop updates state every two
    /// seconds; reloading the table or popup each time would drop the
    /// user's selection and close an open popup menu.
    private func apply(
        _ model: SettingsViewModel,
        previous: SettingsViewModel?
    ) {
        statusLabel.stringValue = "Status: \(model.statusText)"
        activeClientLabel.stringValue = model.activeClientText
        playHereButton.isHidden = !model.showsPlayHere
        errorLabel.stringValue = model.errorText ?? ""
        errorLabel.isHidden = model.errorText == nil

        if previous?.outputOptions != model.outputOptions {
            outputPopUp.removeAllItems()
            for option in model.outputOptions {
                outputPopUp.addItem(withTitle: option.title)
            }
        }
        if outputPopUp.indexOfSelectedItem != model.selectedOutputIndex {
            outputPopUp.selectItem(at: model.selectedOutputIndex)
        }

        if previous?.voices != model.voices {
            voiceTable.reloadData()
        }
    }

    // MARK: Layout

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: content.leadingAnchor, constant: 20
            ),
            stack.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -20
            ),
            stack.topAnchor.constraint(
                equalTo: content.topAnchor, constant: 20
            ),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: content.bottomAnchor, constant: -20
            ),
        ])

        stack.addArrangedSubview(heading("Server"))
        hostField.placeholderString = Endpoint.defaultHost
        hostField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        configure(saveEndpointButton, "Save", #selector(saveEndpoint))
        stack.addArrangedSubview(NSStackView(views: [
            NSTextField(labelWithString: "Host:"), hostField,
            saveEndpointButton,
        ]))
        configure(playHereButton, "Play here", #selector(playHere))
        stack.addArrangedSubview(
            NSStackView(views: [statusLabel, activeClientLabel, playHereButton])
        )
        errorLabel.textColor = .systemRed
        stack.addArrangedSubview(errorLabel)

        stack.addArrangedSubview(heading("Output"))
        outputPopUp.target = self
        outputPopUp.action = #selector(outputChanged)
        stack.addArrangedSubview(outputPopUp)

        stack.addArrangedSubview(heading("Voices"))
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("voice")
        )
        column.title = "Voice"
        voiceTable.addTableColumn(column)
        voiceTable.headerView = nil
        voiceTable.rowHeight = 28
        voiceTable.selectionHighlightStyle = .none
        voiceTable.dataSource = self
        // Double-clicking a row activates it, alongside the row's button.
        voiceTable.target = self
        voiceTable.doubleAction = #selector(voiceRowDoubleClicked)
        voiceTable.delegate = self
        voiceScroll.documentView = voiceTable
        voiceScroll.hasVerticalScroller = true
        voiceScroll.borderType = .bezelBorder
        voiceScroll.translatesAutoresizingMaskIntoConstraints = false
        voiceScroll.heightAnchor.constraint(equalToConstant: 170)
            .isActive = true
        voiceScroll.widthAnchor.constraint(equalToConstant: 560)
            .isActive = true
        stack.addArrangedSubview(voiceScroll)

        stack.addArrangedSubview(heading("Add Voice"))
        addIdField.placeholderString = "id (a-z, 0-9, - or _)"
        addNameField.placeholderString = "Display name"
        addTranscriptField.placeholderString =
            "Exact transcript of the reference clip"
        addTranscriptField.usesSingleLineMode = false
        addTranscriptField.cell?.wraps = true
        addTranscriptField.widthAnchor.constraint(equalToConstant: 560)
            .isActive = true
        addTranscriptField.heightAnchor.constraint(equalToConstant: 60)
            .isActive = true
        configure(chooseAudioButton, "Choose WAV…", #selector(chooseAudio))
        configure(addVoiceButton, "Upload Voice", #selector(submitAddVoice))
        stack.addArrangedSubview(NSStackView(views: [
            NSTextField(labelWithString: "ID:"), addIdField,
            NSTextField(labelWithString: "Name:"), addNameField,
        ]))
        stack.addArrangedSubview(
            NSStackView(views: [chooseAudioButton, addAudioLabel])
        )
        stack.addArrangedSubview(addTranscriptField)
        stack.addArrangedSubview(addVoiceButton)
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func configure(
        _ button: NSButton,
        _ title: String,
        _ sel: Selector
    ) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = sel
    }

    // MARK: Actions

    @objc func saveEndpoint() {
        actionSink.updateEndpoint(host: hostField.stringValue)
    }

    @objc private func playHere() {
        Task { await actionSink.claimActive() }
    }

    @objc func outputChanged() {
        let index = outputPopUp.indexOfSelectedItem
        guard model.outputOptions.indices.contains(index) else { return }
        let device = model.outputOptions[index].device
        Task { await actionSink.setOutputDevice(device) }
    }

    /// Buttons carry the row index in `tag`; resolve against the current
    /// model so a row added after the last reload still maps correctly.
    private func voice(for sender: NSButton) -> SettingsVoiceRow? {
        model.voices.indices.contains(sender.tag)
            ? model.voices[sender.tag]
            : nil
    }

    @objc func useVoice(_ sender: NSButton) {
        guard let voice = voice(for: sender) else { return }
        Task { await actionSink.activateVoice(id: voice.id) }
    }

    @objc private func voiceRowDoubleClicked() {
        let row = voiceTable.clickedRow
        guard model.voices.indices.contains(row),
              !model.voices[row].isActive else { return }
        let id = model.voices[row].id
        Task { await actionSink.activateVoice(id: id) }
    }

    @objc private func renameVoice(_ sender: NSButton) {
        guard let voice = voice(for: sender) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename \(voice.displayName)"
        let field = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 240, height: 24)
        )
        field.stringValue = voice.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != voice.displayName else { return }
        Task { await actionSink.renameVoice(id: voice.id, displayName: name) }
    }

    @objc private func deleteVoice(_ sender: NSButton) {
        guard let voice = voice(for: sender), voice.canDelete else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(voice.displayName)?"
        alert.informativeText = "The reference audio is removed from the "
            + "server."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await actionSink.deleteVoice(id: voice.id) }
    }

    @objc private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        chosenAudioURL = url
        addAudioLabel.stringValue = url.lastPathComponent
    }

    @objc func submitAddVoice() {
        func trimmed(_ field: NSTextField) -> String {
            field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = trimmed(addIdField)
        let name = trimmed(addNameField)
        let transcript = trimmed(addTranscriptField)
        guard let url = chosenAudioURL, !id.isEmpty, !name.isEmpty,
              !transcript.isEmpty else {
            NSSound.beep()
            return
        }
        addVoiceButton.isEnabled = false
        Task {
            let ok = await actionSink.addVoice(
                id: id,
                name: name,
                audioURL: url,
                transcript: transcript
            )
            addVoiceButton.isEnabled = true
            guard ok else { return }
            addIdField.stringValue = ""
            addNameField.stringValue = ""
            addTranscriptField.stringValue = ""
            addAudioLabel.stringValue = "No file chosen"
            chosenAudioURL = nil
        }
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.voices.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard model.voices.indices.contains(row) else { return nil }
        let voice = model.voices[row]
        let name = NSTextField(labelWithString: voice.displayName)
        name.font = voice.isActive
            ? .boldSystemFont(ofSize: 13)
            : .systemFont(ofSize: 13)
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let use = rowButton(
            voice.isActive ? "Active" : "Use",
            #selector(useVoice(_:)),
            row
        )
        use.isEnabled = !voice.isActive
        let rename = rowButton("Rename…", #selector(renameVoice(_:)), row)
        let delete = rowButton("Delete…", #selector(deleteVoice(_:)), row)
        delete.isEnabled = voice.canDelete

        let stack = NSStackView(views: [name, use, rename, delete])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        return stack
    }

    private func rowButton(_ title: String, _ sel: Selector, _ row: Int)
        -> NSButton {
        let button = NSButton(title: title, target: self, action: sel)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = row
        return button
    }
}
