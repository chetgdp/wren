import AppKit

@MainActor
final class SettingsContentViewController: NSTabViewController {
    var onAction: ((SettingsWindowAction) -> Void)? {
        didSet { connectActions() }
    }
    var onAddVoice: (() -> Void)? {
        didSet { voicesController.onAddVoice = onAddVoice }
    }
    var onRevealLogs: ((URL) -> Void)? {
        didSet { diagnosticsController.onRevealLogs = onRevealLogs }
    }

    private let voicesController = SettingsVoicesViewController()
    private let outputController = SettingsOutputViewController()
    private let diagnosticsController = SettingsDiagnosticsViewController()

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        addTab(
            title: "Voices",
            symbol: "waveform",
            controller: voicesController)
        addTab(
            title: "Output",
            symbol: "hifispeaker",
            controller: outputController)
        addTab(
            title: "Diagnostics",
            symbol: "stethoscope",
            controller: diagnosticsController)
        connectActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func render(_ model: SettingsViewModel) {
        voicesController.render(model)
        outputController.render(model.output)
        diagnosticsController.render(
            diagnostics: model.diagnostics,
            recovery: model.recovery)
    }

    private func addTab(
        title: String,
        symbol: String,
        controller: NSViewController
    ) {
        let item = NSTabViewItem(viewController: controller)
        item.label = title
        item.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title)
        addTabViewItem(item)
    }

    private func connectActions() {
        voicesController.onAction = onAction
        voicesController.onAddVoice = onAddVoice
        outputController.onAction = onAction
        diagnosticsController.onAction = onAction
        diagnosticsController.onRevealLogs = onRevealLogs
    }
}
