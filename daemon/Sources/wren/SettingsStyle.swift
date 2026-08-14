import AppKit

@MainActor
enum SettingsStyle {
    static let unit: CGFloat = 4
    static let space1 = unit
    static let space2 = unit * 2
    static let space3 = unit * 3
    static let space4 = unit * 4
    static let space6 = unit * 6
    static let space8 = unit * 8

    static let windowSize = NSSize(width: 760, height: 600)
    static let minimumWindowSize = NSSize(width: 680, height: 520)
    static let sheetSize = NSSize(width: 520, height: 390)
    static let voiceListWidth: CGFloat = 280
    static let fieldWidth: CGFloat = 300
    static let diagnosticLabelWidth = unit * 32
    static let rowHeight: CGFloat = 48
    static let issueInset: CGFloat = space3

    static let titleFont = NSFont.systemFont(
        ofSize: 20,
        weight: .semibold)
    static let sectionFont = NSFont.systemFont(
        ofSize: NSFont.systemFontSize,
        weight: .semibold)
    static let bodyFont = NSFont.systemFont(
        ofSize: NSFont.systemFontSize)
    static let detailFont = NSFont.systemFont(
        ofSize: NSFont.smallSystemFontSize)
    static let codeFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular)

    static func label(
        _ text: String,
        font: NSFont? = nil,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font ?? bodyFont
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal)
        return label
    }

    static func detailLabel(_ text: String = "") -> NSTextField {
        label(
            text,
            font: detailFont,
            color: .secondaryLabelColor)
    }

    static func sectionLabel(_ text: String) -> NSTextField {
        label(text, font: sectionFont)
    }

    static func actionButton(
        _ title: String,
        target: AnyObject?,
        action: Selector?
    ) -> NSButton {
        let button = NSButton(
            title: title,
            target: target,
            action: action)
        button.bezelStyle = .rounded
        return button
    }

    static func verticalStack(
        spacing: CGFloat? = nil
    ) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing ?? space3
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func horizontalStack(
        spacing: CGFloat? = nil
    ) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing ?? space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}
