import AppKit
import QuartzCore

/// Interactive step-by-step onboarding guide with highlighted callouts
final class OnboardingGuideView: NSView {
    private let backdrop = NSView()
    private let guideGlass = GlassSurfaceView.panel(cornerRadius: 20)
    private let guideContent = NSView()
    private let cardBackground = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)
    private let nextGlass = GlassSurfaceView.control(cornerRadius: 12)
    private let skipGlass = GlassSurfaceView.control(cornerRadius: 12)
    private let progressLabel = NSTextField(labelWithString: "")
    private let illustrationView = NSImageView()
    private var currentStep = 0
    private var currentIllustration: IllustrationType? = nil
    private let steps: [GuideStep]
    /// Current theme for color consistency
    var theme: NotesyTheme = amberTheme {
        didSet {
            updateThemeColors()
        }
    }

    struct GuideStep {
        let title: String
        let body: String
        let highlightRect: NSRect?
        let arrowDirection: ArrowDirection?
        let illustration: IllustrationType?
    }

    enum ArrowDirection { case up, down, left, right, none }
    
    enum IllustrationType {
        case none
        case dragToMove
        case dragToResize
        case optionDragArrow
        case clickAnchors
        case rightClickMenu
        case doubleClickNewCard
        case keyboardShortcuts
    }

    override init(frame frameRect: NSRect) {
        steps = [
            GuideStep(title: "Welcome to Notesy", body: "A three-column workspace for notes and visual thinking. Let's take a quick tour.", highlightRect: nil, arrowDirection: .none, illustration: .none),
            GuideStep(title: "Folders Sidebar", body: "Click any folder to filter your notes. \"Canvas\" shows only canvas notes. Create new folders with the + button.", highlightRect: NSRect(x: 8, y: 68, width: 232, height: 300), arrowDirection: .right, illustration: .none),
            GuideStep(title: "Notes List", body: "All your notes appear here. Click to open, double-click to rename. The glass panel lets your wallpaper show through.", highlightRect: NSRect(x: 248, y: 68, width: 242, height: 500), arrowDirection: .right, illustration: .none),
            GuideStep(title: "Note Editor / Canvas", body: "Text notes show a rich editor. Canvas notes become an infinite spatial workspace - drag cards, connect ideas.", highlightRect: NSRect(x: 498, y: 68, width: 500, height: 500), arrowDirection: .left, illustration: .none),
            GuideStep(title: "Toolbar Actions", body: "New note/canvas, formatting, zoom, and settings. Try \u{2318}N for new note, \u{2318}\u{21E7}N for new canvas.", highlightRect: NSRect(x: 10, y: 8, width: 400, height: 56), arrowDirection: .down, illustration: .keyboardShortcuts),
            GuideStep(title: "Create Cards", body: "Double-click anywhere on the canvas to create a new card. Each card is a draggable, resizable glass note.", highlightRect: NSRect(x: 498, y: 68, width: 500, height: 500), arrowDirection: .left, illustration: .doubleClickNewCard),
            GuideStep(title: "Move & Resize Cards", body: "Drag anywhere on a card to move it. Drag the bottom-right corner to resize. Cards snap to the grid for alignment.", highlightRect: NSRect(x: 498, y: 68, width: 500, height: 500), arrowDirection: .left, illustration: .dragToMove),
            GuideStep(title: "Create Arrows", body: "Hold \u{2325} (Option) and drag from empty space to create free-floating arrows. They're perfect for flow diagrams and mind maps.", highlightRect: NSRect(x: 498, y: 68, width: 500, height: 500), arrowDirection: .left, illustration: .optionDragArrow),
            GuideStep(title: "Card Menu & Layers", body: "Right-click any card for: delete, move to layer (1-10), and more. Layers let you organize complex diagrams.", highlightRect: NSRect(x: 498, y: 68, width: 500, height: 500), arrowDirection: .left, illustration: .rightClickMenu),
            GuideStep(title: "You're Ready!", body: "Your notes sync to iCloud Drive \u{2192} Documents \u{2192} Notesy. Press \u{2318}F to search, \u{2318}+ / \u{2318}- to zoom canvas, \u{2318}0 for actual size.", highlightRect: nil, arrowDirection: .none, illustration: .none)
        ]
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func draw(_ dirtyRect: NSRect) {
        // Fully transparent: the dimmed backdrop is a subview, not this layer.
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor

        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)

        guideGlass.style = .regular
        guideGlass.isInteractive = true
        guideGlass.cornerRadius = 20
        guideGlass.contentView = guideContent
        addSubview(guideGlass)

        // The guide sits over the user's notes, so the card needs a readable
        // base. Pure clear glass turns the body text into noise.
        cardBackground.wantsLayer = true
        cardBackground.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.985).cgColor
        cardBackground.layer?.cornerRadius = 20
        guideContent.addSubview(cardBackground)

        titleLabel.font = .systemFont(ofSize: 22, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        guideContent.addSubview(titleLabel)

        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.preferredMaxLayoutWidth = 360
        guideContent.addSubview(bodyLabel)

        illustrationView.imageScaling = .scaleProportionallyUpOrDown
        illustrationView.animates = true
        guideContent.addSubview(illustrationView)

        let nextGlass = self.nextGlass
        nextGlass.isInteractive = true
        nextGlass.style = .clear
        nextGlass.contentView = nextButton
        guideContent.addSubview(nextGlass)

        let skipGlass = self.skipGlass
        skipGlass.isInteractive = true
        skipGlass.style = .clear
        skipGlass.contentView = skipButton
        guideContent.addSubview(skipGlass)

        nextButton.bezelStyle = .regularSquare
        nextButton.isBordered = false
        nextButton.contentTintColor = .white
        nextButton.font = .systemFont(ofSize: 13, weight: .semibold)
        nextButton.target = self
        nextButton.action = #selector(nextStep)
        nextButton.keyEquivalent = "\r"
        nextGlass.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.85)

        skipButton.bezelStyle = .regularSquare
        skipButton.isBordered = false
        skipButton.contentTintColor = .labelColor
        skipButton.font = .systemFont(ofSize: 13, weight: .medium)
        skipButton.target = self
        skipButton.action = #selector(skipGuide)

        progressLabel.font = .systemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .tertiaryLabelColor
        progressLabel.alignment = .center
        guideContent.addSubview(progressLabel)

        updateStep()
        updateThemeColors()
    }
    
    /// Update all UI colors to match the current theme
    private func updateThemeColors() {
        let effectiveTheme = theme.resolved(for: effectiveAppearance)
        
        // Card background
        cardBackground.layer?.backgroundColor = effectiveTheme.cardBackground.withAlphaComponent(0.985).cgColor
        
        // Text colors
        titleLabel.textColor = effectiveTheme.textPrimary
        bodyLabel.textColor = effectiveTheme.textSecondary
        progressLabel.textColor = effectiveTheme.textTertiary
        
        // Button colors
        nextGlass.tintColor = effectiveTheme.accentColor.withAlphaComponent(0.85)
        nextButton.contentTintColor = .white
        skipButton.contentTintColor = effectiveTheme.textPrimary
        
        // Regenerate illustration with new theme colors
        updateIllustration(for: currentIllustration)
    }
    
    override func layout() {
        super.layout()
        backdrop.frame = bounds

        let cardWidth = min(500, max(360, bounds.width - 120))
        let cardHeight = min(470, max(380, bounds.height - 120))
        let cardX = (bounds.width - cardWidth) / 2
        let cardY = (bounds.height - cardHeight) / 2
        guideGlass.frame = NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight)
        guideGlass.isHidden = false
        guideContent.frame = guideGlass.bounds
        cardBackground.frame = guideContent.bounds

        // This view is not flipped, so y grows upward. Lay out in bands from
        // the top down: title -> progress -> illustration -> body -> buttons.
        let content = guideContent.bounds.insetBy(dx: 26, dy: 22)
        let contentWidth = content.width

        let titleHeight: CGFloat = 30
        titleLabel.frame = NSRect(x: content.minX, y: content.maxY - titleHeight,
                                  width: contentWidth, height: titleHeight)

        let progressHeight: CGFloat = 16
        let progressY = titleLabel.frame.minY - 6 - progressHeight
        progressLabel.frame = NSRect(x: content.minX, y: progressY,
                                     width: contentWidth, height: progressHeight)

        // Buttons sit on the bottom edge.
        let buttonHeight: CGFloat = 34
        let buttonY = content.minY
        let skipWidth: CGFloat = 86
        let nextWidth: CGFloat = 124
        skipGlass.frame = NSRect(x: content.minX, y: buttonY, width: skipWidth, height: buttonHeight)
        nextGlass.frame = NSRect(x: content.maxX - nextWidth, y: buttonY,
                                 width: nextWidth, height: buttonHeight)
        skipGlass.isHidden = skipButton.isHidden
        nextButton.frame = NSRect(origin: .zero, size: nextGlass.bounds.size)
        skipButton.frame = NSRect(origin: .zero, size: skipGlass.bounds.size)

        let bandTop = progressY - 16
        let bodyBottom = buttonY + buttonHeight + 20

        if illustrationView.isHidden {
            placeBody(top: bandTop, bottom: bodyBottom, width: contentWidth, x: content.minX, centered: true)
        } else {
            let illustrationHeight: CGFloat = 138
            let illustrationWidth = min(contentWidth, 320)
            illustrationView.frame = NSRect(x: content.minX + (contentWidth - illustrationWidth) / 2,
                                            y: bandTop - illustrationHeight,
                                            width: illustrationWidth,
                                            height: illustrationHeight)
            placeBody(top: illustrationView.frame.minY - 14,
                      bottom: bodyBottom,
                      width: contentWidth,
                      x: content.minX,
                      centered: false)
        }

        updateSpotlight()
    }

    /// Top-align (or vertically center) the wrapping body text in its band.
    private func placeBody(top: CGFloat, bottom: CGFloat, width: CGFloat, x: CGFloat, centered: Bool) {
        bodyLabel.preferredMaxLayoutWidth = width
        let available = max(24, top - bottom)
        let fitted = bodyLabel.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(max(fitted.height, 20), available)
        let y = centered ? bottom + (available - height) / 2 : top - height
        bodyLabel.frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func updateStep() {
        let step = steps[currentStep]
        titleLabel.stringValue = step.title
        bodyLabel.stringValue = step.body
        progressLabel.stringValue = "Step \(currentStep + 1) of \(steps.count)"

        nextButton.title = currentStep == steps.count - 1 ? "Get Started" : "Next"
        skipButton.isHidden = currentStep == steps.count - 1
        skipGlass.isHidden = skipButton.isHidden

        currentIllustration = step.illustration
        updateIllustration(for: step.illustration)
        // Text length changes the body height and the illustration toggles the
        // band heights, so re-run the band layout for this step.
        needsLayout = true
    }

    private func updateIllustration(for type: IllustrationType?) {
        guard let type = type else {
            illustrationView.image = nil
            illustrationView.isHidden = true
            return
        }
        illustrationView.isHidden = false
        
        let size = NSSize(width: 320, height: 138)
        let image = NSImage(size: size)
        image.lockFocus()
        
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return
        }
        // Transparent canvas: the glass card is the background. A painted box
        // here reads as a dark slab inside the card.
        ctx.clear(CGRect(origin: .zero, size: size))
        
        let effectiveTheme = theme.resolved(for: effectiveAppearance)
        let accentColor = effectiveTheme.accentColor
        let textColor = effectiveTheme.textPrimary
        let secondaryColor = effectiveTheme.textSecondary
        let cardColor = effectiveTheme.cardBackground
        let cardBorder = effectiveTheme.borderColor
        
        switch type {
        case .dragToMove:
            drawDragToMove(ctx: ctx, size: size, cardColor: cardColor, borderColor: cardBorder, textColor: textColor, secondaryColor: secondaryColor, accentColor: accentColor)
        case .dragToResize:
            drawDragToResize(ctx: ctx, size: size, cardColor: cardColor, borderColor: cardBorder, textColor: textColor, secondaryColor: secondaryColor, accentColor: accentColor)
        case .optionDragArrow:
            drawOptionDragArrow(ctx: ctx, size: size, textColor: textColor, secondaryColor: secondaryColor, accentColor: accentColor)
        case .clickAnchors:
            drawClickAnchors(ctx: ctx, size: size, cardColor: cardColor, borderColor: cardBorder, textColor: textColor, secondaryColor: secondaryColor, accentColor: accentColor)
        case .rightClickMenu:
            drawRightClickMenu(ctx: ctx, size: size, cardColor: cardColor, borderColor: cardBorder, textColor: textColor, accentColor: accentColor)
        case .doubleClickNewCard:
            drawDoubleClickNewCard(ctx: ctx, size: size, cardColor: cardColor, borderColor: cardBorder, textColor: textColor, secondaryColor: secondaryColor, accentColor: accentColor)
        case .keyboardShortcuts:
            drawKeyboardShortcuts(ctx: ctx, size: size, accentColor: accentColor, textColor: textColor)
        case .none:
            break
        }
        
        image.unlockFocus()
        illustrationView.image = image
    }

    // MARK: - Illustration Drawing Helpers

    private func drawDragToMove(ctx: CGContext, size: NSSize, cardColor: NSColor, borderColor: NSColor, textColor: NSColor, secondaryColor: NSColor, accentColor: NSColor) {
        let cardRect = CGRect(x: 60, y: 20, width: 160, height: 80)
        drawCard(ctx: ctx, in: cardRect, title: "Drag to Move", body: "Click & drag anywhere", cardColor: cardColor, borderColor: borderColor, textColor: textColor, secondaryColor: secondaryColor)
        drawArrow(ctx: ctx, from: CGPoint(x: 240, y: 60), to: CGPoint(x: 260, y: 60), color: accentColor)
        drawLabel(ctx: ctx, "\u{2192}", at: CGPoint(x: 245, y: 70), color: accentColor, size: 14)
    }

    private func drawDragToResize(ctx: CGContext, size: NSSize, cardColor: NSColor, borderColor: NSColor, textColor: NSColor, secondaryColor: NSColor, accentColor: NSColor) {
        let cardRect = CGRect(x: 60, y: 20, width: 160, height: 80)
        drawCard(ctx: ctx, in: cardRect, title: "Resize", body: "Drag corner \u{2198}", cardColor: cardColor, borderColor: borderColor, textColor: textColor, secondaryColor: secondaryColor)
        let handleRect = CGRect(x: cardRect.maxX - 12, y: cardRect.minY + 12, width: 12, height: 12)
        drawResizeHandle(ctx: ctx, in: handleRect, color: accentColor)
        drawLabel(ctx: ctx, "\u{2198}", at: CGPoint(x: cardRect.maxX - 6, y: cardRect.minY + 6), color: accentColor, size: 10)
    }

    private func drawOptionDragArrow(ctx: CGContext, size: NSSize, textColor: NSColor, secondaryColor: NSColor, accentColor: NSColor) {
        drawLabel(ctx: ctx, "\u{2325}", at: CGPoint(x: 40, y: 80), color: accentColor, size: 24, weight: .bold)
        drawLabel(ctx: ctx, "+", at: CGPoint(x: 80, y: 80), color: secondaryColor, size: 24)
        drawLabel(ctx: ctx, "Drag", at: CGPoint(x: 110, y: 80), color: textColor, size: 16)
        drawArrow(ctx: ctx, from: CGPoint(x: 180, y: 60), to: CGPoint(x: 250, y: 60), color: accentColor, withArrowHead: true)
        drawLabel(ctx: ctx, "Free Arrow", at: CGPoint(x: 190, y: 30), color: secondaryColor, size: 12)
    }

    private func drawClickAnchors(ctx: CGContext, size: NSSize, cardColor: NSColor, borderColor: NSColor, textColor: NSColor, secondaryColor: NSColor, accentColor: NSColor) {
        let card1 = CGRect(x: 40, y: 20, width: 100, height: 60)
        let card2 = CGRect(x: 180, y: 20, width: 100, height: 60)
        drawCard(ctx: ctx, in: card1, title: "Card A", body: "Click anchor \u{2192}", cardColor: cardColor, borderColor: borderColor, textColor: textColor, secondaryColor: secondaryColor)
        drawCard(ctx: ctx, in: card2, title: "Card B", body: "\u{2190} Click anchor", cardColor: cardColor, borderColor: borderColor, textColor: textColor, secondaryColor: secondaryColor)
        drawAnchors(ctx: ctx, on: card1, color: accentColor)
        drawAnchors(ctx: ctx, on: card2, color: accentColor)
        drawArrow(ctx: ctx, from: CGPoint(x: card1.maxX, y: card1.midY), to: CGPoint(x: card2.minX, y: card2.midY), color: accentColor, withArrowHead: true)
    }

    private func drawRightClickMenu(ctx: CGContext, size: NSSize, cardColor: NSColor, borderColor: NSColor, textColor: NSColor, accentColor: NSColor) {
        let cardRect = CGRect(x: 30, y: 30, width: 130, height: 78)
        drawCard(ctx: ctx, in: cardRect, title: "Right-Click", body: "Menu appears", cardColor: cardColor, borderColor: borderColor, textColor: textColor, secondaryColor: NSColor.secondaryLabelColor)
        let menuRect = CGRect(x: cardRect.maxX + 14, y: cardRect.minY, width: 118, height: 70)
        drawContextMenu(ctx: ctx, in: menuRect, items: ["Delete", "Layer 1", "Layer 2", "Duplicate"], cardColor: cardColor, borderColor: borderColor, textColor: textColor)
    }

    private func drawDoubleClickNewCard(ctx: CGContext, size: NSSize, cardColor: NSColor, borderColor: NSColor, textColor: NSColor, secondaryColor: NSColor, accentColor: NSColor) {
        drawLabel(ctx: ctx, "Double-click", at: CGPoint(x: 140, y: 95), color: accentColor, size: 16, weight: .bold, centered: true)
        drawArrow(ctx: ctx, from: CGPoint(x: 140, y: 80), to: CGPoint(x: 140, y: 55), color: accentColor)
        let cardRect = CGRect(x: 70, y: 15, width: 140, height: 60)
        drawCard(ctx: ctx, in: cardRect, title: "New Card", body: "Appears instantly", cardColor: cardColor, borderColor: borderColor, textColor: textColor, secondaryColor: secondaryColor)
    }

    private func drawKeyboardShortcuts(ctx: CGContext, size: NSSize, accentColor: NSColor, textColor: NSColor) {
        let shortcuts = [
            ("\u{2318}N", "New Note"),
            ("\u{2318}\u{21E7}N", "New Canvas"),
            ("\u{2318}F", "Find"),
            ("\u{2318}+", "Zoom In"),
            ("\u{2318}-", "Zoom Out"),
            ("\u{2318}0", "Actual Size"),
            ("\u{2325}\u{2318}S", "Toggle Sidebar"),
        ]
        var y: CGFloat = 118
        for (key, desc) in shortcuts {
            drawKeycap(ctx: ctx, key, at: CGPoint(x: 80, y: y), color: accentColor)
            drawLabel(ctx: ctx, desc, at: CGPoint(x: 160, y: y + 4), color: textColor, size: 13)
            y -= 17
        }
    }

    // MARK: - Low-level drawing primitives

    private func drawCard(ctx: CGContext, in rect: CGRect, title: String, body: String, cardColor: NSColor, borderColor: NSColor, textColor: NSColor, secondaryColor: NSColor) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(cardColor.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: textColor
        ]
        title.draw(at: CGPoint(x: rect.minX + 10, y: rect.maxY - 20), withAttributes: titleAttrs)
        
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: secondaryColor
        ]
        body.draw(at: CGPoint(x: rect.minX + 10, y: rect.maxY - 36), withAttributes: bodyAttrs)
    }

    private func drawResizeHandle(ctx: CGContext, in rect: CGRect, color: NSColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX - 4, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 4))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY + 4))
        path.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY))
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    private func drawAnchors(ctx: CGContext, on rect: CGRect, color: NSColor) {
        let points = [
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY)
        ]
        for point in points {
            let anchorRect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            let path = CGPath(ellipseIn: anchorRect, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color.withAlphaComponent(0.3).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokePath()
        }
    }

    private func drawContextMenu(ctx: CGContext, in rect: CGRect, items: [String], cardColor: NSColor, borderColor: NSColor, textColor: NSColor) {
        let path = CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(cardColor.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        
        var y = rect.maxY - 12
        for item in items {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: textColor
            ]
            item.draw(at: CGPoint(x: rect.minX + 12, y: y), withAttributes: attrs)
            y -= 16
        }
    }

    private func drawArrow(ctx: CGContext, from start: CGPoint, to end: CGPoint, color: NSColor, withArrowHead: Bool = false) {
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        ctx.strokePath()
        
        if withArrowHead {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let angle = atan2(dy, dx)
            let headLen: CGFloat = 10
            let headAngle: CGFloat = .pi / 6
            
            let arrowPath = CGMutablePath()
            arrowPath.move(to: end)
            arrowPath.addLine(to: CGPoint(x: end.x - headLen * cos(angle - headAngle), y: end.y - headLen * sin(angle - headAngle)))
            arrowPath.move(to: end)
            arrowPath.addLine(to: CGPoint(x: end.x - headLen * cos(angle + headAngle), y: end.y - headLen * sin(angle + headAngle)))
            ctx.addPath(arrowPath)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
    }

    private func drawLabel(ctx: CGContext, _ text: String, at point: CGPoint, color: NSColor, size: CGFloat, weight: NSFont.Weight = .regular, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        let strSize = text.size(withAttributes: attrs)
        let drawPoint = centered ? CGPoint(x: point.x - strSize.width / 2, y: point.y) : point
        text.draw(at: drawPoint, withAttributes: attrs)
    }

    private func drawKeycap(ctx: CGContext, _ text: String, at point: CGPoint, color: NSColor) {
        let keyRect = CGRect(x: point.x - 30, y: point.y - 10, width: 60, height: 20)
        let path = CGPath(roundedRect: keyRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]
        let strSize = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: point.x - strSize.width / 2, y: point.y - 6), withAttributes: attrs)
    }

    private func updateSpotlight() {
        // A step without a highlight must not inherit the previous arrow.
        arrowLayer?.removeFromSuperlayer()
        arrowLayer = nil

        guard let highlight = steps[currentStep].highlightRect else {
            backdrop.layer?.mask = nil
            return
        }

        let maskLayer = CAShapeLayer()
        maskLayer.frame = bounds
        let path = CGMutablePath()
        path.addRect(bounds)
        let hole = highlight.insetBy(dx: -12, dy: -12)
        let holePath = CGPath(roundedRect: hole, cornerWidth: 14, cornerHeight: 14, transform: nil)
        path.addPath(holePath)
        path.closeSubpath()
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        backdrop.layer?.mask = maskLayer

        if let arrowDir = steps[currentStep].arrowDirection, arrowDir != .none {
            addArrowIndicator(for: highlight, direction: arrowDir)
        }
    }

    private var arrowLayer: CAShapeLayer?

    private func addArrowIndicator(for rect: NSRect, direction: ArrowDirection) {
        arrowLayer?.removeFromSuperlayer()
        let arrow = CAShapeLayer()
        arrow.strokeColor = NSColor.systemBlue.cgColor
        arrow.fillColor = NSColor.systemBlue.cgColor
        arrow.lineWidth = 3

        let center: CGPoint
        let points: [CGPoint]
        switch direction {
        case .up:
            center = CGPoint(x: rect.midX, y: rect.maxY + 30)
            points = [CGPoint(x: center.x, y: center.y - 14), CGPoint(x: center.x - 10, y: center.y + 6), CGPoint(x: center.x + 10, y: center.y + 6)]
        case .down:
            center = CGPoint(x: rect.midX, y: rect.minY - 30)
            points = [CGPoint(x: center.x, y: center.y + 14), CGPoint(x: center.x - 10, y: center.y - 6), CGPoint(x: center.x + 10, y: center.y - 6)]
        case .left:
            center = CGPoint(x: rect.maxX + 30, y: rect.midY)
            points = [CGPoint(x: center.x - 14, y: center.y), CGPoint(x: center.x + 6, y: center.y - 10), CGPoint(x: center.x + 6, y: center.y + 10)]
        case .right:
            center = CGPoint(x: rect.minX - 30, y: rect.midY)
            points = [CGPoint(x: center.x + 14, y: center.y), CGPoint(x: center.x - 6, y: center.y - 10), CGPoint(x: center.x - 6, y: center.y + 10)]
        case .none:
            return
        }

        let path = CGMutablePath()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        path.closeSubpath()
        arrow.path = path

        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 1.0
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        arrow.add(pulse, forKey: "pulse")

        layer?.addSublayer(arrow)
        arrowLayer = arrow
    }

    @objc private func nextStep() {
        arrowLayer?.removeFromSuperlayer()
        arrowLayer = nil

        if currentStep < steps.count - 1 {
            currentStep += 1
            updateStep()
        } else {
            finish()
        }
    }

    @objc private func skipGuide() {
        finish()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasSeenGuide")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            DispatchQueue.main.async {
                self?.removeFromSuperview()
            }
        }
    }

    func start() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }
}