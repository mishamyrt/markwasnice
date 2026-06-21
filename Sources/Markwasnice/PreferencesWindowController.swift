import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private var settings: EditorSettings
    private let onChange: (EditorSettings) -> Void
    private let textSizeSlider = NSSlider(
        value: 1, minValue: 0.6, maxValue: 3, target: nil, action: nil)
    private let smallTextSizeLabel = NSTextField(labelWithString: "A")
    private let largeTextSizeLabel = NSTextField(labelWithString: "A")
    private let widthPopup = NSPopUpButton()

    init(settings: EditorSettings, onChange: @escaping (EditorSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
        let window = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.contentView = contentView
        window.isReleasedWhenClosed = false

        super.init(window: window)

        configureControls(in: contentView)
    }

    func update(settings: EditorSettings) {
        self.settings = settings
        textSizeSlider.doubleValue = Double(settings.textSizeScale)
        widthPopup.selectItem(withTitle: String(settings.maxTextColumns))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func textSizeChanged(_ sender: NSSlider) {
        settings.textSizeScale = CGFloat(sender.doubleValue)
        onChange(settings)
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        guard let value = Int(sender.titleOfSelectedItem ?? "") else {
            return
        }

        settings.maxTextColumns = value
        onChange(settings)
    }

    private func configureControls(in contentView: NSView) {
        let textSizeLabel = NSTextField(labelWithString: "Text Size")
        let widthLabel = NSTextField(labelWithString: "Text Width")
        let widthCaption = NSTextField(labelWithString: "characters")

        textSizeSlider.target = self
        textSizeSlider.action = #selector(textSizeChanged(_:))
        textSizeSlider.doubleValue = Double(settings.textSizeScale)
        textSizeSlider.numberOfTickMarks = 14
        textSizeSlider.allowsTickMarkValuesOnly = true

        smallTextSizeLabel.font = LilexFontProvider.regular(size: 11)
        largeTextSizeLabel.font = LilexFontProvider.regular(size: 18)

        for option in EditorSettings.maxTextWidthOptions {
            widthPopup.addItem(withTitle: String(option))
        }
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.selectItem(withTitle: String(settings.maxTextColumns))

        for view in [
            textSizeLabel, smallTextSizeLabel, textSizeSlider, largeTextSizeLabel, widthLabel,
            widthPopup, widthCaption,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            textSizeLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 24),
            textSizeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 30),
            textSizeLabel.widthAnchor.constraint(equalToConstant: 90),

            smallTextSizeLabel.leadingAnchor.constraint(
                equalTo: textSizeLabel.trailingAnchor, constant: 12),
            smallTextSizeLabel.centerYAnchor.constraint(equalTo: textSizeLabel.centerYAnchor),

            textSizeSlider.leadingAnchor.constraint(
                equalTo: smallTextSizeLabel.trailingAnchor, constant: 8),
            textSizeSlider.trailingAnchor.constraint(
                equalTo: largeTextSizeLabel.leadingAnchor, constant: -8),
            textSizeSlider.centerYAnchor.constraint(equalTo: textSizeLabel.centerYAnchor),

            largeTextSizeLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -24),
            largeTextSizeLabel.centerYAnchor.constraint(equalTo: textSizeLabel.centerYAnchor),

            widthLabel.leadingAnchor.constraint(equalTo: textSizeLabel.leadingAnchor),
            widthLabel.topAnchor.constraint(equalTo: textSizeLabel.bottomAnchor, constant: 28),
            widthLabel.widthAnchor.constraint(equalTo: textSizeLabel.widthAnchor),

            widthPopup.leadingAnchor.constraint(equalTo: widthLabel.trailingAnchor, constant: 12),
            widthPopup.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            widthPopup.widthAnchor.constraint(equalToConstant: 90),

            widthCaption.leadingAnchor.constraint(equalTo: widthPopup.trailingAnchor, constant: 8),
            widthCaption.centerYAnchor.constraint(equalTo: widthPopup.centerYAnchor),
        ])
    }

}
