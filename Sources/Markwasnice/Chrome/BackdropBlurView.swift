@preconcurrency import AppKit
import CoreImage.CIFilterBuiltins
import ObjectiveC

final class BackdropBlurView: NSView {
    private let containerLayer = CALayer()
    private let backgroundGradientLayer = CAGradientLayer()
    private let backdropLayer: CALayer
    private var blurFilter: NSObject?

    var blurRadius: CGFloat = 2 {
        didSet {
            guard blurRadius != oldValue else { return }
            withoutImplicitAnimations {
                updateBlurRadius()
            }
        }
    }

    var isProminent = false {
        didSet {
            guard isProminent != oldValue else { return }

            withoutImplicitAnimations {
                blurRadius = isProminent ? 4 : 2
                updateBackdropFilter()
                updateBackgroundGradient()
            }
        }
    }

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
        backgroundGradientLayer.frame = bounds
        backdropLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutImplicitAnimations {
            updateBackgroundGradient()
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
        backgroundGradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        backgroundGradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        updateBackgroundGradient()

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

        updateBackdropFilter()

        containerLayer.addSublayer(backgroundGradientLayer)
        containerLayer.addSublayer(backdropLayer)
        rootLayer.addSublayer(containerLayer)
    }

    private func makeGradientImage(
        width: CGFloat = 100,
        height: CGFloat = 100,
        startOffset: CGFloat
    ) -> CGImage {
        let gradientFilter = CIFilter.smoothLinearGradient()
        gradientFilter.color0 = CIColor.black
        gradientFilter.color1 = CIColor.clear
        gradientFilter.point0 = CGPoint(x: 0, y: height)
        gradientFilter.point1 = CGPoint(x: 0, y: startOffset * height)

        return CIContext().createCGImage(
            gradientFilter.outputImage!,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        )!
    }

    private func updateBlurRadius() {
        blurFilter?.setValue(blurRadius, forKey: "inputRadius")
    }

    private func updateBackdropFilter() {
        let filterName = isProminent ? "gaussianBlur" : "variableBlur"
        guard let blur = Self.makeCAFilter(named: filterName) else {
            backdropLayer.filters = nil
            blurFilter = nil
            return
        }

        blur.setValue(blurRadius, forKey: "inputRadius")
        if !isProminent {
            let gradientImage = makeGradientImage(startOffset: 0)
            blur.setValue(gradientImage, forKey: "inputMaskImage")
            blur.setValue(true, forKey: "inputNormalizeEdges")
        }

        blurFilter = blur
        backdropLayer.filters = [blur]
    }

    private func updateBackgroundGradient() {
        let background = EditorThemeColors.default
            .variant(for: effectiveAppearance)
            .background
        if isProminent {
            backgroundGradientLayer.colors = [
                background.withAlphaComponent(0.94).cgColor,
                background.withAlphaComponent(0.94).cgColor,
            ]
            return
        }

        backgroundGradientLayer.colors = [
            background.withAlphaComponent(0.9).cgColor,
            background.withAlphaComponent(0).cgColor,
        ]
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
