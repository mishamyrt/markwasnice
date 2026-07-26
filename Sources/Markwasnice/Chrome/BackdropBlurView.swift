@preconcurrency import AppKit
import ObjectiveC

final class BackdropBlurView: NSView {
    private static let blurRadius: CGFloat = 5
    private static let backgroundAlpha: CGFloat = 0.86

    private let containerLayer = CALayer()
    private let backgroundLayer = CALayer()
    private let backdropLayer: CALayer

    override init(frame frameRect: NSRect) {
        backdropLayer = Self.makeBackdropLayer()
        super.init(frame: frameRect)
        configureView()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        containerLayer.frame = bounds
        backgroundLayer.frame = bounds
        backdropLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutImplicitAnimations {
            updateBackgroundColor()
        }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configureView() {
        wantsLayer = true
        guard let rootLayer = layer else {
            return
        }

        containerLayer.masksToBounds = true
        updateBackgroundColor()

        backdropLayer.name = "markwasnice-titlebar-backdrop"
        backdropLayer.backgroundColor = NSColor.clear.cgColor
        backdropLayer.masksToBounds = false
        backdropLayer.setValue(true, forKey: "allowsGroupBlending")
        backdropLayer.setValue(true, forKey: "allowsGroupOpacity")
        backdropLayer.setValue(true, forKey: "disablesOccludedBackdropBlurs")
        backdropLayer.setValue(true, forKey: "ignoresOffscreenGroups")
        backdropLayer.setValue(false, forKey: "allowsInPlaceFiltering")
        backdropLayer.setValue(0.5, forKey: "scale")
        backdropLayer.setValue(8.0, forKey: "bleedAmount")

        configureBackdropFilter()

        // Tint above the backdrop, not below it: underneath, the blurred
        // copy of the content paints over the tint at full strength and
        // fades out along the band's bottom edge, which reads as a gradient
        // mask instead of one flat 86% wash.
        containerLayer.addSublayer(backdropLayer)
        containerLayer.addSublayer(backgroundLayer)
        rootLayer.addSublayer(containerLayer)
    }

    private func configureBackdropFilter() {
        guard let blur = Self.makeCAFilter(named: "gaussianBlur") else {
            backdropLayer.filters = nil
            return
        }

        blur.setValue(Self.blurRadius, forKey: "inputRadius")
        // Without this the kernel runs out of samples near the band's top and
        // bottom edges and blurs them less than the middle, so the strip reads
        // as a gradient rather than one flat blur.
        blur.setValue(true, forKey: "inputNormalizeEdges")
        backdropLayer.filters = [blur]
    }

    private func updateBackgroundColor() {
        let background = EditorThemeColors.default
            .variant(for: effectiveAppearance)
            .background
        backgroundLayer.backgroundColor = background
            .withAlphaComponent(Self.backgroundAlpha)
            .cgColor
    }

    private static func makeBackdropLayer() -> CALayer {
        guard let layerClass = NSClassFromString("CABackdropLayer") as? CALayer.Type
        else {
            assertionFailure("CABackdropLayer is unavailable")
            return CALayer()
        }

        return layerClass.init()
    }

    private static func makeCAFilter(named name: String) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") else {
            assertionFailure("CAFilter is unavailable")
            return nil
        }

        let selectors = [
            NSSelectorFromString("filterWithType:"),
            NSSelectorFromString("filterWithName:"),
        ]

        typealias Factory =
            @convention(c) (AnyClass, Selector, NSString)
                -> Unmanaged<AnyObject>?

        for selector in selectors {
            guard let method = class_getClassMethod(filterClass, selector) else {
                continue
            }

            let implementation = method_getImplementation(method)
            let factory = unsafeBitCast(implementation, to: Factory.self)
            return factory(filterClass, selector, name as NSString)?.takeUnretainedValue()
                as? NSObject
        }

        assertionFailure("No usable CAFilter factory selector found")
        return nil
    }

    private func withoutImplicitAnimations(_ updates: () -> Void) {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        updates()

        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }
}
