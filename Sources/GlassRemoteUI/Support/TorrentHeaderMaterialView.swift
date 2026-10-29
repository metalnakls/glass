import AppKit
import CoreImage.CIFilterBuiltins

/// Blurs the live backdrop before tinting it. Fading a material's whole view
/// mixes the original sharp rows back in, which defeats blur at low tint values.
final class TorrentHeaderMaterialView: NSView {
    let tint = CAGradientLayer()
    private let blur = CIFilter.maskedVariableBlur()
    private var baseMask: CIImage?
    private var maskSize = CGSize.zero
    private var maskSolidHeight: CGFloat = -1
    private var solidHeight: CGFloat = 0
    private var strength: CGFloat = 0.75
    private var reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        blur.setDefaults() // Use Core Image's standard blur radius.
        tint.startPoint = CGPoint(x: 0.5, y: 1)
        tint.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(tint)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        updateTint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var frame: NSRect { didSet { updateGeometry() } }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); updateGeometry() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateTint() }

    func configure(strength: Double, titleHeight: CGFloat? = nil) {
        let strength = min(1, max(0, strength))
        if self.strength != strength {
            self.strength = strength
            updateTint()
        }
        if let titleHeight, solidHeight != TorrentStickyHeaders.topInset + titleHeight {
            solidHeight = TorrentStickyHeaders.topInset + titleHeight
            updateGeometry()
        }
    }
    @objc private func accessibilityChanged() {
        reducesTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        updateTint()
        updateGeometry()
    }
    private func updateTint() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.windowBackgroundColor.withAlphaComponent(reducesTransparency ? 1 : strength)
            tint.colors = [color.cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }
    private func updateGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let solid = min(bounds.height, max(0, solidHeight))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if maskSize != bounds.size || maskSolidHeight != solid {
            maskSize = bounds.size; maskSolidHeight = solid
            tint.frame = bounds
            tint.locations = [0, NSNumber(value: Double(solid / bounds.height)), 1]
            if solid < bounds.height {
                let gradient = CIFilter.linearGradient()
                gradient.point0 = CGPoint(x: 0, y: solid)
                gradient.point1 = CGPoint(x: 0, y: bounds.height)
                gradient.color0 = .white; gradient.color1 = .black
                baseMask = gradient.outputImage?.cropped(to: CGRect(origin: .zero, size: bounds.size))
            } else {
                baseMask = CIImage(color: .white).cropped(to: CGRect(origin: .zero, size: bounds.size))
            }
        }
        // AppKit background-filter masks use the backdrop's parent coordinates.
        // Translate the cached mask with the view, including during early release.
        let transform = superview?.isFlipped == false
            ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: frame.minX, ty: frame.maxY)
            : CGAffineTransform(translationX: frame.minX, y: frame.minY)
        blur.mask = baseMask?.transformed(by: transform)
        backgroundFilters = reducesTransparency ? [] : [blur]
        CATransaction.commit()
    }
    isolated deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }
}
