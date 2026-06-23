import AppKit

private extension NSToolbarItem.Identifier {
    static let fullScreenHistory = NSToolbarItem.Identifier("FullScreenHistory")
    static let fullScreenDocumentTitle = NSToolbarItem.Identifier("FullScreenDocumentTitle")
    static let fullScreenPreview = NSToolbarItem.Identifier("FullScreenPreview")
}

@MainActor
final class FullScreenToolbarController: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "FullScreenToolbar")

    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    private let historyControl = ChromeHistoryControl()
    private let previewButton = ChromeIconButton(symbolName: "eye")
    private let titleLabel = NSTextField(labelWithString: "Untitled")
    private let dirtyDotLabel = NSTextField(labelWithString: "•")
    private let titleView = NSStackView()

    override init() {
        super.init()
        configureToolbar()
    }

    func updateTitle(_ title: String, isEdited: Bool) {
        titleLabel.stringValue = title
        dirtyDotLabel.isHidden = !isEdited
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarItemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .fullScreenHistory:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = historyControl
            return item
        case .fullScreenDocumentTitle:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = titleView
            item.isBordered = false
            return item
        case .fullScreenPreview:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = previewButton
            return item
        default:
            return nil
        }
    }

    private var toolbarItemIdentifiers: [NSToolbarItem.Identifier] {
        [
            .fullScreenHistory,
            .flexibleSpace,
            .fullScreenDocumentTitle,
            .flexibleSpace,
            .fullScreenPreview,
        ]
    }

    private func configureToolbar() {
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.centeredItemIdentifier = .fullScreenDocumentTitle

        historyControl.onUndo = { [weak self] in
            self?.onUndo?()
        }
        historyControl.onRedo = { [weak self] in
            self?.onRedo?()
        }
        historyControl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            historyControl.widthAnchor.constraint(equalToConstant: 72),
            historyControl.heightAnchor.constraint(equalToConstant: 36),
        ])

        previewButton.isEnabled = false
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewButton.widthAnchor.constraint(equalToConstant: 36),
            previewButton.heightAnchor.constraint(equalToConstant: 36),
        ])

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.textColor = .labelColor

        dirtyDotLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        dirtyDotLabel.textColor = .secondaryLabelColor

        titleView.orientation = .horizontal
        titleView.alignment = .centerY
        titleView.spacing = 4
        titleView.addArrangedSubview(titleLabel)
        titleView.addArrangedSubview(dirtyDotLabel)
        titleView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            titleView.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
}
