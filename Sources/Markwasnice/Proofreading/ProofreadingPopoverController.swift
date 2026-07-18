import AppKit

/// Content of the issue popup: bold rule title over a wrapping hint.
final class ProofreadingPopoverController: NSViewController {
    private static let contentWidth: CGFloat = 300
    private static let padding = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

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
        let maxTextWidth = Self.contentWidth
            - Self.padding.left - Self.padding.right

        let titleLabel = NSTextField(wrappingLabelWithString: issueTitle)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 15)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(wrappingLabelWithString: issueHint)
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor

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
        stack.edgeInsets = Self.padding
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(
                equalToConstant: Self.contentWidth
            ),
        ])
        view = container
    }
}
