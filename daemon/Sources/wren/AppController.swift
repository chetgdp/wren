import AppKit
import Foundation

@MainActor
protocol AppMenuPresenting: AnyObject {
    var onAction: ((WrenMenuBar.Action) -> Void)? { get set }
    func render(_ state: AppState)
}

extension WrenMenuBar: AppMenuPresenting {}

@MainActor
protocol AppSettingsPresenting: AnyObject {
    func show()
    func update(state: AppState)
}

extension SettingsWindowController: AppSettingsPresenting {}

@MainActor
final class AppController {
    private let store: WrenStore
    private let menuBar: any AppMenuPresenting
    private let makeSettingsWindow: @MainActor () -> any AppSettingsPresenting
    private let terminate: @MainActor () -> Void
    private var settingsWindow: (any AppSettingsPresenting)?
    private var terminationObserver: NSObjectProtocol?

    convenience init() {
        let store = WrenStore()
        self.init(
            store: store,
            menuBar: WrenMenuBar(),
            notificationCenter: .default
        )
    }

    init(
        store: WrenStore,
        menuBar: any AppMenuPresenting,
        notificationCenter: NotificationCenter,
        makeSettingsWindow: (@MainActor () -> any AppSettingsPresenting)? = nil,
        terminate: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        }
    ) {
        self.store = store
        self.menuBar = menuBar
        self.makeSettingsWindow = makeSettingsWindow ?? {
            SettingsWindowController(state: store.state, actionSink: store)
        }
        self.terminate = terminate

        menuBar.onAction = { [weak self] action in
            self?.perform(action)
        }
        store.observe { [weak self] state in
            self?.menuBar.render(state)
            self?.settingsWindow?.update(state: state)
        }

        terminationObserver = notificationCenter.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak store] _ in
            MainActor.assumeIsolated {
                store?.shutdown()
            }
        }
    }
}

private extension AppController {
    func perform(_ action: WrenMenuBar.Action) {
        switch action {
        case .refresh:
            Task { @MainActor [weak store] in
                await store?.pollState()
            }
        case .claimActive:
            Task { @MainActor [weak store] in
                await store?.claimActive()
            }
        case .activateVoice(let id):
            Task { @MainActor [weak store] in
                await store?.activateVoice(id: id)
            }
        case .setSpeakingRate(let rate):
            store.setSpeakingRate(rate)
        case .setEffects(let enabled):
            Task { @MainActor [weak store] in
                await store?.setEffects(enabled)
            }
        case .setOutputDevice(let device):
            Task { @MainActor [weak store] in
                await store?.setOutputDevice(device)
            }
        case .setPaused(let desired):
            Task { @MainActor [weak store] in
                await store?.setPaused(desired)
            }
        case .stopSpeaking:
            Task { @MainActor [weak store] in
                await store?.stopSpeaking()
            }
        case .setLaunchAtLogin(let enabled):
            store.setLaunchAtLogin(enabled)
        case .showSettings:
            showSettings()
        case .quit:
            terminate()
        }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = makeSettingsWindow()
            window.update(state: store.state)
            settingsWindow = window
        }
        settingsWindow?.show()
    }
}
