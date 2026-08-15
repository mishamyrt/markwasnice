@preconcurrency import AppKit
import CoreImage.CIFilterBuiltins
import ObjectiveC

final class BackdropBlurView: NSView {
    private static let blurRadius: CGFloat = 5
    private static let maximumProgressiveBlurRadius: CGFloat = 2
    private static let minimumProgressiveBlurRadius: CGFloat = 0.4
    private static let uniformBackgroundAlpha: CGFloat = 0.86
    private static let progressiveBackgroundAlpha: CGFloat = 0.8

    private let containerLayer = CALayer()
    private let backgroundLayer = CALayer()
    private let backdropLayer: CALayer
    private lazy var progressiveBlurMask = Self.makeProgressiveBlurMask()
    var usesProgressiveBlur: Bool {
        didSet {
            guard usesProgressiveBlur != oldValue else {
                return
            }

            withoutImplicitAnimations {
                configureBackdropFilter()
                updateBackgroundColor()
            }
        }
    }

    init(frame frameRect: NSRect, usesProgressiveBlur: Bool = false) {
        backdropLayer = Self.makeBackdropLayer()
        self.usesProgressiveBlur = usesProgressiveBlur
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
        if usesProgressiveBlur, configureProgressiveBackdropFilter() {
            return
        }

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

    private func configureProgressiveBackdropFilter() -> Bool {
        guard let blur = Self.makeCAFilter(named: "variableBlur"),
              let progressiveBlurMask
        else {
            return false
        }

        blur.setValue(Self.blurRadius, forKey: "inputRadius")
        blur.setValue(progressiveBlurMask, forKey: "inputMaskImage")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        backdropLayer.filters = [blur]
        return true
    }

    /// `variableBlur` multiplies its maximum radius by the mask alpha. A
    /// bottom alpha of 1/5 therefore starts the band at a 1pt radius, while
    /// the opaque top reaches the full 5pt radius.
    private static func makeProgressiveBlurMask(
        width: CGFloat = 64,
        height: CGFloat = 64
    ) -> CGImage? {
        let gradient = CIFilter.linearGradient()
        let minimumAlpha = minimumProgressiveBlurRadius / maximumProgressiveBlurRadius
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1)
        gradient.color1 = CIColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: minimumAlpha
        )
        gradient.point0 = CGPoint(x: 0, y: height)
        gradient.point1 = .zero

        guard let image = gradient.outputImage else {
            return nil
        }

        return CIContext().createCGImage(
            image,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )
    }

    private func updateBackgroundColor() {
        let background = EditorThemeColors.default
            .variant(for: effectiveAppearance)
            .background
        backgroundLayer.backgroundColor = background
            .withAlphaComponent(backgroundAlpha)
            .cgColor
    }

    private var backgroundAlpha: CGFloat {
        usesProgressiveBlur
            ? Self.progressiveBackgroundAlpha
            : Self.uniformBackgroundAlpha
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
