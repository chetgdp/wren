import AppKit

@MainActor
protocol SettingsWindowActionSink: AnyObject {
    func refresh() async
    func activateVoice(id: String) async
    func importVoice(
        wav: URL,
        transcript: URL,
        name: String,
        id: String
    ) async
    func renameVoice(id: String, name: String) async
    func deleteVoice(id: String) async
    func setOutputDevice(_ device: AudioOutputDevice?) async
    func retryStartup()
    func resetInvalidSettings()
}

extension WrenStore: SettingsWindowActionSink {}

enum SettingsWindowAction: Equatable, Sendable {
    case refresh
    case activateVoice(id: String)
    case importVoice(SettingsVoiceImport)
    case renameVoice(id: String, name: String)
    case deleteVoice(id: String)
    case setOutputDevice(AudioOutputDevice?)
    case retryStartup
    case resetInvalidSettings
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let stateProvider: @MainActor () -> AppState
    private let actionSink: any SettingsWindowActionSink
    private let contentController = SettingsContentViewController()
    private var currentState: AppState
    private var addVoiceWindow: NSWindow?
    private var addVoiceController: SettingsAddVoiceViewController?

    private(set) var presentedViewModel: SettingsViewModel

    init(
        stateProvider: @escaping @MainActor () -> AppState,
        actionSink: any SettingsWindowActionSink
    ) {
        let initialState = stateProvider()
        self.stateProvider = stateProvider
        self.actionSink = actionSink
        currentState = initialState
        presentedViewModel = SettingsViewModel(state: initialState)

        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: SettingsStyle.windowSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable
            ],
            backing: .buffered,
            defer: false)
        window.title = "Wren Settings"
        window.contentMinSize = SettingsStyle.minimumWindowSize
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.contentViewController = contentController
        contentController.onAction = { [weak self] action in
            Task { @MainActor [weak self] in
                await self?.perform(action)
            }
        }
        contentController.onAddVoice = { [weak self] in
            self?.presentAddVoice()
        }
        contentController.onRevealLogs = { [weak self] url in
            self?.revealLogs(at: url)
        }
        contentController.render(presentedViewModel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    func show() {
        update(state: stateProvider())
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor [weak self] in
            await self?.perform(.refresh)
        }
    }

    func update(state: AppState) {
        currentState = state
        presentedViewModel = SettingsViewModel(state: state)
        contentController.render(presentedViewModel)
        let ids = Set(presentedViewModel.voices.map(\.id))
        addVoiceController?.update(
            existingIDs: ids,
            importAvailable: presentedViewModel.addVoiceVisible,
            submissionEnabled: presentedViewModel.canAddVoice)
    }

    func perform(_ action: SettingsWindowAction) async {
        switch action {
        case .refresh:
            await actionSink.refresh()
        case .activateVoice(let id):
            await actionSink.activateVoice(id: id)
        case .importVoice(let submission):
            await actionSink.importVoice(
                wav: submission.wav,
                transcript: submission.transcript,
                name: submission.displayName,
                id: submission.id)
        case .renameVoice(let id, let name):
            await actionSink.renameVoice(id: id, name: name)
        case .deleteVoice(let id):
            await actionSink.deleteVoice(id: id)
        case .setOutputDevice(let device):
            await actionSink.setOutputDevice(device)
        case .retryStartup:
            actionSink.retryStartup()
        case .resetInvalidSettings:
            actionSink.resetInvalidSettings()
        }
    }

    private func presentAddVoice() {
        guard addVoiceWindow == nil,
              presentedViewModel.canAddVoice,
              let parent = window
        else { return }
        let ids = Set(presentedViewModel.voices.map(\.id))
        let controller = SettingsAddVoiceViewController(
            existingIDs: ids,
            importAvailable: true)
        let sheet = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: SettingsStyle.sheetSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        sheet.title = "Add Voice"
        sheet.contentViewController = controller
        controller.onCancel = { [weak self] in
            self?.dismissAddVoice()
        }
        controller.onSubmit = { [weak self] submission in
            guard let self else { return }
            self.dismissAddVoice()
            Task { @MainActor [weak self] in
                await self?.perform(.importVoice(submission))
            }
        }
        addVoiceController = controller
        addVoiceWindow = sheet
        parent.beginSheet(sheet)
    }

    private func dismissAddVoice() {
        guard let sheet = addVoiceWindow else { return }
        window?.endSheet(sheet)
        sheet.orderOut(nil)
        addVoiceWindow = nil
        addVoiceController = nil
    }

    private func revealLogs(at url: URL) {
        guard presentedViewModel.recovery.revealLogURL == url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
