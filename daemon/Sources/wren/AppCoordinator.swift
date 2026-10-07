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

@MainActor
protocol LocalServerSupervising: AnyObject {
    var onChange: (@MainActor (LocalServerState) -> Void)? { get set }
    var state: LocalServerState { get }
    func start(host: String)
    func setEnabled(_ enabled: Bool)
    func hostChanged(_ host: String)
    func shutdown()
}

extension ServerSupervisor: LocalServerSupervising {}
@MainActor
final class AppCoordinator {
    private let store: WrenStore
    private let supervisor: any LocalServerSupervising
    private var menuBar: (any AppMenuPresenting)?
    private let makeSettingsWindow: @MainActor () -> any AppSettingsPresenting
    private let terminate: @MainActor () -> Void
    private var settingsWindow: (any AppSettingsPresenting)?

    private var didFinishLaunchingObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var isTerminating = false

    convenience init() {
        self.init(store: WrenStore(), supervisor: ServerSupervisor())
    }
    convenience init(
        store: WrenStore,
        menuBar: (any AppMenuPresenting)? = nil,
        makeSettingsWindow: (@MainActor () -> any AppSettingsPresenting)? = nil,
        terminate: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        }
    ) {
        self.init(
            store: store,
            supervisor: ServerSupervisor(),
            menuBar: menuBar,
            makeSettingsWindow: makeSettingsWindow,
            terminate: terminate
        )
    }

    init(
        store: WrenStore,
        supervisor: any LocalServerSupervising,
        menuBar: (any AppMenuPresenting)? = nil,
        makeSettingsWindow: (@MainActor () -> any AppSettingsPresenting)? = nil,
        terminate: @escaping @MainActor () -> Void = {
            NSApp.terminate(nil)
        }
    ) {
        self.store = store
        self.supervisor = supervisor
        self.menuBar = menuBar
        self.makeSettingsWindow = makeSettingsWindow ?? {
            let model = SettingsModel(state: store.state)
            model.onUpdateEndpoint = { host in
                store.updateEndpoint(host: host)
                supervisor.hostChanged(store.state.host)
            }
            model.onClaimActive = {
                Task { await store.claimActive() }
            }
            model.onActivateVoice = { id in
                Task { await store.activateVoice(id: id) }
            }
            model.onRenameVoice = { id, name in
                Task { await store.renameVoice(id: id, displayName: name) }
            }
            model.onDeleteVoice = { id in
                Task { await store.deleteVoice(id: id) }
            }
            model.onAddVoice = { id, name, url, transcript in
                await store.addVoice(
                    id: id,
                    name: name,
                    audioURL: url,
                    transcript: transcript
                )
            }
            model.onSetOutputDevice = { device in
                Task { await store.setOutputDevice(device) }
            }
            model.onSetEffects = { enabled in
                Task { await store.setEffects(enabled) }
            }
            return SettingsPanel(model: model)
        }
        self.terminate = terminate
    }

    deinit {
        if let didFinishLaunchingObserver {
            NotificationCenter.default.removeObserver(
                didFinishLaunchingObserver
            )
        }
        for observer in applicationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        for source in signalSources {
            source.cancel()
        }
    }

    func start() {
        didFinishLaunchingObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: NSApplication.shared,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let observer = self?.didFinishLaunchingObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self?.didFinishLaunchingObserver = nil
                }
                self?.deferWindowConstruction()
            }
        }

        applicationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: NSApplication.shared,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isTerminating else { return }
                    Task { @MainActor [weak self] in
                        await self?.store.claimIfNeeded()
                    }
                }
            }
        )

        applicationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: NSApplication.shared,
                queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isTerminating = true
                    self?.supervisor.shutdown()
                    self?.store.shutdown()
                }
            }
        )

        NSApplication.shared.setActivationPolicy(.accessory)

        // Install POSIX signal handlers to trigger clean NSApp termination.
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: sig,
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.terminate()
                }
            }
            source.resume()
            signalSources.append(source)
        }

        let bar = menuBar ?? WrenMenuBar()
        self.menuBar = bar

        supervisor.onChange = { [weak store] state in
            store?.setLocalServer(state)
        }
        supervisor.start(host: store.state.host)
        bar.onAction = { [weak self] action in
            self?.perform(action)
        }

        store.observe { [weak self] state in
            self?.menuBar?.render(state)
            self?.settingsWindow?.update(state: state)
        }
    }

    private func perform(_ action: WrenMenuBar.Action) {
        switch action {
        case .refresh:
            store.refreshLoginItem()
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
        case .setRunLocalServer(let enabled):
            supervisor.setEnabled(enabled)
        case .showSettings:
            showSettings()
        case .quit:
            terminate()
        }
    }

    private func showSettings() {
        ensureSettingsWindow()
        settingsWindow?.show()
    }

    private func ensureSettingsWindow() {
        guard settingsWindow == nil else { return }
        let window = makeSettingsWindow()
        window.update(state: store.state)
        settingsWindow = window
    }

    private func deferWindowConstruction() {
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ensureSettingsWindow()
            }
        }
        RunLoop.main.add(timer, forMode: .default)
    }
}
