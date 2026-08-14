import AppKit

@MainActor
final class SettingsVoicesViewController: NSViewController {
    var onAction: ((SettingsWindowAction) -> Void)?
    var onAddVoice: (() -> Void)?

    private var model: SettingsViewModel?
    private var selectedID: String?

    private let titleLabel = SettingsStyle.label(
        "Voice Library",
        font: SettingsStyle.titleFont)
    private let subtitleLabel = SettingsStyle.detailLabel(
        "The active checkmark always reflects the daemon's current voice.")
    private let noticeLabel = SettingsStyle.detailLabel()
    private let errorLabel = SettingsStyle.detailLabel()
    private let tableView = NSTableView()
    private let listScrollView = NSScrollView()
    private let placeholderLabel = SettingsStyle.detailLabel()
    private let loadingIndicator = NSProgressIndicator()

    private let detailTitle = SettingsStyle.label(
        "",
        font: SettingsStyle.titleFont)
    private let detailStatus = SettingsStyle.detailLabel()
    private let detailID = SettingsStyle.detailLabel()
    private let pendingLabel = SettingsStyle.detailLabel()
    private let renameField = NSTextField()
    private let renameButton = SettingsStyle.actionButton(
        "Save Name",
        target: nil,
        action: nil)
    private let activateButton = SettingsStyle.actionButton(
        "Use Voice",
        target: nil,
        action: nil)
    private let deleteButton = SettingsStyle.actionButton(
        "Delete…",
        target: nil,
        action: nil)
    private let issuesStack = SettingsStyle.verticalStack(
        spacing: SettingsStyle.space2)
    private let detailStack = SettingsStyle.verticalStack()
    private let detailScrollView = NSScrollView()

    private lazy var addButton = SettingsStyle.actionButton(
        "Add Voice…",
        target: self,
        action: #selector(addVoiceClicked))

    override func loadView() {
        view = NSView()
        configureHeader()
        configureList()
        configureDetail()
        configureLayout()
    }

    func render(_ model: SettingsViewModel) {
        loadViewIfNeeded()
        self.model = model
        noticeLabel.stringValue = model.libraryNotice ?? ""
        noticeLabel.isHidden = model.libraryNotice == nil
        errorLabel.stringValue = model.voiceError ?? ""
        errorLabel.isHidden = model.voiceError == nil
        errorLabel.textColor = .systemRed
        addButton.isHidden = !model.addVoiceVisible
        addButton.isEnabled = model.canAddVoice

        let priorSelection = selectedID
        if let priorSelection,
           model.voice(id: priorSelection) != nil {
            selectedID = priorSelection
        } else {
            selectedID = model.activeVoiceID ?? model.voices.first?.id
        }
        tableView.reloadData()
        selectRenderedRow()
        renderPlaceholder(model.voiceLoadState)
        renderDetail()
    }

    private func configureHeader() {
        subtitleLabel.setContentHuggingPriority(
            .defaultLow,
            for: .horizontal)
        addButton.toolTip = "Add a local WAV and transcript pair"
        addButton.setAccessibilityLabel("Add Voice")
    }

    private func configureList() {
        let column = NSTableColumn(identifier: .voiceColumn)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = SettingsStyle.rowHeight
        tableView.intercellSpacing = NSSize(
            width: 0,
            height: SettingsStyle.space1)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsEmptySelection = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.setAccessibilityLabel("Voice Library")

        listScrollView.documentView = tableView
        listScrollView.hasVerticalScroller = true
        listScrollView.drawsBackground = false
        listScrollView.borderType = .noBorder
        listScrollView.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.alignment = .center
        placeholderLabel.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal)
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
    }

    private func configureDetail() {
        renameField.placeholderString = "Display name"
        renameField.delegate = self
        renameField.setAccessibilityLabel("Voice Display Name")
        renameField.widthAnchor.constraint(
            equalToConstant: SettingsStyle.fieldWidth).isActive = true

        renameButton.target = self
        renameButton.action = #selector(renameClicked)
        activateButton.target = self
        activateButton.action = #selector(activateClicked)
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        deleteButton.hasDestructiveAction = true

        pendingLabel.textColor = .controlAccentColor
        detailID.font = SettingsStyle.codeFont

        let renameRow = SettingsStyle.horizontalStack()
        renameRow.addArrangedSubview(renameField)
        renameRow.addArrangedSubview(renameButton)

        let actions = SettingsStyle.horizontalStack()
        actions.addArrangedSubview(activateButton)
        actions.addArrangedSubview(deleteButton)

        detailStack.addArrangedSubview(detailTitle)
        detailStack.addArrangedSubview(detailStatus)
        detailStack.addArrangedSubview(detailID)
        detailStack.addArrangedSubview(pendingLabel)
        detailStack.setCustomSpacing(
            SettingsStyle.space6,
            after: pendingLabel)
        detailStack.addArrangedSubview(
            SettingsStyle.sectionLabel("Display Name"))
        detailStack.addArrangedSubview(renameRow)
        detailStack.setCustomSpacing(
            SettingsStyle.space6,
            after: renameRow)
        detailStack.addArrangedSubview(
            SettingsStyle.sectionLabel("Profile Issues"))
        detailStack.addArrangedSubview(issuesStack)
        detailStack.setCustomSpacing(
            SettingsStyle.space6,
            after: issuesStack)
        detailStack.addArrangedSubview(actions)

        let document = NSView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detailStack)
        detailScrollView.documentView = document
        detailScrollView.hasVerticalScroller = true
        detailScrollView.drawsBackground = false
        detailScrollView.borderType = .noBorder
        detailScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            detailStack.leadingAnchor.constraint(
                equalTo: document.leadingAnchor,
                constant: SettingsStyle.space6),
            detailStack.trailingAnchor.constraint(
                equalTo: document.trailingAnchor,
                constant: -SettingsStyle.space6),
            detailStack.topAnchor.constraint(
                equalTo: document.topAnchor,
                constant: SettingsStyle.space6),
            detailStack.bottomAnchor.constraint(
                equalTo: document.bottomAnchor,
                constant: -SettingsStyle.space6),
            document.widthAnchor.constraint(
                equalTo: detailScrollView.contentView.widthAnchor)
        ])
    }

    private func configureLayout() {
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        let headerText = SettingsStyle.verticalStack(
            spacing: SettingsStyle.space1)
        headerText.addArrangedSubview(titleLabel)
        headerText.addArrangedSubview(subtitleLabel)
        let header = SettingsStyle.horizontalStack(
            spacing: SettingsStyle.space4)
        header.addArrangedSubview(headerText)
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(addButton)

        let listContainer = NSView()
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(listScrollView)
        let placeholder = SettingsStyle.verticalStack()
        placeholder.alignment = .centerX
        placeholder.addArrangedSubview(loadingIndicator)
        placeholder.addArrangedSubview(placeholderLabel)
        listContainer.addSubview(placeholder)

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(listContainer)
        splitView.addArrangedSubview(detailScrollView)

        view.addSubview(header)
        view.addSubview(noticeLabel)
        view.addSubview(errorLabel)
        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(
                equalTo: view.leadingAnchor,
                constant: SettingsStyle.space6),
            header.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -SettingsStyle.space6),
            header.topAnchor.constraint(
                equalTo: view.topAnchor,
                constant: SettingsStyle.space6),
            noticeLabel.leadingAnchor.constraint(
                equalTo: header.leadingAnchor),
            noticeLabel.trailingAnchor.constraint(
                equalTo: header.trailingAnchor),
            noticeLabel.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: SettingsStyle.space3),
            errorLabel.leadingAnchor.constraint(
                equalTo: header.leadingAnchor),
            errorLabel.trailingAnchor.constraint(
                equalTo: header.trailingAnchor),
            errorLabel.topAnchor.constraint(
                equalTo: noticeLabel.bottomAnchor,
                constant: SettingsStyle.space2),
            splitView.leadingAnchor.constraint(
                equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(
                equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(
                equalTo: errorLabel.bottomAnchor,
                constant: SettingsStyle.space4),
            splitView.bottomAnchor.constraint(
                equalTo: view.bottomAnchor),
            listContainer.widthAnchor.constraint(
                equalToConstant: SettingsStyle.voiceListWidth),
            listScrollView.leadingAnchor.constraint(
                equalTo: listContainer.leadingAnchor),
            listScrollView.trailingAnchor.constraint(
                equalTo: listContainer.trailingAnchor),
            listScrollView.topAnchor.constraint(
                equalTo: listContainer.topAnchor),
            listScrollView.bottomAnchor.constraint(
                equalTo: listContainer.bottomAnchor),
            placeholder.centerXAnchor.constraint(
                equalTo: listContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(
                equalTo: listContainer.centerYAnchor),
            placeholder.widthAnchor.constraint(
                lessThanOrEqualTo: listContainer.widthAnchor,
                constant: -SettingsStyle.space6)
        ])
    }

    private func selectRenderedRow() {
        guard let selectedID,
              let index = model?.voices.firstIndex(
                where: { $0.id == selectedID })
        else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(
            IndexSet(integer: index),
            byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    private func renderPlaceholder(
        _ state: SettingsVoiceLoadState
    ) {
        switch state {
        case .loading:
            placeholderLabel.stringValue = "Loading Voice Library…"
            loadingIndicator.startAnimation(nil)
            listScrollView.isHidden = true
            placeholderLabel.isHidden = false
        case .empty:
            placeholderLabel.stringValue = model?.addVoiceVisible == true
                ? "No voices yet. Add a WAV and transcript to begin."
                : "No voice profiles were reported. Check Diagnostics."
            loadingIndicator.stopAnimation(nil)
            listScrollView.isHidden = true
            placeholderLabel.isHidden = false
        case .loaded:
            loadingIndicator.stopAnimation(nil)
            listScrollView.isHidden = false
            placeholderLabel.isHidden = true
        }
    }

    private func renderDetail() {
        guard let row = model?.voice(id: selectedID) else {
            detailStack.isHidden = true
            return
        }
        detailStack.isHidden = false
        detailTitle.stringValue = row.displayName
        let active = row.isActive ? " · Active" : ""
        detailStatus.stringValue = "\(row.statusTitle)\(active)"
        detailStatus.textColor = statusColor(row.status)
        detailID.stringValue = "Stable ID: \(row.id)"
        pendingLabel.stringValue = row.pendingTitle ?? ""
        pendingLabel.isHidden = row.pendingTitle == nil
        if view.window?.firstResponder !== renameField.currentEditor() {
            renameField.stringValue = row.displayName
        }
        renameField.isEnabled = row.canRename
        activateButton.isEnabled = row.canActivate
        deleteButton.isEnabled = row.canDelete
        updateRenameButton(row)
        renderIssues(row.issues)
    }

    private func renderIssues(_ issues: [SettingsVoiceIssue]) {
        for view in issuesStack.arrangedSubviews {
            issuesStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if issues.isEmpty {
            issuesStack.addArrangedSubview(
                SettingsStyle.detailLabel("No issues reported."))
            return
        }
        for issue in issues {
            let group = SettingsStyle.verticalStack(
                spacing: SettingsStyle.space1)
            group.addArrangedSubview(SettingsStyle.label(issue.title))
            let diagnostic = SettingsStyle.detailLabel(issue.diagnostic)
            diagnostic.font = SettingsStyle.codeFont
            group.addArrangedSubview(diagnostic)
            issuesStack.addArrangedSubview(group)
        }
    }

    private func updateRenameButton(_ row: SettingsVoiceRow) {
        let normalized = SettingsVoiceNameValidation.normalized(
            renameField.stringValue)
        renameButton.isEnabled = row.canRename
            && normalized != nil
            && normalized != row.displayName
    }

    private func statusColor(_ status: VoiceStatus) -> NSColor {
        switch status {
        case .ready:
            return .secondaryLabelColor
        case .incomplete:
            return .systemOrange
        case .invalid:
            return .systemRed
        }
    }

    @objc private func addVoiceClicked() {
        guard model?.canAddVoice == true else { return }
        onAddVoice?()
    }

    @objc private func activateClicked() {
        guard let row = model?.voice(id: selectedID),
              row.canActivate
        else { return }
        onAction?(.activateVoice(id: row.id))
    }

    @objc private func renameClicked() {
        guard let row = model?.voice(id: selectedID),
              row.canRename,
              let name = SettingsVoiceNameValidation.normalized(
                renameField.stringValue),
              name != row.displayName
        else { return }
        onAction?(.renameVoice(id: row.id, name: name))
    }

    @objc private func deleteClicked() {
        guard let row = model?.voice(id: selectedID),
              row.canDelete,
              let window = view.window
        else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(row.displayName)?"
        alert.informativeText = "This removes the voice from the library. "
            + "It cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard response == .alertFirstButtonReturn else { return }
                self?.onAction?(.deleteVoice(id: row.id))
            }
        }
    }
}

extension SettingsVoicesViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model?.voices.count ?? 0
    }
}

extension SettingsVoicesViewController: NSTableViewDelegate {
    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let voice = model?.voices[row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier.voiceCell
        let cell = tableView.makeView(
            withIdentifier: identifier,
            owner: self) as? SettingsVoiceCellView
            ?? SettingsVoiceCellView()
        cell.identifier = identifier
        cell.render(voice)
        return cell
    }

    func tableViewSelectionDidChange(
        _ notification: Notification
    ) {
        let row = tableView.selectedRow
        guard row >= 0, let voice = model?.voices[row] else { return }
        selectedID = voice.id
        renderDetail()
    }
}

extension SettingsVoicesViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let row = model?.voice(id: selectedID) else { return }
        updateRenameButton(row)
    }
}

@MainActor
private final class SettingsVoiceCellView: NSTableCellView {
    private let icon = NSImageView()
    private let nameLabel = SettingsStyle.label("")
    private let statusLabel = SettingsStyle.detailLabel()

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: SettingsStyle.space4,
            weight: .regular)
        let text = SettingsStyle.verticalStack(
            spacing: SettingsStyle.space1)
        text.addArrangedSubview(nameLabel)
        text.addArrangedSubview(statusLabel)
        let row = SettingsStyle.horizontalStack(
            spacing: SettingsStyle.space3)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(text)
        addSubview(row)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(
                equalToConstant: SettingsStyle.space4),
            icon.heightAnchor.constraint(
                equalToConstant: SettingsStyle.space4),
            row.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: SettingsStyle.space3),
            row.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -SettingsStyle.space3),
            row.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func render(_ voice: SettingsVoiceRow) {
        nameLabel.stringValue = voice.displayName
        let status = voice.pendingTitle ?? voice.statusTitle
        statusLabel.stringValue = voice.isActive
            ? "Active · \(status)"
            : status
        icon.image = NSImage(
            systemSymbolName: voice.symbolName,
            accessibilityDescription: statusLabel.stringValue)
        if voice.isActive {
            icon.contentTintColor = .controlAccentColor
        } else {
            switch voice.status {
            case .ready:
                icon.contentTintColor = .secondaryLabelColor
            case .incomplete:
                icon.contentTintColor = .systemOrange
            case .invalid:
                icon.contentTintColor = .systemRed
            }
        }
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let voiceColumn = Self("SettingsVoiceColumn")
    static let voiceCell = Self("SettingsVoiceCell")
}
