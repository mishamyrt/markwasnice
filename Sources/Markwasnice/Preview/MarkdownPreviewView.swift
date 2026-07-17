import AppKit

/// Read-only rendered-markdown view shown over the editor in preview mode.
/// Owns its own scroll position; content and colors are pushed in by
/// MarkdownEditorView, which also mirrors the editor's chrome insets here.
final class MarkdownPreviewView: NSView {
    var onScroll: (() -> Void)?
    var onExitRequested: (() -> Void)? {
        get { textView.onExitRequested }
        set { textView.onExitRequested = newValue }
    }

    private let scrollView = NSScrollView()
    // Same TextKit 1 stack as the editor: exact whole-document geometry keeps
    // the fraction-based scroll sync deterministic.
    private let previewTextStorage = NSTextStorage()
    private let previewLayoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(
        containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private let textView: PreviewTextView
    private var lastScrollOffsetY: CGFloat?
    private var lastScrollClipSize: NSSize?
    private var scrollerTopInset: CGFloat = 0

    init() {
        previewTextStorage.addLayoutManager(previewLayoutManager)
        previewLayoutManager.addTextContainer(textContainer)
        previewLayoutManager.allowsNonContiguousLayout = false
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        textView = PreviewTextView(frame: .zero, textContainer: textContainer)

        super.init(frame: .zero)

        wantsLayer = true
        configureTextView()
        configureScrollView()

        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setContent(
        _ content: NSAttributedString,
        colors: EditorThemeColors.Variant
    ) {
        previewTextStorage.setAttributedString(content)
        scrollView.backgroundColor = colors.background
        textView.backgroundColor = colors.background
        textView.selectedTextAttributes = [.backgroundColor: colors.selection]
        textView.linkTextAttributes = [
            .foregroundColor: colors.foreground,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: colors.underline,
            .cursor: NSCursor.pointingHand,
        ]
    }

    func setInsets(top: CGFloat, bottom: CGFloat, horizontal: CGFloat) {
        let contentInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        // With automaticallyAdjustsContentInsets off, the scroll view's own
        // contentInsets setter never reaches the clip view (whose insets
        // drive bounds clamping), so the clip view is set directly.
        if !edgeInsets(scrollView.contentView.contentInsets, equalTo: contentInsets) {
            scrollView.contentView.contentInsets = contentInsets
        }
        let containerInset = NSSize(width: horizontal, height: 0)
        if textView.textContainerInset != containerInset {
            textView.textContainerInset = containerInset
        }
        applyScrollerInsets()
    }

    /// Mirrors the editor's scroller offset (bar height while the chrome is
    /// visible, 0 otherwise). Content padding lives on the clip view, which
    /// the scroll view's scroller tiling does not see, so the full offset
    /// is applied here just like in the editor.
    func setScrollerTopInset(_ inset: CGFloat) {
        scrollerTopInset = inset
        applyScrollerInsets()
    }

    func focus() {
        window?.makeFirstResponder(textView)
    }

    var scrollFraction: CGFloat {
        let clipView = scrollView.contentView
        let minOffset = -scrollView.contentView.contentInsets.top
        let maxOffset = max(
            minOffset,
            textView.frame.height - clipView.bounds.height
                + scrollView.contentView.contentInsets.bottom
        )
        guard maxOffset > minOffset else {
            return 0
        }

        return (clipView.bounds.origin.y - minOffset) / (maxOffset - minOffset)
    }

    func scrollToFraction(_ fraction: CGFloat) {
        layoutSubtreeIfNeeded()
        previewLayoutManager.ensureLayout(for: textContainer)

        let clipView = scrollView.contentView
        let minOffset = -scrollView.contentView.contentInsets.top
        let maxOffset = max(
            minOffset,
            textView.frame.height - clipView.bounds.height
                + scrollView.contentView.contentInsets.bottom
        )
        let clamped = min(max(fraction, 0), 1)
        let target = minOffset + (maxOffset - minOffset) * clamped
        clipView.setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func configureTextView() {
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesFindBar = false
    }

    private func configureScrollView() {
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.scrollerInsets = NSEdgeInsetsZero
        // Tahoe's tile pass reads the clip view's own copy of this flag
        // (default true) and would stamp glass insets over the zero insets
        // above; see the editor's configureScrollView.
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    private func applyScrollerInsets() {
        let insets = NSEdgeInsets(top: scrollerTopInset, left: 0, bottom: 0, right: 0)
        if !edgeInsets(scrollView.scrollerInsets, equalTo: insets) {
            scrollView.scrollerInsets = insets
        }
    }

    @objc private func scrollViewBoundsDidChange(_ notification: Notification) {
        guard let clipView = notification.object as? NSClipView else {
            return
        }

        let offsetY = clipView.bounds.origin.y
        let clipSize = clipView.bounds.size
        defer {
            lastScrollOffsetY = offsetY
            lastScrollClipSize = clipSize
        }
        // Window resizes change the clip size and shift the origin as a
        // side effect; only origin-only changes are user scrolling.
        guard let lastScrollOffsetY,
              let lastScrollClipSize,
              clipSize == lastScrollClipSize,
              abs(offsetY - lastScrollOffsetY) > 0.5
        else {
            return
        }

        onScroll?()
    }

    private func edgeInsets(_ lhs: NSEdgeInsets, equalTo rhs: NSEdgeInsets) -> Bool {
        lhs.top == rhs.top && lhs.left == rhs.left && lhs.bottom == rhs.bottom
            && lhs.right == rhs.right
    }
}

private final class PreviewTextView: NSTextView {
    var onExitRequested: (() -> Void)?

    override func cancelOperation(_: Any?) {
        onExitRequested?()
    }
}
