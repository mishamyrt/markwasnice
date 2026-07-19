import AppKit

final class ProofreadingPopoverController: NSViewController {
    private static let contentWidth: CGFloat = 300
    private static let padding = NSEdgeInsets(
        top: 12,
        left: 14,
        bottom: 12,
        right: 14
    )

    private let issueTitle: String
    private let issueHint: String

    init(title: String, hint: String) {
        issueTitle = title
        issueHint = hint
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let padding = Self.padding
        let maxTextWidth =
            Self.contentWidth - padding.left - padding.right

        let titleLabel = NSTextField(
            wrappingLabelWithString: issueTitle
        )
        titleLabel.font = .boldSystemFont(ofSize: 15)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(
            wrappingLabelWithString: issueHint
        )
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .labelColor

        for label in [titleLabel, hintLabel] {
            label.isEditable = false
            label.isSelectable = false
            label.refusesFirstResponder = true
            label.preferredMaxLayoutWidth = maxTextWidth
        }

        let stack = NSStackView(views: [titleLabel, hintLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = OpaquePopoverView()
        container.addSubview(stack)

        let safeArea = container.safeAreaLayoutGuide

        NSLayoutConstraint.activate([
            safeArea.widthAnchor.constraint(
                equalToConstant: Self.contentWidth
            ),

            stack.leadingAnchor.constraint(
                equalTo: safeArea.leadingAnchor,
                constant: padding.left
            ),
            stack.trailingAnchor.constraint(
                equalTo: safeArea.trailingAnchor,
                constant: -padding.right
            ),
            stack.topAnchor.constraint(
                equalTo: safeArea.topAnchor,
                constant: padding.top
            ),
            stack.bottomAnchor.constraint(
                equalTo: safeArea.bottomAnchor,
                constant: -padding.bottom
            ),
        ])

        view = container
    }
}

final class OpaquePopoverView: NSView {
    override var isOpaque: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
