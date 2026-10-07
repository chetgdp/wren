import AppKit
import SwiftUI

@MainActor
enum WrenMenuMetrics {
    static let minimumWidth: CGFloat = 292
    static let nativeInset: CGFloat = 14
    static let space2: CGFloat = 2
    static let space4: CGFloat = 4
    static let space8: CGFloat = 8
    static let titleHeight: CGFloat = 17
    static let detailHeight: CGFloat = 14
    static let statusHeight: CGFloat = 44
    static let progressHeight: CGFloat = 56
    static let progressBarHeight: CGFloat = 12
    static let messageHeight: CGFloat = 36
    static let loginHeight: CGFloat = 32
    static let sliderHeight: CGFloat = 46
    static let sliderTrackHeight: CGFloat = 20
    static let valueWidth: CGFloat = 62
    static let switchWidth: CGFloat = 54
    static let switchHeight: CGFloat = 24
    static let switchThumbWidth: CGFloat = 32
    static let switchThumbHeight: CGFloat = 20
    static let warningIconSize: CGFloat = 14
    static let speakingRateStep = 0.05
    static let speakingRateDebounce: TimeInterval = 0.3
    static let transitionDuration = 0.15
}

@MainActor
final class WrenMenuStatusView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: WrenMenuMetrics.minimumWidth,
            height: WrenMenuMetrics.statusHeight
        ))
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .menuFont(
            ofSize: NSFont.smallSystemFontSize
        )
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)
        addSubview(detailLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        let inset = WrenMenuMetrics.nativeInset
        let width = max(0, bounds.width - inset * 2)
        detailLabel.frame = NSRect(
            x: inset,
            y: WrenMenuMetrics.space4,
            width: width,
            height: WrenMenuMetrics.detailHeight
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: detailLabel.frame.maxY + WrenMenuMetrics.space2,
            width: width,
            height: WrenMenuMetrics.titleHeight
        )
    }

    func render(_ status: WrenMenuModel.Status) {
        titleLabel.stringValue = status.title
        detailLabel.stringValue = status.detail
        switch status.tone {
        case .normal:
            titleLabel.textColor = .labelColor
            detailLabel.textColor = .secondaryLabelColor
        case .warning:
            titleLabel.textColor = .labelColor
            detailLabel.textColor = .systemOrange
        case .error:
            titleLabel.textColor = .systemRed
            detailLabel.textColor = .secondaryLabelColor
        }
        let accessibilityText = status.detail.isEmpty
            ? status.title
            : "\(status.title). \(status.detail)"
        setAccessibilityLabel(accessibilityText)
        toolTip = accessibilityText
    }

    func setMenuWidth(_ width: CGFloat) {
        setFrameSize(NSSize(
            width: max(width, WrenMenuMetrics.minimumWidth),
            height: WrenMenuMetrics.statusHeight
        ))
    }
}


@MainActor
final class WrenMenuMessageView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String, tone: WrenMenuModel.Tone) {
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: WrenMenuMetrics.minimumWidth,
            height: WrenMenuMetrics.messageHeight
        ))
        label.font = .menuFont(
            ofSize: NSFont.smallSystemFontSize
        )
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        render(text: text, tone: tone)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        let inset = WrenMenuMetrics.nativeInset
        label.frame = NSRect(
            x: inset,
            y: WrenMenuMetrics.space4,
            width: max(0, bounds.width - inset * 2),
            height: bounds.height - WrenMenuMetrics.space8
        )
    }

    func render(text: String, tone: WrenMenuModel.Tone) {
        label.stringValue = text
        switch tone {
        case .normal:
            label.textColor = .secondaryLabelColor
        case .warning:
            label.textColor = .systemOrange
        case .error:
            label.textColor = .systemRed
        }
        setAccessibilityLabel(text)
        toolTip = text
    }
}

@MainActor
final class WrenMenuLoginView: NSView {
    private final class ToggleModel: ObservableObject {
        @Published var isOn = false
        @Published var isEnabled = false
    }

    private struct LoginSwitch: View {
        @ObservedObject var model: ToggleModel

        var body: some View {
            Capsule()
                .fill(trackColor)
                .frame(
                    width: WrenMenuMetrics.switchWidth,
                    height: WrenMenuMetrics.switchHeight
                )
                .overlay(
                    alignment: model.isOn ? .trailing : .leading
                ) {
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(
                            width: WrenMenuMetrics.switchThumbWidth,
                            height: WrenMenuMetrics.switchThumbHeight
                        )
                        .padding(WrenMenuMetrics.space2)
                        .shadow(
                            color: Color(nsColor: .shadowColor)
                                .opacity(0.25),
                            radius: 1,
                            y: 0.5
                        )
                }
                .opacity(model.isEnabled ? 1 : 0.5)
                .animation(nil, value: model.isOn)
        }

        private var trackColor: Color {
            if model.isOn {
                return Color(nsColor: .controlAccentColor)
            }
            return Color(nsColor: .quaternaryLabelColor)
        }
    }
    private let titleLabel: NSTextField
    private let warningView = NSImageView()
    private let model: ToggleModel
    private let host: NSHostingView<LoginSwitch>
    var onToggle: ((Bool) -> Void)?

    init(title: String = "Launch at Login") {
        let model = ToggleModel()
        self.model = model
        titleLabel = NSTextField(labelWithString: title)
        host = NSHostingView(
            rootView: LoginSwitch(model: model)
        )
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: WrenMenuMetrics.minimumWidth,
            height: WrenMenuMetrics.loginHeight
        ))
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        warningView.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "\(title) warning"
        )
        warningView.contentTintColor = .systemOrange
        warningView.isHidden = true
        addSubview(titleLabel)
        addSubview(warningView)
        addSubview(host)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        let inset = WrenMenuMetrics.nativeInset
        let switchSize = host.fittingSize
        host.frame = NSRect(
            x: bounds.width - inset - switchSize.width,
            y: (bounds.height - switchSize.height) / 2,
            width: switchSize.width,
            height: switchSize.height
        )
        warningView.frame = NSRect(
            x: host.frame.minX
                - WrenMenuMetrics.warningIconSize
                - WrenMenuMetrics.space8,
            y: (bounds.height - WrenMenuMetrics.warningIconSize) / 2,
            width: WrenMenuMetrics.warningIconSize,
            height: WrenMenuMetrics.warningIconSize
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: (bounds.height - WrenMenuMetrics.titleHeight) / 2,
            width: max(
                0,
                warningView.frame.minX - inset
                    - WrenMenuMetrics.space8
            ),
            height: WrenMenuMetrics.titleHeight
        )
    }
    func render(_ login: WrenMenuModel.Login) {
        render(
            isOn: login.isOn,
            isEnabled: login.isEnabled,
            detail: login.error,
            tone: login.error == nil ? .normal : .warning
        )
    }

    func render(
        isOn: Bool,
        isEnabled: Bool,
        detail: String?,
        tone: WrenMenuModel.Tone = .normal
    ) {
        model.isOn = isOn
        model.isEnabled = isEnabled
        titleLabel.textColor = isEnabled
            ? .labelColor
            : .disabledControlTextColor
        warningView.isHidden = detail == nil
        warningView.toolTip = detail
        switch tone {
        case .error:
            warningView.contentTintColor = .systemRed
        case .warning:
            warningView.contentTintColor = .systemOrange
        case .normal:
            warningView.contentTintColor = .secondaryLabelColor
        }
        toolTip = detail
        setAccessibilityValue(isOn)
        setAccessibilityEnabled(isEnabled)
        layoutSubtreeIfNeeded()
    }

    func setMenuWidth(_ width: CGFloat) {
        setFrameSize(NSSize(
            width: max(width, WrenMenuMetrics.minimumWidth),
            height: WrenMenuMetrics.loginHeight
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard model.isEnabled,
              host.frame.insetBy(
                dx: -WrenMenuMetrics.space4,
                dy: -WrenMenuMetrics.space4
              ).contains(point)
        else { return }
        onToggle?(!model.isOn)
    }

    override func accessibilityPerformPress() -> Bool {
        guard model.isEnabled else { return false }
        onToggle?(!model.isOn)
        return true
    }
}
