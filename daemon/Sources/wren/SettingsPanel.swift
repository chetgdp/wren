import AppKit
import SwiftUI

@MainActor
final class SettingsPanel: FloatingPanel {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let contentSize = NSSize(width: 560, height: 640)
        super.init(
            contentRect: NSRect(origin: .zero, size: contentSize),
            title: SettingsCopy.windowTitle
        )
        animationBehavior = .none
        let hostingView = NSHostingView(
            rootView: SettingsRootView(model: model)
        )
        // Keep SwiftUI's ideal scroll-view size from enlarging the panel.
        // Longer settings pages scroll within the same window bounds.
        hostingView.sizingOptions = []
        contentView = hostingView
        setContentSize(contentSize)
    }

    override func present() {
        present(destination: .server)
    }

    func present(destination: SettingsDestination) {
        model.selectDestination(destination)
        super.present()
    }
}


extension SettingsPanel: AppSettingsPresenting {
    func show() {
        present()
    }

    func update(state: AppState) {
        model.apply(state: state)
    }
}