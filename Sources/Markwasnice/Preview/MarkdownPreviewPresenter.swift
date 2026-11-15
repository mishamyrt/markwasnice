import AppKit
import Markdown

/// Owns the preview overlay for the editor: lazy view creation, the
/// fade/scale transition between the editor scroll view and the preview,
/// re-rendering, and inset propagation. Kept out of MarkdownEditorView so
/// the styling engine there stays navigable; the editor supplies content
/// and scroll state through the closures below.
@MainActor
final class MarkdownPreviewPresenter {
    private(set) var isActive = false

    var source: (() -> String)?
    var theme: (() -> MarkdownPreviewRenderer.Theme)?
    var editorScrollFraction: (() -> CGFloat)?
    var focusEditor: (() -> Void)?
    var onScroll: (() -> Void)?
    var onScrollOffsetChanged: (() -> Void)?
    var onExitRequested: (() -> Void)?
    var onPreviewCreated: ((MarkdownPreviewView) -> Void)?

    private weak var container: NSView?
    private weak var editorScrollView: NSScrollView?
    private var previewView: MarkdownPreviewView?
    private var renderTask: Task<Void, Never>?
    private var contentGeneration = 0
    private var document: Document?
    private var renderedTheme: MarkdownPreviewRenderer.Theme?
    private(set) var renderedContent: NSAttributedString?
    private var displayedContent: NSAttributedString?
    private var needsReveal = false

    private static let transitionDuration: TimeInterval = 0.22
    private static let transitionScale: CGFloat = 1.02

    init(container: NSView, editorScrollView: NSScrollView) {
        self.container = container
        self.editorScrollView = editorScrollView
    }

    deinit {
        renderTask?.cancel()
    }

    func invalidateContent() {
        contentGeneration &+= 1
        renderTask?.cancel()
        document = nil
        renderedContent = nil
        renderedTheme = nil
        refreshIfActive()
    }

    func waitForRendering() async {
        await renderTask?.value
    }

    func setActive(_ isActive: Bool) {
        guard self.isActive != isActive else {
            return
        }

        self.isActive = isActive
        if isActive {
            show()
        } else {
            hide()
        }
    }

    var isScrolledFromTop: Bool {
        previewView?.isScrolledFromTop ?? false
    }

    func refreshIfActive() {
        guard isActive, let previewView else {
            return
        }
        updateContent(in: previewView)
    }

    func setInsets(top: CGFloat, bottom: CGFloat, horizontal: CGFloat) {
        previewView?.setInsets(top: top, bottom: bottom, horizontal: horizontal)
    }

    func setScrollerInsets(top: CGFloat, bottom: CGFloat) {
        previewView?.setScrollerInsets(top: top, bottom: bottom)
    }

    private func show() {
        guard editorScrollView != nil else {
            return
        }
        let preview = ensurePreviewView()
        needsReveal = true
        updateContent(in: preview)
    }

    private func updateContent(in preview: MarkdownPreviewView) {
        renderTask?.cancel()
        let generation = contentGeneration
        renderTask = Task { [weak self] in
            // Coalesce theme and font-size changes during live resize.
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self, isActive else {
                return
            }
            if document == nil {
                let parsed = await MarkdownPreviewRenderer.prepare(source?() ?? "")
                guard generation == contentGeneration else {
                    return
                }
                document = parsed
            }
            guard !Task.isCancelled, let document, let theme = theme?() else {
                return
            }
            if renderedContent == nil || renderedTheme != theme {
                guard let content = await MarkdownPreviewRenderer(theme: theme)
                    .renderCooperatively(document),
                    !Task.isCancelled, generation == contentGeneration
                else {
                    return
                }
                renderedContent = content
                renderedTheme = theme
            }
            guard isActive, !Task.isCancelled, let renderedContent else {
                return
            }
            let fraction = needsReveal
                ? (editorScrollFraction?() ?? 0)
                : preview.scrollFraction
            if displayedContent !== renderedContent {
                preview.setContent(renderedContent, colors: theme.colors)
                displayedContent = renderedContent
            }
            guard await preview.prepareLayout(), generation == contentGeneration else {
                return
            }
            preview.scrollToFraction(fraction)
            if needsReveal {
                needsReveal = false
                reveal(preview)
            }
        }
    }

    private func reveal(_ preview: MarkdownPreviewView) {
        guard let editorScrollView else {
            return
        }
        preview.isHidden = false
        preview.focus()

        preview.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            preview.animator().alphaValue = 1
            editorScrollView.animator().alphaValue = 0
        }
        animateScale(on: preview, from: Self.transitionScale, to: 1)
    }

    private func hide() {
        needsReveal = false
        renderTask?.cancel()
        focusEditor?()
        guard let preview = previewView, !preview.isHidden else {
            editorScrollView?.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.transitionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            preview.animator().alphaValue = 0
            editorScrollView?.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            // AppKit guarantees this completion handler runs on the main thread.
            MainActor.assumeIsolated {
                guard let self, !self.isActive, let previewView = self.previewView else {
                    return
                }

                previewView.isHidden = true
                previewView.layer?.transform = CATransform3DIdentity
            }
        }
        animateScale(on: preview, from: 1, to: Self.transitionScale)
    }

    private func ensurePreviewView() -> MarkdownPreviewView {
        if let previewView {
            return previewView
        }

        let preview = MarkdownPreviewView()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isHidden = true
        preview.onScroll = { [weak self] in
            self?.onScroll?()
        }
        preview.onScrollOffsetChanged = { [weak self] in
            self?.onScrollOffsetChanged?()
        }
        preview.onExitRequested = { [weak self] in
            self?.onExitRequested?()
        }
        if let container {
            container.addSubview(preview)
            NSLayoutConstraint.activate([
                preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                preview.topAnchor.constraint(equalTo: container.topAnchor),
                preview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        previewView = preview
        onPreviewCreated?(preview)
        return preview
    }

    /// Scales around the view center regardless of the layer's anchor point,
    /// so AppKit's own layer geometry management stays untouched at rest.
    private func scaleTransform(
        _ scale: CGFloat,
        bounds: NSRect
    ) -> CATransform3D {
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
    }

    private func animateScale(
        on preview: MarkdownPreviewView,
        from: CGFloat,
        to: CGFloat
    ) {
        guard let layer = preview.layer else {
            return
        }

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = scaleTransform(from, bounds: preview.bounds)
        animation.toValue = scaleTransform(to, bounds: preview.bounds)
        animation.duration = Self.transitionDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = scaleTransform(to, bounds: preview.bounds)
        layer.add(animation, forKey: "previewScale")
    }
}
