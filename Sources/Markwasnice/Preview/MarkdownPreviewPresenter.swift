import AppKit

/// Owns the preview overlay for the editor: lazy view creation, the
/// fade/scale transition between the editor scroll view and the preview,
/// re-rendering, and inset propagation. Kept out of MarkdownEditorView so
/// the styling engine there stays navigable; the editor supplies content
/// and scroll state through the closures below.
@MainActor
final class MarkdownPreviewPresenter {
    private(set) var isActive = false

    var renderContent: ((MarkdownPreviewView) -> Void)?
    var editorScrollFraction: (() -> CGFloat)?
    var focusEditor: (() -> Void)?
    var onScroll: (() -> Void)?
    var onExitRequested: (() -> Void)?
    var onPreviewCreated: ((MarkdownPreviewView) -> Void)?

    private weak var container: NSView?
    private weak var editorScrollView: NSScrollView?
    private var previewView: MarkdownPreviewView?

    private static let transitionDuration: TimeInterval = 0.22
    private static let transitionScale: CGFloat = 1.02

    init(container: NSView, editorScrollView: NSScrollView) {
        self.container = container
        self.editorScrollView = editorScrollView
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

    func refreshIfActive() {
        guard isActive, let previewView, !previewView.isHidden else {
            return
        }

        let fraction = previewView.scrollFraction
        renderContent?(previewView)
        previewView.scrollToFraction(fraction)
    }

    func setInsets(top: CGFloat, bottom: CGFloat, horizontal: CGFloat) {
        previewView?.setInsets(top: top, bottom: bottom, horizontal: horizontal)
    }

    func setScrollerTopInset(_ inset: CGFloat) {
        previewView?.setScrollerTopInset(inset)
    }

    private func show() {
        guard let editorScrollView else {
            return
        }

        let preview = ensurePreviewView()
        renderContent?(preview)
        preview.isHidden = false
        preview.scrollToFraction(editorScrollFraction?() ?? 0)
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
            guard let self, !isActive, let previewView else {
                return
            }

            previewView.isHidden = true
            previewView.layer?.transform = CATransform3DIdentity
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
