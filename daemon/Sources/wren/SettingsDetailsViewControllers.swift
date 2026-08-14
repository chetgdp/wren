import AppKit

@MainActor
final class SettingsOutputViewController: NSViewController {
    var onAction: ((SettingsWindowAction) -> Void)?

    private var model: SettingsOutputViewModel?
    private let outputPopup = NSPopUpButton()
    private let desiredValue = SettingsStyle.label("")
    private let effectiveValue = SettingsStyle.label("")
    private let warningLabel = SettingsStyle.detailLabel()
    private let errorLabel = SettingsStyle.detailLabel()

    override func loadView() {
        view = NSView()
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged)
        outputPopup.setAccessibilityLabel("Preferred Output")
        outputPopup.widthAnchor.constraint(
            equalToConstant: SettingsStyle.fieldWidth).isActive = true
        desiredValue.setAccessibilityLabel("Desired Output")
        effectiveValue.setAccessibilityLabel("Effective Output")
        warningLabel.textColor = .systemOrange
        errorLabel.textColor = .systemRed

        let title = SettingsStyle.label(
            "Output",
            font: SettingsStyle.titleFont)
        let help = SettingsStyle.detailLabel(
            "Wren remembers a device by its stable Core Audio identifier. "
                + "If it disconnects, playback uses the system default.")
        let selectRow = detailRow(
            label: "Preferred Device",
            value: outputPopup)
        let desiredRow = detailRow(
            label: "Desired",
            value: desiredValue)
        let effectiveRow = detailRow(
            label: "Effective",
            value: effectiveValue)
        let stack = SettingsStyle.verticalStack(
            spacing: SettingsStyle.space4)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(help)
        stack.setCustomSpacing(SettingsStyle.space8, after: help)
        stack.addArrangedSubview(selectRow)
        stack.addArrangedSubview(desiredRow)
        stack.addArrangedSubview(effectiveRow)
        stack.setCustomSpacing(
            SettingsStyle.space6,
            after: effectiveRow)
        stack.addArrangedSubview(warningLabel)
        stack.addArrangedSubview(errorLabel)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: SettingsStyle.space8),
            stack.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -SettingsStyle.space8),
            stack.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: SettingsStyle.space8)
        ])
    }

    func render(_ model: SettingsOutputViewModel) {
        loadViewIfNeeded()
        self.model = model
        outputPopup.removeAllItems()
        for option in model.options {
            outputPopup.addItem(withTitle: option.title)
            outputPopup.lastItem?.isEnabled = option.isConnected
        }
        selectDesiredOption()
        outputPopup.isEnabled = model.selectionEnabled
        desiredValue.stringValue = model.desiredTitle
        effectiveValue.stringValue = model.effectiveTitle
        warningLabel.stringValue = model.fallbackWarning ?? ""
        warningLabel.isHidden = model.fallbackWarning == nil
        errorLabel.stringValue = model.providerError ?? ""
        errorLabel.isHidden = model.providerError == nil
    }

    private func detailRow(
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

    private func selectDesiredOption() {
        guard let model else { return }
        let index = model.options.firstIndex {
            $0.uid == model.desiredUID
        } ?? 0
        outputPopup.selectItem(at: index)
    }

    @objc private func outputChanged() {
        guard let model,
              model.selectionEnabled,
              outputPopup.indexOfSelectedItem >= 0
        else { return }
        let option = model.options[outputPopup.indexOfSelectedItem]
        selectDesiredOption()
        guard option.isConnected,
              option.uid != model.desiredUID
        else { return }
        onAction?(.setOutputDevice(option.device))
    }
}

@MainActor
final class SettingsDiagnosticsViewController: NSViewController {
    var onAction: ((SettingsWindowAction) -> Void)?
    var onRevealLogs: ((URL) -> Void)?

    private let rowsStack = SettingsStyle.verticalStack(
        spacing: SettingsStyle.space3)
    private let errorLabel = SettingsStyle.detailLabel()
    private let recoveryStack = SettingsStyle.verticalStack(
        spacing: SettingsStyle.space3)
    private let recoveryMessage = SettingsStyle.detailLabel()
    private let retryButton = SettingsStyle.actionButton(
        "Retry",
        target: nil,
        action: nil)
    private let resetButton = SettingsStyle.actionButton(
        "Reset Invalid Settings",
        target: nil,
        action: nil)
    private let revealButton = SettingsStyle.actionButton(
        "Reveal Logs",
        target: nil,
        action: nil)
    private var revealLogURL: URL?

    override func loadView() {
        view = NSView()
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        resetButton.target = self
        resetButton.action = #selector(resetClicked)
        revealButton.target = self
        revealButton.action = #selector(revealClicked)
        errorLabel.textColor = .systemRed

        let title = SettingsStyle.label(
            "Diagnostics",
            font: SettingsStyle.titleFont)
        let help = SettingsStyle.detailLabel(
            "Deployment facts are read-only. Change backend, model, "
                + "endpoint, and library settings where Wren is launched.")
        let actions = SettingsStyle.horizontalStack()
        actions.addArrangedSubview(retryButton)
        actions.addArrangedSubview(resetButton)
        actions.addArrangedSubview(revealButton)
        recoveryStack.addArrangedSubview(
            SettingsStyle.sectionLabel("Recovery"))
        recoveryStack.addArrangedSubview(recoveryMessage)
        recoveryStack.addArrangedSubview(actions)

        let content = SettingsStyle.verticalStack(
            spacing: SettingsStyle.space4)
        content.addArrangedSubview(title)
        content.addArrangedSubview(help)
        content.setCustomSpacing(SettingsStyle.space8, after: help)
        content.addArrangedSubview(rowsStack)
        content.addArrangedSubview(errorLabel)
        content.setCustomSpacing(
            SettingsStyle.space8,
            after: errorLabel)
        content.addArrangedSubview(recoveryStack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scrollView.documentView = document
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(
                equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor),
            content.leadingAnchor.constraint(
                equalTo: document.leadingAnchor,
                constant: SettingsStyle.space8),
            content.trailingAnchor.constraint(
                equalTo: document.trailingAnchor,
                constant: -SettingsStyle.space8),
            content.topAnchor.constraint(
                equalTo: document.topAnchor,
                constant: SettingsStyle.space8),
            content.bottomAnchor.constraint(
                equalTo: document.bottomAnchor,
                constant: -SettingsStyle.space8),
            document.widthAnchor.constraint(
                equalTo: scrollView.contentView.widthAnchor)
        ])
    }

    func render(
        diagnostics: SettingsDiagnosticsViewModel,
        recovery: SettingsRecoveryViewModel
    ) {
        loadViewIfNeeded()
        renderRows(diagnostics.rows)
        errorLabel.stringValue = diagnostics.errorMessage ?? ""
        errorLabel.isHidden = diagnostics.errorMessage == nil
        recoveryStack.isHidden = !recovery.isVisible
        recoveryMessage.stringValue = recovery.message
            ?? "Use an available recovery action, then refresh state."
        retryButton.isHidden = !recovery.canRetry
        resetButton.isHidden = !recovery.canResetInvalidSettings
        revealLogURL = recovery.revealLogURL
        revealButton.isHidden = recovery.revealLogURL == nil
    }

    private func renderRows(_ rows: [SettingsDiagnosticRow]) {
        for view in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for row in rows {
            let key = SettingsStyle.sectionLabel(row.label)
            key.alignment = .right
            key.widthAnchor.constraint(
                equalToConstant: SettingsStyle.diagnosticLabelWidth
            ).isActive = true
            let value = SettingsStyle.label(row.value)
            value.isSelectable = true
            if ["Endpoint", "Protocol", "Voices Directory", "Logs"]
                .contains(row.label) {
                value.font = SettingsStyle.codeFont
            }
            value.setAccessibilityLabel("\(row.label): \(row.value)")
            let line = SettingsStyle.horizontalStack(
                spacing: SettingsStyle.space4)
            line.alignment = .firstBaseline
            line.addArrangedSubview(key)
            line.addArrangedSubview(value)
            rowsStack.addArrangedSubview(line)
        }
    }

    @objc private func retryClicked() {
        onAction?(.retryStartup)
    }

    @objc private func resetClicked() {
        onAction?(.resetInvalidSettings)
    }

    @objc private func revealClicked() {
        guard let revealLogURL else { return }
        onRevealLogs?(revealLogURL)
    }
}
