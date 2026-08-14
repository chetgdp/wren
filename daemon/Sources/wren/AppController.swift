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

/// Composes the immutable state owner with native AppKit renderers.
@MainActor
final class AppController {
    private let store: WrenStore
    private let menuBar: any AppMenuPresenting
    private let makeSettingsWindow: @MainActor () ->
        any AppSettingsPresenting
    private let revealLogs: @MainActor (URL) -> Void
    private let terminate: @MainActor () -> Void
    private var settingsWindow: (any AppSettingsPresenting)?
    private var terminationObserver: NSObjectProtocol?

    convenience init() {
        let paths = WrenPaths.standard()
        let host = DaemonClient.resolveHost(flag: nil)
        let endpoint = URL(string: "http://\(host)")!
        let token = DaemonClient.resolveToken(flag: nil)
        let factory = WrenSessionFactory(paths: paths, token: token)
        let store = WrenStore(
            endpoint: endpoint,
            sessionFactory: factory
        )
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
        makeSettingsWindow: (
            @MainActor () -> any AppSettingsPresenting
        )? = nil,
        revealLogs: @escaping @MainActor (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        },
        terminate: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        }
    ) {
        self.store = store
        self.menuBar = menuBar
        self.makeSettingsWindow = makeSettingsWindow ?? {
            SettingsWindowController(
                stateProvider: { store.state },
                actionSink: store
            )
        }
        self.revealLogs = revealLogs
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
                guard let store else { return }
                await store.refreshLocalPreferences()
                await store.refresh()
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
        case .showSettings, .addVoice, .manageVoices:
            showSettings()
        case .retryStartup:
            store.retryStartup()
        case .resetInvalidSettings:
            store.resetInvalidSettings()
        case .revealLogs(let url):
            guard store.state.manager?.ownership == .managed,
                  store.state.managerRecovery.revealLogURL == url
            else { return }
            revealLogs(url)
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
