import AppKit

/// Menu row hosting a labeled slider (NSMenuItem text can't hold one).
/// Continuous dragging updates the value label live but the change callback
/// is debounced, so a drag lands one config write, not fifty.
@MainActor
final class SliderMenuView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private var debounce: Timer?

    var onChange: ((Double) -> Void)?

    init(title: String, min: Double, max: Double) {
        slider = NSSlider(value: 1.0, minValue: min, maxValue: max,
                          target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 46))

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 13)
        titleLabel.frame = NSRect(x: 14, y: 26, width: 160, height: 17)

        valueLabel.font = .menuFont(ofSize: 13)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 186, y: 26, width: 60, height: 17)

        slider.frame = NSRect(x: 14, y: 4, width: 232, height: 20)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)
        showValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var value: Double {
        get { slider.doubleValue }
        set {
            // A pending debounce means the user just dragged; don't let a
            // stale server echo yank the knob back.
            guard debounce == nil else { return }
            slider.doubleValue = newValue
            showValue()
        }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set {
            slider.isEnabled = newValue
            titleLabel.textColor = newValue ? .labelColor : .disabledControlTextColor
        }
    }

    @objc private func sliderMoved() {
        showValue()
        debounce?.invalidate()
        // Menu tracking runs the run loop in event-tracking mode, where
        // default-mode timers never fire; .common covers it.
        let timer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.debounce = nil
                self.onChange?(self.slider.doubleValue)
            }
        }
        debounce = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showValue() {
        valueLabel.stringValue = String(format: "%.1f×", slider.doubleValue)
    }
}
