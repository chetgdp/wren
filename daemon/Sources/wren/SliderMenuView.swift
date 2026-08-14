import AppKit

/// Native menu row for the one local Speaking Rate preference.
@MainActor
final class SliderMenuView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private var debounce: Timer?

    var onChange: ((Double) -> Void)?

    init(title: String, min: Double, max: Double) {
        slider = NSSlider(
            value: 1,
            minValue: min,
            maxValue: max,
            target: nil,
            action: nil
        )
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: WrenMenuMetrics.minimumWidth,
            height: WrenMenuMetrics.sliderHeight
        ))

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        titleLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setAccessibilityLabel(title)

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)
        showValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        let inset = WrenMenuMetrics.nativeInset
        let valueX = bounds.width
            - inset
            - WrenMenuMetrics.valueWidth
        slider.frame = NSRect(
            x: inset,
            y: WrenMenuMetrics.space4,
            width: max(0, bounds.width - inset * 2),
            height: WrenMenuMetrics.sliderTrackHeight
        )
        titleLabel.frame = NSRect(
            x: inset,
            y: slider.frame.maxY + WrenMenuMetrics.space2,
            width: max(
                0,
                valueX - inset - WrenMenuMetrics.space8
            ),
            height: WrenMenuMetrics.titleHeight
        )
        valueLabel.frame = NSRect(
            x: valueX,
            y: titleLabel.frame.minY,
            width: WrenMenuMetrics.valueWidth,
            height: WrenMenuMetrics.titleHeight
        )
    }

    var value: Double {
        get { slider.doubleValue }
        set {
            guard debounce == nil else { return }
            slider.doubleValue = newValue
            showValue()
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            titleLabel.textColor = newValue
                ? .labelColor
                : .disabledControlTextColor
            valueLabel.textColor = newValue
                ? .secondaryLabelColor
                : .disabledControlTextColor
        }
    }

    func setMenuWidth(_ width: CGFloat) {
        setFrameSize(NSSize(
            width: max(width, WrenMenuMetrics.minimumWidth),
            height: WrenMenuMetrics.sliderHeight
        ))
    }

    @objc private func sliderMoved() {
        let step = WrenMenuMetrics.speakingRateStep
        slider.doubleValue = (slider.doubleValue / step).rounded() * step
        showValue()
        debounce?.invalidate()
        let timer = Timer(
            timeInterval: WrenMenuMetrics.speakingRateDebounce,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.debounce = nil
                self.onChange?(self.slider.doubleValue)
            }
        }
        debounce = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showValue() {
        valueLabel.stringValue = String(
            format: "%.2f×",
            slider.doubleValue
        )
    }
}
