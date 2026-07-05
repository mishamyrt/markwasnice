import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController {
    private var settings: EditorSettings
    private let onChange: (EditorSettings) -> Void
    private let textSizeSlider = NSSlider(
        value: 1, minValue: 0.05, maxValue: 1.95, target: nil, action: nil
    )
    private let smallTextSizeLabel = NSTextField(labelWithString: "A")
    private let largeTextSizeLabel = NSTextField(labelWithString: "A")
    private let widthPopup = NSPopUpButton()
    private let tabModePopup = NSPopUpButton()
    private let tabWidthPopup = NSPopUpButton()

    init(settings: EditorSettings, onChange: @escaping (EditorSettings) -> Void) {
        self.settings = settings
        self.onChange = onChange

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
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
        tabModePopup.selectItem(withTitle: title(for: settings.tabInsertionMode))
        tabWidthPopup.selectItem(withTitle: String(settings.tabWidth))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
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

    @objc private func tabModeChanged(_ sender: NSPopUpButton) {
        // The popup is populated from allCases in configureControls; decode
        // the selection through the same list.
        let modes = EditorSettings.TabInsertionMode.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else {
            return
        }

        settings.tabInsertionMode = modes[sender.indexOfSelectedItem]
        onChange(settings)
    }

    @objc private func tabWidthChanged(_ sender: NSPopUpButton) {
        guard let value = Int(sender.titleOfSelectedItem ?? "") else {
            return
        }

        settings.tabWidth = value
        onChange(settings)
    }

    private func configureControls(in contentView: NSView) {
        let textSizeLabel = NSTextField(labelWithString: "Text Size")
        let widthLabel = NSTextField(labelWithString: "Text Width")
        let widthCaption = NSTextField(labelWithString: "characters")
        let tabModeLabel = NSTextField(labelWithString: "Tab Inserts")
        let tabWidthLabel = NSTextField(labelWithString: "Tab Size")
        let tabWidthCaption = NSTextField(labelWithString: "characters")

        textSizeSlider.target = self
        textSizeSlider.action = #selector(textSizeChanged(_:))
        textSizeSlider.doubleValue = Double(settings.textSizeScale)
        textSizeSlider.numberOfTickMarks = 15
        textSizeSlider.allowsTickMarkValuesOnly = true

        smallTextSizeLabel.font = LilexFontProvider.regular(size: 11)
        largeTextSizeLabel.font = LilexFontProvider.regular(size: 18)

        for option in EditorSettings.maxTextWidthOptions {
            widthPopup.addItem(withTitle: String(option))
        }
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        widthPopup.selectItem(withTitle: String(settings.maxTextColumns))

        for mode in EditorSettings.TabInsertionMode.allCases {
            tabModePopup.addItem(withTitle: title(for: mode))
        }
        tabModePopup.target = self
        tabModePopup.action = #selector(tabModeChanged(_:))
        tabModePopup.selectItem(withTitle: title(for: settings.tabInsertionMode))

        for option in EditorSettings.tabWidthOptions {
            tabWidthPopup.addItem(withTitle: String(option))
        }
        tabWidthPopup.target = self
        tabWidthPopup.action = #selector(tabWidthChanged(_:))
        tabWidthPopup.selectItem(withTitle: String(settings.tabWidth))

        for view in [
            textSizeLabel, smallTextSizeLabel, textSizeSlider, largeTextSizeLabel,
            widthLabel,
            widthPopup, widthCaption, tabModeLabel, tabModePopup, tabWidthLabel,
            tabWidthPopup,
            tabWidthCaption,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            textSizeLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: 24
            ),
            textSizeLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: 30
            ),
            textSizeLabel.widthAnchor.constraint(equalToConstant: 90),

            smallTextSizeLabel.leadingAnchor.constraint(
                equalTo: textSizeLabel.trailingAnchor, constant: 12
            ),
            smallTextSizeLabel.centerYAnchor
                .constraint(equalTo: textSizeLabel.centerYAnchor),

            textSizeSlider.leadingAnchor.constraint(
                equalTo: smallTextSizeLabel.trailingAnchor, constant: 8
            ),
            textSizeSlider.trailingAnchor.constraint(
                equalTo: largeTextSizeLabel.leadingAnchor, constant: -8
            ),
            textSizeSlider.centerYAnchor.constraint(equalTo: textSizeLabel.centerYAnchor),

            largeTextSizeLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -24
            ),
            largeTextSizeLabel.centerYAnchor
                .constraint(equalTo: textSizeLabel.centerYAnchor),

            widthLabel.leadingAnchor.constraint(equalTo: textSizeLabel.leadingAnchor),
            widthLabel.topAnchor.constraint(
                equalTo: textSizeLabel.bottomAnchor,
                constant: 28
            ),
            widthLabel.widthAnchor.constraint(equalTo: textSizeLabel.widthAnchor),

            widthPopup.leadingAnchor.constraint(
                equalTo: widthLabel.trailingAnchor,
                constant: 12
            ),
            widthPopup.centerYAnchor.constraint(equalTo: widthLabel.centerYAnchor),
            widthPopup.widthAnchor.constraint(equalToConstant: 90),

            widthCaption.leadingAnchor.constraint(
                equalTo: widthPopup.trailingAnchor,
                constant: 8
            ),
            widthCaption.centerYAnchor.constraint(equalTo: widthPopup.centerYAnchor),

            tabModeLabel.leadingAnchor.constraint(equalTo: textSizeLabel.leadingAnchor),
            tabModeLabel.topAnchor.constraint(
                equalTo: widthLabel.bottomAnchor,
                constant: 28
            ),
            tabModeLabel.widthAnchor.constraint(equalTo: textSizeLabel.widthAnchor),

            tabModePopup.leadingAnchor.constraint(
                equalTo: tabModeLabel.trailingAnchor, constant: 12
            ),
            tabModePopup.centerYAnchor.constraint(equalTo: tabModeLabel.centerYAnchor),
            tabModePopup.widthAnchor.constraint(equalToConstant: 120),

            tabWidthLabel.leadingAnchor.constraint(equalTo: textSizeLabel.leadingAnchor),
            tabWidthLabel.topAnchor.constraint(
                equalTo: tabModeLabel.bottomAnchor,
                constant: 28
            ),
            tabWidthLabel.widthAnchor.constraint(equalTo: textSizeLabel.widthAnchor),

            tabWidthPopup.leadingAnchor.constraint(
                equalTo: tabWidthLabel.trailingAnchor, constant: 12
            ),
            tabWidthPopup.centerYAnchor.constraint(equalTo: tabWidthLabel.centerYAnchor),
            tabWidthPopup.widthAnchor.constraint(equalToConstant: 90),

            tabWidthCaption.leadingAnchor.constraint(
                equalTo: tabWidthPopup.trailingAnchor, constant: 8
            ),
            tabWidthCaption.centerYAnchor
                .constraint(equalTo: tabWidthPopup.centerYAnchor),
        ])
    }

    private func title(for mode: EditorSettings.TabInsertionMode) -> String {
        switch mode {
        case .spaces:
            "Spaces"
        case .tab:
            "Tab"
        }
    }
}
