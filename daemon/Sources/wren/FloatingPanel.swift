import AppKit

/// Shared base for panels in an accessory app. An accessory
/// app has no dock icon and cannot be reached with Cmd-Tab,
/// so panels can temporarily switch to .regular while visible
/// and revert on close. Settings opts out for immediate presentation.
@MainActor
class FloatingPanel: NSPanel {
    private var observers: [Any] = []

    override var canBecomeKey: Bool { true }
    var showsDockIcon: Bool { true }

    init(contentRect: NSRect, title: String) {
        super.init(
            contentRect: contentRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.title = title
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [
            .moveToActiveSpace,
            .fullScreenAuxiliary,
        ]

        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.level = .statusBar
                }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard self?.showsDockIcon == true else { return }
                    _ = NSApp.setActivationPolicy(.accessory)
                }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present() {
        if showsDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        if !isVisible { center() }
        level = .statusBar
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        if showsDockIcon {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
