import AppKit
import UniformTypeIdentifiers

@MainActor
final class SettingsAddVoiceViewController: NSViewController {
    var onCancel: (() -> Void)?
    var onSubmit: ((SettingsVoiceImport) -> Void)?

    private var draft = SettingsVoiceImportDraft()
    private var existingIDs: Set<String>
    private var importAvailable: Bool
    private var submissionEnabled: Bool
    private let fileExists: (URL) -> Bool

    private let wavValue = SettingsStyle.detailLabel("No file chosen")
    private let transcriptValue = SettingsStyle.detailLabel("No file chosen")
    private let nameField = NSTextField()
    private let idField = NSTextField()
    private let validationLabel = SettingsStyle.detailLabel()
    private let addButton = SettingsStyle.actionButton(
        "Add Voice",
        target: nil,
        action: nil)

    init(
        existingIDs: Set<String>,
        importAvailable: Bool,
        submissionEnabled: Bool? = nil,
        fileExists: @escaping (URL) -> Bool = {
            FileManager.default.fileExists(atPath: $0.path)
        }
    ) {
        self.existingIDs = existingIDs
        self.importAvailable = importAvailable
        self.submissionEnabled = submissionEnabled ?? importAvailable
        self.fileExists = fileExists
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func loadView() {
        view = NSView()
        nameField.placeholderString = "Voice name"
        nameField.delegate = self
        nameField.setAccessibilityLabel("Voice Display Name")
        idField.placeholderString = "stable-id"
        idField.delegate = self
        idField.font = SettingsStyle.codeFont
        idField.setAccessibilityLabel("Stable Voice ID")
        for field in [nameField, idField] {
            field.widthAnchor.constraint(
                equalToConstant: SettingsStyle.fieldWidth
            ).isActive = true
        }
        wavValue.lineBreakMode = .byTruncatingMiddle
        wavValue.setAccessibilityLabel("Reference WAV")
        transcriptValue.lineBreakMode = .byTruncatingMiddle
        transcriptValue.setAccessibilityLabel("Transcript")
        addButton.target = self
        addButton.action = #selector(addClicked)

        let title = SettingsStyle.label(
            "Add Voice",
            font: SettingsStyle.titleFont)
        let help = SettingsStyle.detailLabel(
            "Choose local reference files. Wren adds a library profile; "
                + "your active voice will not change.")
        let wavButton = SettingsStyle.actionButton(
            "Choose WAV…",
            target: self,
            action: #selector(chooseWAV))
        let transcriptButton = SettingsStyle.actionButton(
            "Choose Transcript…",
            target: self,
            action: #selector(chooseTranscript))
        let wavRow = fileRow(button: wavButton, value: wavValue)
        let transcriptRow = fileRow(
            button: transcriptButton,
            value: transcriptValue)
        let nameRow = formRow(label: "Display Name", value: nameField)
        let idRow = formRow(label: "Stable ID", value: idField)
        let idHelp = SettingsStyle.detailLabel(
            "1–32 lowercase letters, digits, hyphens, or underscores. "
                + "The ID cannot be changed after import.")
        let cancelButton = SettingsStyle.actionButton(
            "Cancel",
            target: self,
            action: #selector(cancelClicked))
        cancelButton.keyEquivalent = "\u{1b}"
        addButton.keyEquivalent = "\r"
        let buttons = SettingsStyle.horizontalStack()
        buttons.addArrangedSubview(NSView())
        buttons.addArrangedSubview(cancelButton)
        buttons.addArrangedSubview(addButton)

        let stack = SettingsStyle.verticalStack(
            spacing: SettingsStyle.space3)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(help)
        stack.setCustomSpacing(SettingsStyle.space6, after: help)
        stack.addArrangedSubview(wavRow)
        stack.addArrangedSubview(transcriptRow)
        stack.setCustomSpacing(
            SettingsStyle.space6,
            after: transcriptRow)
        stack.addArrangedSubview(nameRow)
        stack.addArrangedSubview(idRow)
        stack.addArrangedSubview(idHelp)
        stack.addArrangedSubview(validationLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(buttons)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: SettingsStyle.space6),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -SettingsStyle.space6),
            stack.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: SettingsStyle.space6),
            stack.bottomAnchor.constraint(
                equalTo: view.bottomAnchor,
                constant: -SettingsStyle.space6)
        ])
        renderDraft()
    }

    func update(
        existingIDs: Set<String>,
        importAvailable: Bool,
        submissionEnabled: Bool
    ) {
        self.existingIDs = existingIDs
        self.importAvailable = importAvailable
        self.submissionEnabled = submissionEnabled
        if isViewLoaded { renderValidation() }
    }

    private func fileRow(
        button: NSButton,
        value: NSTextField
    ) -> NSStackView {
        button.widthAnchor.constraint(
            equalToConstant: SettingsStyle.diagnosticLabelWidth
        ).isActive = true
        let row = SettingsStyle.horizontalStack(
            spacing: SettingsStyle.space4)
        row.addArrangedSubview(button)
        row.addArrangedSubview(value)
        return row
    }

    private func formRow(
        label: String,
        value: NSView
    ) -> NSStackView {
        let key = SettingsStyle.sectionLabel(label)
        key.alignment = .right
        key.widthAnchor.constraint(
            equalToConstant: SettingsStyle.diagnosticLabelWidth
        ).isActive = true
        let row = SettingsStyle.horizontalStack(
            spacing: SettingsStyle.space4)
        row.addArrangedSubview(key)
        row.addArrangedSubview(value)
        return row
    }

    private func renderDraft() {
        wavValue.stringValue = draft.wavURL?.path ?? "No file chosen"
        transcriptValue.stringValue = draft.transcriptURL?.path
            ?? "No file chosen"
        nameField.stringValue = draft.displayName
        idField.stringValue = draft.id
        renderValidation()
    }

    private func renderValidation() {
        let validation = draft.validate(
            existingIDs: existingIDs,
            importAvailable: importAvailable)
        if let message = validation.message {
            validationLabel.stringValue = message
            validationLabel.textColor = .systemRed
            addButton.isEnabled = false
        } else if !submissionEnabled {
            validationLabel.stringValue = "Another action is in progress."
            validationLabel.textColor = .secondaryLabelColor
            addButton.isEnabled = false
        } else {
            validationLabel.stringValue =
                "Ready to add. The active voice will not change."
            validationLabel.textColor = .secondaryLabelColor
            addButton.isEnabled = true
        }
    }

    private func chooseFile(
        contentTypes: [UTType],
        completion: @escaping (URL) -> Void
    ) {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in completion(url) }
        }
    }

    @objc private func chooseWAV() {
        chooseFile(contentTypes: [.wav]) { [weak self] url in
            guard let self else { return }
            self.draft.chooseWAV(url, fileExists: self.fileExists)
            self.renderDraft()
        }
    }

    @objc private func chooseTranscript() {
        chooseFile(contentTypes: [.plainText]) { [weak self] url in
            guard let self else { return }
            self.draft.chooseTranscript(url, fileExists: self.fileExists)
            self.renderDraft()
        }
    }

    @objc private func addClicked() {
        let validation = draft.validate(
            existingIDs: existingIDs,
            importAvailable: importAvailable)
        guard submissionEnabled,
              let submission = validation.submission else {
            renderValidation()
            return
        }
        onSubmit?(submission)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

extension SettingsAddVoiceViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as? NSTextField === nameField {
            draft.setDisplayName(nameField.stringValue)
        } else if obj.object as? NSTextField === idField {
            draft.setID(idField.stringValue)
        }
        renderValidation()
    }
}
