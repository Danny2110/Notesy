import AppKit

/// The editor for a drawing note: themed paper holding a `DrawingCanvasView`
/// plus the Notes-style floating tool palette (inks, colours, widths, undo).
///
/// Contract with `NotesWorkspaceView` (frozen):
/// - `configure(theme:)` is called on every theme / appearance change.
/// - `load(strokeData:imageFile:)` swaps in another note's content. `strokeData`
///   is the editable `PKDrawing` payload; `imageFile` is an imported PNG (shown
///   as the paper under the ink) when the note came from Apple Notes.
/// - `strokeData` and `thumbnail(size:)` are how the workspace persists and
///   previews the note.
/// - `isEmpty` reports whether there are any strokes (used by save logic).
/// - `canvas` gives the workspace direct access to the ink canvas view
///   for first-responder calls.
///
/// OWNER: DrawingEditorView.swift (integration and canvas are other files).
@MainActor
final class DrawingEditorView: NSView {
    /// The editor matches `NotesWorkspaceView` (flipped), so mouse coords are
    /// top-down Y; they need inversion before sampling for PKDrawing.
    override var isFlipped: Bool { true }

    /// Ink changed; the workspace debounces a save of `strokeData`.
    var onDrawingChanged: (() -> Void)?

    /// The backing ink canvas. Exposed so the workspace can make it first responder.
    let canvas: DrawingCanvasView

    /// Whether the ink has any strokes. Used by the workspace to avoid saving
    /// empty canvases back to disk.
    var isEmpty: Bool { canvas.isEmpty }

    /// Identity of the note whose content is on screen. The workspace sets this
    /// before `load(...)` so re-selecting the same note keeps its undo stack.
    var noteIdentity: UUID?

    // MARK: - Palette state

    private static let inkColors: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1),   // black
        NSColor(srgbRed: 0.45, green: 0.45, blue: 0.47, alpha: 1),   // grey
        NSColor(srgbRed: 0.90, green: 0.25, blue: 0.22, alpha: 1),   // red
        NSColor(srgbRed: 0.96, green: 0.55, blue: 0.14, alpha: 1),   // orange
        NSColor(srgbRed: 0.97, green: 0.79, blue: 0.17, alpha: 1),   // yellow
        NSColor(srgbRed: 0.25, green: 0.67, blue: 0.35, alpha: 1),   // green
        NSColor(srgbRed: 0.13, green: 0.61, blue: 0.64, alpha: 1),   // teal
        NSColor(srgbRed: 0.19, green: 0.46, blue: 0.92, alpha: 1),   // blue
        NSColor(srgbRed: 0.55, green: 0.33, blue: 0.85, alpha: 1),   // purple
        NSColor(srgbRed: 0.93, green: 0.34, blue: 0.60, alpha: 1),   // pink
        NSColor(srgbRed: 0.52, green: 0.36, blue: 0.25, alpha: 1),   // brown
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1)    // white
    ]

    private static let lineWidths: [CGFloat] = [2, 5, 10]

    private static let toolSymbols: [DrawingCanvasView.Tool: String] = [
        .monoline: "pencil.tip",
        .marker: "highlighter",
        .pencil: "pencil",
        .crayon: "scribble.variable",
        .fountainPen: "pencil.line",
        .watercolor: "drop.fill",
        .eraser: "eraser"
    ]

    private let paletteGlass = GlassSurfaceView.bar(cornerRadius: 18)
    private let paletteContent = PaletteContentView()
    private var toolButtons: [(tool: DrawingCanvasView.Tool, button: PaletteButton)] = []
    private var colorButtons: [(color: NSColor, button: PaletteButton)] = []
    private var widthButtons: [(width: CGFloat, button: PaletteButton)] = []
    private var actionButtons: [PaletteButton] = []
    private var separatorViews: [NSView] = []

    /// A drawing note gets its own sheet of paper; a sketch laid over a note's
    /// text draws none, so the words stay readable under the ink.
    var showsPaper = true {
        didSet { applyPaperColor() }
    }

    private var theme: NotesyTheme = getDefaultTheme()
    /// True once the user picks a swatch; theme changes then leave the ink alone.
    private var hasPickedColor = false
    private var lastInkTool: DrawingCanvasView.Tool = .monoline

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        canvas = DrawingCanvasView()
        super.init(frame: frameRect)
        addSubview(canvas)
        buildPalette()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    // MARK: - Configuration

    func configure(theme: NotesyTheme) {
        self.theme = theme
        // Paper follows the note page, so a drawing never looks like a new sheet
        // pasted on top of the themed document.
        applyPaperColor()
        if !hasPickedColor {
            canvas.inkColor = isDarkTheme ? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
                                          : NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        }

        let accent = theme.accentColor
        for (_, button) in toolButtons {
            button.accent = accent
            button.contentTintColor = theme.textPrimary
        }
        for (_, button) in colorButtons { button.accent = accent }
        for (_, button) in widthButtons {
            button.accent = accent
            button.contentTintColor = theme.textPrimary
            button.previewColor = canvas.inkColor
        }
        for button in actionButtons {
            button.accent = accent
            button.contentTintColor = theme.textPrimary
        }
        for separator in separatorViews {
            separator.layer?.backgroundColor = theme.borderColor.withAlphaComponent(0.7).cgColor
        }
        paletteGlass.tintColor = theme.cardBackground.withAlphaComponent(0.22)
        refreshSelection()
        needsLayout = true
    }

    private func applyPaperColor() {
        canvas.backgroundColor = showsPaper ? theme.readingBackground : .clear
    }

    /// A dark theme paints dark paper, so the default pen has to be light —
    /// judged from the theme's text colour, which is light on dark surfaces.
    private var isDarkTheme: Bool {
        guard let color = theme.textPrimary.usingColorSpace(.sRGB) else { return false }
        return color.brightnessComponent > 0.5
    }

    /// Swaps in another note's content. `strokeData` is the editable strokes;
    /// `imageFile` is an optional pre-imported PNG shown as the paper behind
    /// the ink. Re-selecting the same note keeps the live drawing and its undo
    /// history instead of reloading (and resetting) it.
    func load(strokeData: Data?, imageFile: String?) {
        guard noteIdentity != loadedIdentity else { return }
        loadedIdentity = noteIdentity

        // Background art (from import or drag-drop) goes behind all ink.
        if let file = imageFile {
            canvas.backgroundImage = DrawingMedia.image(for: file)
        } else {
            canvas.backgroundImage = nil
        }
        // Always replace the ink: a note with no stroke sidecar is a blank
        // drawing, and must not inherit the previously selected note's strokes.
        canvas.setDrawingData(strokeData)

        hasPickedColor = false
        configure(theme: theme)
        needsDisplay = true
    }

    private var loadedIdentity: UUID?

    // MARK: - Persistence

    var strokeData: Data { canvas.drawingData }

    func thumbnail(size: NSSize) -> NSImage? {
        canvas.thumbnail(size: size)
    }

    /// Makes the ink canvas the first responder so keyboard shortcuts (⌘Z,
    /// ⇧⌘Z) reach the canvas undo manager directly.
    func focusCanvas() {
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Layout

    private let barHeight: CGFloat = 70
    private let barBottomInset: CGFloat = 18
    private var barWidth: CGFloat {
        min(452, max(220, bounds.width - 24))
    }

    /// Base measurements for one palette row, shrunk uniformly when the window
    /// is too narrow to hold the chips at full size.
    private struct PaletteMetrics {
        var chip: CGFloat
        var swatch: CGFloat
        var separator: CGFloat
        var gap: CGFloat
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        layoutPalette()
    }

    private func layoutPalette() {
        let width = barWidth
        paletteGlass.frame = NSRect(x: (bounds.width - width) / 2,
                                    y: bounds.height - barHeight - barBottomInset,
                                    width: width, height: barHeight)
        layoutPaletteRows(in: paletteGlass.bounds)

        // Keep the palette above the ink: `canvas` is added first.
        if paletteGlass.superview == self { addSubview(paletteGlass, positioned: .above, relativeTo: nil) }
    }

    private func layoutPaletteRows(in host: CGRect) {
        let sideInset: CGFloat = 12
        let available = max(160, host.width - sideInset * 2)

        var rowOne: [NSView] = toolButtons.map(\.button)
        if let separator = separatorViews.first { rowOne.append(separator) }
        rowOne.append(contentsOf: widthButtons.map(\.button))

        var rowTwo: [NSView] = colorButtons.map(\.button)
        if separatorViews.count > 1 { rowTwo.append(separatorViews[1]) }
        rowTwo.append(contentsOf: actionButtons.filter { $0.isHidden == false })

        let base = PaletteMetrics(chip: 28, swatch: 22, separator: 11, gap: 4)
        // One scale for both rows keeps every chip the same size and gets
        // both rows inside the bar on narrow windows.
        let needed = max(rowWidth(rowOne, metrics: base), rowWidth(rowTwo, metrics: base))
        let scale = max(0.6, min(1, available / max(1, needed)))
        var metrics = base
        metrics.chip = (base.chip * scale).rounded()
        metrics.swatch = (base.swatch * scale).rounded()
        metrics.separator = (base.separator * scale).rounded()
        metrics.gap = max(3, (base.gap * scale).rounded())

        let rowGap: CGFloat = 8
        let contentHeight = metrics.chip + rowGap + metrics.swatch
        let top = (host.height - contentHeight) / 2
        place(rowOne, in: host, y: top, height: metrics.chip, metrics: metrics)
        place(rowTwo, in: host, y: top + metrics.chip + rowGap, height: metrics.swatch, metrics: metrics)
    }

    private func rowWidth(_ row: [NSView], metrics: PaletteMetrics) -> CGFloat {
        let items = row.reduce(CGFloat.zero) { $0 + itemWidth($1, metrics: metrics) }
        return items + metrics.gap * CGFloat(max(0, row.count - 1))
    }

    private func itemWidth(_ view: NSView, metrics: PaletteMetrics) -> CGFloat {
        guard view is PaletteButton else { return metrics.separator }
        return colorButtons.contains { $0.button === view } ? metrics.swatch : metrics.chip
    }

    private func place(_ row: [NSView], in host: CGRect, y: CGFloat, height: CGFloat, metrics: PaletteMetrics) {
        var x = host.midX - rowWidth(row, metrics: metrics) / 2
        for view in row {
            let width = itemWidth(view, metrics: metrics)
            if view is PaletteButton {
                view.frame = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
            } else {
                let separatorHeight = max(10, (height * 0.8).rounded())
                view.frame = NSRect(x: (x + (width - 1) / 2).rounded(),
                                    y: (y + (height - separatorHeight) / 2).rounded(),
                                    width: 1, height: separatorHeight)
            }
            x += width + metrics.gap
        }
    }

    // MARK: - Palette construction

    private func buildPalette() {
        paletteGlass.style = .clear
        paletteGlass.tintColor = theme.cardBackground.withAlphaComponent(0.22)
        paletteGlass.contentView = paletteContent
        addSubview(paletteGlass)

        for tool in DrawingCanvasView.Tool.allCases {
            let button = makeChip(help: tool.title)
            button.image = NSImage(systemSymbolName: Self.toolSymbols[tool] ?? "pencil.tip",
                                   accessibilityDescription: tool.title)
            button.action = #selector(pickTool(_:))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            paletteContent.addSubview(button)
            toolButtons.append((tool, button))
        }

        separatorViews.append(makeSeparator())
        separatorViews.append(makeSeparator())
        for separator in separatorViews { paletteContent.addSubview(separator) }

        for width in Self.lineWidths {
            let button = makeChip(help: "Line width \(Int(width)) pt")
            button.previewWidth = width
            button.action = #selector(pickWidth(_:))
            button.identifier = NSUserInterfaceItemIdentifier("width-\(Int(width))")
            paletteContent.addSubview(button)
            widthButtons.append((width, button))
        }

        let undo = makeChip(help: "Undo (⌘Z)")
        undo.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")
        undo.action = #selector(undoTapped)
        paletteContent.addSubview(undo)

        let redo = makeChip(help: "Redo (⇧⌘Z)")
        redo.image = NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")
        redo.action = #selector(redoTapped)
        paletteContent.addSubview(redo)

        let clear = makeChip(help: "Clear drawing")
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear drawing")
        clear.action = #selector(clearTapped)
        paletteContent.addSubview(clear)

        actionButtons = [undo, redo, clear]

        for color in Self.inkColors {
            let button = makeChip(help: colorName(for: color))
            button.swatchColor = color
            button.action = #selector(pickColor(_:))
            paletteContent.addSubview(button)
            colorButtons.append((color, button))
        }

        canvas.tool = .monoline
        canvas.lineWidth = 5
        refreshSelection()
    }

    private func makeChip(help: String) -> PaletteButton {
        let button = PaletteButton()
        button.isBordered = false
        button.focusRingType = .none
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.toolTip = help
        button.accent = theme.accentColor
        button.contentTintColor = theme.textPrimary
        return button
    }

    private func makeSeparator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 0.5
        view.layer?.backgroundColor = theme.borderColor.withAlphaComponent(0.7).cgColor
        return view
    }

    // MARK: - Palette actions

    @objc private func pickTool(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let tool = DrawingCanvasView.Tool(rawValue: raw) else { return }
        if tool != .eraser { lastInkTool = tool }
        canvas.tool = tool
        refreshSelection()
    }

    @objc private func pickColor(_ sender: NSButton) {
        guard let index = colorButtons.firstIndex(where: { $0.button === sender }) else { return }
        canvas.inkColor = colorButtons[index].color
        hasPickedColor = true
        if canvas.tool == .eraser { canvas.tool = lastInkTool }
        for (_, button) in widthButtons { button.previewColor = canvas.inkColor }
        refreshSelection()
    }

    @objc private func pickWidth(_ sender: NSButton) {
        guard let index = widthButtons.firstIndex(where: { $0.button === sender }) else { return }
        canvas.lineWidth = widthButtons[index].width
        refreshSelection()
    }

    @objc private func undoTapped() {
        canvas.undo(nil)
        refreshSelection()
    }

    @objc private func redoTapped() {
        canvas.redo(nil)
        refreshSelection()
    }

    @objc private func clearTapped() {
        canvas.clear()
        refreshSelection()
    }

    private func refreshSelection() {
        for (tool, button) in toolButtons { button.isSelected = canvas.tool == tool }
        for (color, button) in colorButtons {
            button.isSelected = canvas.tool != .eraser && Self.matches(canvas.inkColor, color)
        }
        for (width, button) in widthButtons { button.isSelected = abs(canvas.lineWidth - width) < 0.01 }
        needsDisplay = true
    }

    private static func matches(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    private func colorName(for color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "Ink colour" }
        let saturation = c.saturationComponent
        let brightness = c.brightnessComponent
        if saturation < 0.12 {
            return brightness > 0.8 ? "White ink" : (brightness > 0.3 ? "Grey ink" : "Black ink")
        }
        switch c.hueComponent * 360 {
        case ..<15: return "Red ink"
        case ..<45: return "Orange ink"
        case ..<70: return "Yellow ink"
        case ..<160: return "Green ink"
        case ..<200: return "Teal ink"
        case ..<255: return "Blue ink"
        case ..<290: return "Purple ink"
        case ..<335: return "Pink ink"
        default: return "Red ink"
        }
    }

    // MARK: - Theming

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configure(theme: notesyPalette(for: UserDefaults.standard.selectedThemeID ?? .amber,
                                       dark: effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
    }
}

// MARK: - Palette pieces

/// Flipped host for the palette chips; the glass installs it unflipped.
private final class PaletteContentView: NSView {
    override var isFlipped: Bool { true }
}

/// A borderless chip that paints its own selection state, colour swatch or
/// line-width preview. `NSButton` keeps click, tooltip and accessibility
/// behaviour; only the drawing is custom.
private final class PaletteButton: NSButton {
    var isSelected = false { didSet { needsDisplay = true } }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var swatchColor: NSColor? { didSet { needsDisplay = true } }
    var previewWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var previewColor: NSColor = .labelColor { didSet { needsDisplay = true } }

    override var isHighlighted: Bool {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)

        if let swatch = swatchColor {
            swatch.setFill()
            path.fill()
            if isSelected {
                accent.setStroke()
                path.lineWidth = 2.5
            } else {
                NSColor.labelColor.withAlphaComponent(0.22).setStroke()
                path.lineWidth = 0.5
            }
            path.stroke()
            return
        }

        if previewWidth > 0 {
            if isSelected {
                accent.withAlphaComponent(0.20).setFill()
                path.fill()
            } else if isHighlighted {
                NSColor.labelColor.withAlphaComponent(0.08).setFill()
                path.fill()
            }
            let barHeight = max(1.5, min(previewWidth, rect.height - 8))
            let bar = NSRect(x: rect.midX - 8, y: rect.midY - barHeight / 2, width: 16, height: barHeight)
            previewColor.setFill()
            NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            return
        }

        if isSelected {
            accent.withAlphaComponent(0.20).setFill()
            path.fill()
        } else if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}
