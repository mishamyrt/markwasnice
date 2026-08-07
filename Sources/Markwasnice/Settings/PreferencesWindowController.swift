import AppKit

@MainActor
final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private enum Layout {
        static let width: CGFloat = 420
        static let margin: CGFloat = 24
        static let topMargin: CGFloat = 30
        /// Picked so a row of popups keeps the 45pt pitch the hand-placed
        /// form had.
        static let rowSpacing: CGFloat = 20
        static let columnSpacing: CGFloat = 12
        static let labelColumnWidth: CGFloat = 110
        static let popupWidth: CGFloat = 90
        static let widePopupWidth: CGFloat = 120
    }

    /// Whether more values of the same interaction are still coming. An
    /// NSSlider is continuous by default, so a drag reports every tick it
    /// crosses; only the value the user settles on is worth rolling out to
    /// every open document and writing to defaults.
    enum ChangePhase {
        case live
        case committed
    }

    private var settings: EditorSettings
    private let onChange: (EditorSettings, ChangePhase) -> Void
    private let textSizeSlider = NSSlider(
        value: 1, minValue: 0.05, maxValue: 1.95, target: nil, action: nil
    )
    private let smallTextSizeLabel = NSTextField(labelWithString: "A")
    private let largeTextSizeLabel = NSTextField(labelWithString: "A")
    private let widthPopup = NSPopUpButton()
    private let tabModePopup = NSPopUpButton()
    private let tabWidthPopup = NSPopUpButton()
    private let typographyPopup = NSPopUpButton()
    private let readingSpeedField = NSTextField()
    private let speakingSpeedField = NSTextField()
    private let cliHelperLabel = NSTextField(labelWithString: "CLI Helper")
    private let cliHelperButton = NSButton(
        title: "Install CLI helper", target: nil, action: nil
    )
    private let cliHelperStatus = NSTextField(
        labelWithString: "CLI helper is installed"
    )
    private let cliHelperPath = NSTextField(labelWithString: "")
    private let cliHelperInstaller: CLIHelperInstaller
    private var formGrid: NSGridView?
    private var cliHelperRow: NSGridRow?

    init(
        settings: EditorSettings,
        cliHelperInstaller: CLIHelperInstaller = .bundled,
        onChange: @escaping (EditorSettings, ChangePhase) -> Void
    ) {
        self.settings = settings
        self.cliHelperInstaller = cliHelperInstaller
        self.onChange = onChange

        // Height is a placeholder: configureControls sizes the window to the
        // form it just built, and re-sizes it whenever a row comes or goes.
        let contentView = NSView(
            frame: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.width)
        )
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
        typographyPopup.selectItem(withTitle: title(for: settings.typographyLocale))
        readingSpeedField.integerValue = settings.readingWordsPerMinute
        speakingSpeedField.integerValue = settings.speakingWordsPerMinute
        // The link can come and go behind the app's back (removed manually,
        // a deleted bundle), so the row is re-read every time the window is
        // about to be shown.
        refreshCLIHelperRow()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func textSizeChanged(_ sender: NSSlider) {
        settings.textSizeScale = CGFloat(sender.doubleValue)
        onChange(settings, changePhase(of: sender))
    }

    /// A control's value is provisional exactly while its mouse tracking loop
    /// is still running; keyboard-driven changes carry no such event and are
    /// final on arrival.
    private func changePhase(of sender: NSControl) -> ChangePhase {
        switch sender.window?.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged:
            .live
        default:
            .committed
        }
    }

    @objc private func widthChanged(_ sender: NSPopUpButton) {
        guard let value = Int(sender.titleOfSelectedItem ?? "") else {
            return
        }

        settings.maxTextColumns = value
        onChange(settings, .committed)
    }

    @objc private func tabModeChanged(_ sender: NSPopUpButton) {
        // The popup is populated from allCases in configureControls; decode
        // the selection through the same list.
        let modes = EditorSettings.TabInsertionMode.allCases
        guard modes.indices.contains(sender.indexOfSelectedItem) else {
            return
        }

        settings.tabInsertionMode = modes[sender.indexOfSelectedItem]
        onChange(settings, .committed)
    }

    @objc private func tabWidthChanged(_ sender: NSPopUpButton) {
        guard let value = Int(sender.titleOfSelectedItem ?? "") else {
            return
        }

        settings.tabWidth = value
        onChange(settings, .committed)
    }

    @objc private func typographyChanged(_ sender: NSPopUpButton) {
        // The popup is populated from allCases in configureControls; decode
        // the selection through the same list.
        let locales = EditorSettings.TypographyLocale.allCases
        guard locales.indices.contains(sender.indexOfSelectedItem) else {
            return
        }

        settings.typographyLocale = locales[sender.indexOfSelectedItem]
        onChange(settings, .committed)
    }

    private func speedChanged(_ sender: NSTextField) {
        commitSpeed(sender.integerValue, for: sender)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field == readingSpeedField || field == speakingSpeedField
        else {
            return
        }

        speedChanged(field)
    }

    private func commitSpeed(_ value: Int, for field: NSTextField) {
        let value = min(
            max(value, EditorSettings.wordsPerMinuteRange.lowerBound),
            EditorSettings.wordsPerMinuteRange.upperBound
        )
        field.integerValue = value

        if field == readingSpeedField {
            settings.readingWordsPerMinute = value
        } else {
            settings.speakingWordsPerMinute = value
        }
        onChange(settings, .committed)
    }

    @objc private func installCLIHelper(_: NSButton) {
        do {
            try cliHelperInstaller.install()
        } catch {
            NSAlert(error: error).runModal()
        }

        refreshCLIHelperRow()
    }

    private func refreshCLIHelperRow() {
        let state = cliHelperInstaller.state
        cliHelperButton.isHidden = state != .notInstalled
        cliHelperStatus.isHidden = state == .notInstalled
        cliHelperPath.isHidden = cliHelperStatus.isHidden

        if case let .installed(link) = state {
            cliHelperPath.stringValue = abbreviatedPath(of: link)
        }

        // Nothing to offer in an unbundled build: the whole row goes away
        // rather than showing a button that cannot work.
        cliHelperRow?.isHidden = state == .unavailable
        resizeWindowToFitForm()
    }

    /// The window is exactly as tall as the form asks to be, so a row that
    /// collapses (or a future row that is added) needs no height constant of
    /// its own.
    private func resizeWindowToFitForm() {
        guard let formGrid else {
            return
        }

        formGrid.layoutSubtreeIfNeeded()
        let height = formGrid.fittingSize.height + Layout.topMargin + Layout.margin
        guard let current = window?.contentView?.frame.height,
              abs(current - height) > 0.5
        else {
            return
        }

        window?.setContentSize(NSSize(width: Layout.width, height: height))
    }

    /// Home-relative so the row does not have to fit an absolute path.
    private func abbreviatedPath(of url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard url.path.hasPrefix(home + "/") else {
            return url.path
        }

        return "~" + url.path.dropFirst(home.count)
    }

    private func configureControls(in contentView: NSView) {
        let textSizeLabel = NSTextField(labelWithString: "Text Size")
        let widthLabel = NSTextField(labelWithString: "Text Width")
        let tabModeLabel = NSTextField(labelWithString: "Tab Inserts")
        let tabWidthLabel = NSTextField(labelWithString: "Tab Size")
        let typographyLabel = NSTextField(labelWithString: "Typography")
        let readingSpeedLabel = NSTextField(labelWithString: "Reading Speed")
        let speakingSpeedLabel = NSTextField(labelWithString: "Speaking Speed")

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

        for locale in EditorSettings.TypographyLocale.allCases {
            typographyPopup.addItem(withTitle: title(for: locale))
        }
        typographyPopup.target = self
        typographyPopup.action = #selector(typographyChanged(_:))
        typographyPopup.selectItem(withTitle: title(for: settings.typographyLocale))

        configureSpeedField(
            field: readingSpeedField,
            value: settings.readingWordsPerMinute
        )
        configureSpeedField(
            field: speakingSpeedField,
            value: settings.speakingWordsPerMinute
        )

        cliHelperButton.target = self
        cliHelperButton.action = #selector(installCLIHelper(_:))
        cliHelperButton.bezelStyle = .rounded
        cliHelperPath.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cliHelperPath.textColor = .secondaryLabelColor
        // A long path must be truncated, never widen the settings window.
        cliHelperPath.lineBreakMode = .byTruncatingMiddle
        cliHelperPath.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        let grid = NSGridView(views: [
            [textSizeLabel, textSizeControls()],
            [widthLabel, popupRow(
                widthPopup, width: Layout.popupWidth, caption: "characters"
            )],
            [tabModeLabel, popupRow(tabModePopup, width: Layout.widePopupWidth)],
            [tabWidthLabel, popupRow(
                tabWidthPopup, width: Layout.popupWidth, caption: "characters"
            )],
            [typographyLabel, popupRow(
                typographyPopup, width: Layout.widePopupWidth
            )],
            [readingSpeedLabel, speedFieldRow(readingSpeedField)],
            [speakingSpeedLabel, speedFieldRow(speakingSpeedField)],
            [cliHelperLabel, cliHelperControls()],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Layout.rowSpacing
        grid.columnSpacing = Layout.columnSpacing
        grid.column(at: 0).width = Layout.labelColumnWidth
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        for index in 0 ..< grid.numberOfRows {
            grid.row(at: index).yPlacement = .center
        }
        // The CLI row is the one that stacks two lines under its label, so it
        // hangs from the top instead of centering against them.
        let cliRow = grid.row(at: grid.numberOfRows - 1)
        cliRow.yPlacement = .top
        cliHelperRow = cliRow
        formGrid = grid

        contentView.addSubview(grid)
        // Only three edges: the form's height is what the window is sized
        // from, so pinning the bottom too would fight every resize.
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Layout.margin
            ),
            grid.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Layout.margin
            ),
            grid.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: Layout.topMargin
            ),
        ])

        refreshCLIHelperRow()
    }

    /// The size slider between its two sample glyphs. The slider is the only
    /// view here without an intrinsic width, so it takes the whole remainder.
    private func textSizeControls() -> NSView {
        let stack = NSStackView(views: [
            smallTextSizeLabel, textSizeSlider, largeTextSizeLabel,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func popupRow(
        _ popup: NSPopUpButton,
        width: CGFloat,
        caption: String? = nil
    ) -> NSView {
        popup.widthAnchor.constraint(equalToConstant: width).isActive = true
        let stack = NSStackView(
            views: [popup] + (caption.map { [NSTextField(labelWithString: $0)] } ?? [])
        )
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    private func configureSpeedField(
        field: NSTextField,
        value: Int
    ) {
        let formatter = NumberFormatter()
        formatter.minimum = EditorSettings.wordsPerMinuteRange.lowerBound as NSNumber
        formatter.maximum = EditorSettings.wordsPerMinuteRange.upperBound as NSNumber
        formatter.allowsFloats = false
        field.formatter = formatter
        field.delegate = self
        field.integerValue = value
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
    }

    private func speedFieldRow(_ field: NSTextField) -> NSView {
        let stack = NSStackView(views: [
            field, NSTextField(labelWithString: "words/min"),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        return stack
    }

    /// Install button and installed-state lines share the row: whichever the
    /// installer state calls for is the only one left visible, and the stack
    /// collapses the rest.
    private func cliHelperControls() -> NSView {
        let stack = NSStackView(views: [
            cliHelperButton, cliHelperStatus, cliHelperPath,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    private func title(for mode: EditorSettings.TabInsertionMode) -> String {
        switch mode {
        case .spaces:
            "Spaces"
        case .tab:
            "Tab"
        }
    }

    private func title(for locale: EditorSettings.TypographyLocale) -> String {
        switch locale {
        case .russian:
            "Russian"
        case .english:
            "English"
        }
    }
}
