import AppKit

/// One availability-safe surface for every piece of chrome in the app.
///
/// On macOS 26 and later this hosts a real `NSGlassEffectView` (Liquid Glass).
/// On older systems it degrades to a rounded `NSVisualEffectView` with the same
/// geometry, so layout code never branches on availability.
@MainActor
final class GlassSurfaceView: NSView {
    /// Mirrors `NSGlassEffectView.Style` without leaking an availability-bound type.
    enum Style {
        /// Standard glass for floating chrome.
        case regular
        /// Clearer glass for surfaces that sit over busy artwork.
        case clear
    }

    var style: Style = .regular { didSet { applyAppearance() } }
    var cornerRadius: CGFloat = 16 { didSet { applyAppearance() } }
    var tintColor: NSColor? { didSet { applyAppearance() } }
    /// Interactive glass reacts to pointer and click; use it behind controls.
    var isInteractive: Bool = false { didSet { applyAppearance() } }
    /// Material used only by the pre-macOS 26 fallback.
    var fallbackMaterial: NSVisualEffectView.Material = .hudWindow { didSet { applyAppearance() } }

    /// The view hosted inside the glass. Reparented into the glass automatically.
    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            installContent()
        }
    }

    private var glassView: NSView?
    private var fallbackView: NSVisualEffectView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        installSurface()
        installEdge()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        installEdge()
    }

    /// Glass is a material, not an input target: let clicks fall through to the
    /// host view (so cards stay draggable) while its content — text, buttons,
    /// scroll views — still receives them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        // The hosting glass view does not forward hit-testing to the view it
        // presents through `contentView`, so ask the content directly.
        guard let contentView else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return contentView.hitTest(local)
    }

    /// Floating glass reads as flat without a specular rim and a contact shadow.
    private func installEdge() {
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
            let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.cornerRadius = cornerRadius
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.white.withAlphaComponent(isDark ? 0.12 : 0.55).cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = isDark ? 0.35 : 0.10
            layer?.shadowRadius = 16
            layer?.shadowOffset = CGSize(width: 0, height: -4)
        }
    }

    private func installSurface() {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
            glassView = glass
        } else {
            let fallback = NSVisualEffectView()
            fallback.blendingMode = .withinWindow
            fallback.state = .active
            fallback.autoresizingMask = [.width, .height]
            fallback.wantsLayer = true
            addSubview(fallback)
            fallbackView = fallback
        }
        applyAppearance()
        installContent()
    }

    private func applyAppearance() {
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            glass.style = style == .clear ? .clear : .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = isInteractive
            }
        } else if let fallback = fallbackView {
            fallback.material = fallbackMaterial
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.masksToBounds = true
            fallback.layer?.backgroundColor = tintColor?.cgColor
        }
    }

    private func installContent() {
        guard let contentView else { return }
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            contentView.autoresizingMask = [.width, .height]
            contentView.frame = glass.bounds
            glass.contentView = contentView
        } else if let fallback = fallbackView {
            contentView.autoresizingMask = [.width, .height]
            contentView.frame = fallback.bounds
            fallback.addSubview(contentView)
        }
    }

    override func layout() {
        super.layout()
        glassView?.frame = bounds
        fallbackView?.frame = bounds
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            glass.contentView?.frame = glass.bounds
        } else if let fallback = fallbackView {
            contentView?.frame = fallback.bounds
        }
    }
}

/// A soft, appearance-aware gradient that sits behind chrome so glass has
/// something to refract. Flat backgrounds make Liquid Glass read as flat gray.
final class AmbientBackdropView: NSView {
    enum Tone {
        /// Neutral, slightly cooler: sits behind window chrome and panels.
        case chrome
        /// Warm paper: the canvas and document surface.
        case paper
    }

    var tone: Tone = .chrome { didSet { needsDisplay = true } }

    /// Theme accent blended into both ends of the ramp, so the surface behind
    /// the glass carries the theme instead of staying neutral gray.
    var accent: NSColor? { didSet { needsDisplay = true } }

    /// The gradient is computed from the live appearance, so a light/dark
    /// switch has to repaint it; nothing else invalidates this view.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var top: NSColor
        var bottom: NSColor
        switch (tone, isDark) {
        case (.chrome, false): top = NSColor(srgbRed: 0.973, green: 0.965, blue: 0.945, alpha: 1)
                               bottom = NSColor(srgbRed: 0.902, green: 0.890, blue: 0.867, alpha: 1)
        case (.chrome, true):  top = NSColor(srgbRed: 0.153, green: 0.149, blue: 0.157, alpha: 1)
                               bottom = NSColor(srgbRed: 0.106, green: 0.102, blue: 0.110, alpha: 1)
        case (.paper, false):  top = NSColor(srgbRed: 0.988, green: 0.980, blue: 0.965, alpha: 1)
                               bottom = NSColor(srgbRed: 0.949, green: 0.933, blue: 0.902, alpha: 1)
        case (.paper, true):   top = NSColor(srgbRed: 0.125, green: 0.122, blue: 0.118, alpha: 1)
                               bottom = NSColor(srgbRed: 0.086, green: 0.084, blue: 0.082, alpha: 1)
        }
        if let accent {
            let strength: CGFloat = isDark ? 0.18 : 0.12
            top = Self.blend(top, toward: accent, strength)
            bottom = Self.blend(bottom, toward: accent, strength * 0.6)
        }
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)

        // Soft light source at the top-leading corner; this is the variation
        // that makes the glass edges and specular highlights readable.
        let highlight = NSColor.white.withAlphaComponent(isDark ? 0.07 : 0.55)
        NSGradient(starting: highlight, ending: highlight.withAlphaComponent(0))?.draw(
            fromCenter: NSPoint(x: bounds.minX + bounds.width * 0.28, y: bounds.minY + bounds.height * 0.1),
            radius: 0,
            toCenter: NSPoint(x: bounds.minX + bounds.width * 0.28, y: bounds.minY + bounds.height * 0.1),
            radius: max(bounds.width, bounds.height) * 0.75,
            options: [])
    }

    private static func blend(_ base: NSColor, toward tint: NSColor, _ amount: CGFloat) -> NSColor {
        guard let b = base.usingColorSpace(.sRGB), let t = tint.usingColorSpace(.sRGB) else { return base }
        return NSColor(
            srgbRed: b.redComponent + (t.redComponent - b.redComponent) * amount,
            green: b.greenComponent + (t.greenComponent - b.greenComponent) * amount,
            blue: b.blueComponent + (t.blueComponent - b.blueComponent) * amount,
            alpha: 1
        )
    }
}

/// An opaque, rounded content surface. Unlike `GlassSurfaceView` this is meant
/// for reading surfaces (note list, note page) that must stay legible, so it
/// paints a solid dynamic color instead of glass. It redraws on appearance change.
final class RoundedCardView: NSView {
    var cornerRadius: CGFloat = 14 { didSet { needsDisplay = true } }
    var fillColor: NSColor = .controlBackgroundColor { didSet { needsDisplay = true } }
    var borderColor: NSColor? = .separatorColor { didSet { needsDisplay = true } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: cornerRadius, yRadius: cornerRadius)
        fillColor.setFill()
        path.fill()
        if let borderColor {
            borderColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

extension GlassSurfaceView {
    /// Toolbar-height floating bar: generous radius, interactive so controls respond.
    static func bar(cornerRadius: CGFloat = 24) -> GlassSurfaceView {
        let surface = GlassSurfaceView()
        surface.cornerRadius = cornerRadius
        surface.isInteractive = true
        surface.fallbackMaterial = .headerView
        return surface
    }

    /// Sidebar panel: softer radius, sidebar material on the fallback path.
    static func panel(cornerRadius: CGFloat = 22) -> GlassSurfaceView {
        let surface = GlassSurfaceView()
        surface.cornerRadius = cornerRadius
        surface.fallbackMaterial = .sidebar
        return surface
    }

    /// A single control-sized capsule inside a glass container.
    static func control(cornerRadius: CGFloat = 18) -> GlassSurfaceView {
        let surface = GlassSurfaceView()
        surface.cornerRadius = cornerRadius
        surface.isInteractive = true
        return surface
    }
}
