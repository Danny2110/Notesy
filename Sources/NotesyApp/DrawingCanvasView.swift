import AppKit
import PencilKit

/// A Notes-style handwriting surface.
///
/// macOS exposes PencilKit's data model and renderer (`PKDrawing`, `PKStroke`,
/// `PKStrokePath`, `PKDrawing.image(from:scale:)`) but **not** `PKCanvasView` or
/// `PKToolPicker`, so the canvas, the tool palette, the input handling and the
/// undo stack are ours while the ink rendering is PencilKit's — the same ink
/// types Apple Notes draws with.
///
/// Geometry: `PKDrawing` uses a bottom-left origin. The canvas is flipped like
/// its host view, so event locations are converted into drawing space per event
/// and ink images are blitted with an explicit, rect-relative flip.
///
/// Performance model: committed ink is cached as one `NSImage` rendered at the
/// window's backing scale. The stroke being dragged is rendered into a small
/// tile that only ever grows to cover that stroke's own dirty area, so a drag
/// never re-renders the whole drawing.
@MainActor
final class DrawingCanvasView: NSView {
    enum Tool: String, CaseIterable, Sendable {
        case monoline, marker, pencil, crayon, fountainPen, reed, watercolor, eraser

        var title: String {
            switch self {
            case .monoline: return "Monoline"
            case .marker: return "Marker"
            case .pencil: return "Pencil"
            case .crayon: return "Crayon"
            case .fountainPen: return "Fountain Pen"
            case .reed: return "Reed"
            case .watercolor: return "Watercolor"
            case .eraser: return "Eraser"
            }
        }
    }

    // MARK: - Configuration

    /// Active tool. `.reed` needs macOS 26 and silently falls back to `.monoline`.
    var tool: Tool = .monoline {
        didSet {
            guard tool != oldValue else { return }
            if tool == .eraser || oldValue == .eraser {
                window?.invalidateCursorRects(for: self)
            }
            // A tool switch mid-gesture would produce a mixed stroke; finish cleanly.
            if gesture != .none { endGesture(at: nil, timestamp: nil, pressure: nil) }
        }
    }

    /// Ink colour for new strokes. Existing strokes keep the colour they were drawn with.
    var inkColor: NSColor = .black

    /// Point width at normal pressure/speed. Per-point widths are derived from this.
    var lineWidth: CGFloat = 6

    /// Paper colour behind the ink. No vibrancy or material is drawn inside the canvas.
    var backgroundColor: NSColor = .white {
        didSet {
            invalidateRenderedContent()
            needsDisplay = true
        }
    }

    /// Called after a stroke, an erase gesture, a clear or an undo/redo changed the ink.
    var onDrawingChanged: (() -> Void)?

    /// Image painted behind the ink, aspect-fit: an imported Apple Notes drawing
    /// the user can keep adding to. Included in `thumbnail(size:)` output.
    var backgroundImage: NSImage? {
        didSet {
            invalidateRenderedContent()
            needsDisplay = true
        }
    }

    // MARK: - Derived state

    var drawingData: Data { drawingIncludingLive.dataRepresentation() }

    var isEmpty: Bool { drawingIncludingLive.strokes.isEmpty }

    // MARK: - Load / clear / export

    /// Replaces the whole drawing. Does not call `onDrawingChanged` (external load)
    /// and resets the undo history so ⌘Z cannot undo across notes.
    func setDrawingData(_ data: Data?) {
        cancelGesture()
        var decoded = PKDrawing()
        if let data, !data.isEmpty, let loaded = try? PKDrawing(data: data) {
            decoded = loaded
        }
        drawing = decoded
        resetHistory(with: decoded)
        invalidateRenderedContent()
        needsDisplay = true
    }

    /// Removes every stroke. Undoable and reports the change.
    func clear() {
        cancelGesture()
        let current = drawing
        guard !current.strokes.isEmpty else { return }
        drawing = PKDrawing()
        invalidateRenderedContent()
        needsDisplay = true
        recordHistory(drawing.dataRepresentation(), actionName: "Clear Drawing")
        onDrawingChanged?()
    }

    /// Aspect-fit PNG-ready thumbnail of the ink, cropped to the drawing bounds.
    /// Background art (an imported drawing) is included so the list preview
    /// never renders an imported drawing as blank paper.
    func thumbnail(size: NSSize) -> NSImage? {
        let ink = drawingIncludingLive
        guard size.width > 0, size.height > 0 else { return nil }
        guard !ink.strokes.isEmpty || backgroundImage != nil else { return nil }

        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let page = CGRect(origin: .zero, size: size)
        backgroundColor.setFill()
        page.fill()

        if let art = backgroundImage {
            blitUnflipped(art, in: fittedRect(for: art.size, in: page))
        }

        if !ink.strokes.isEmpty {
            let content = ink.bounds.insetBy(dx: -8, dy: -8)
            if content.width > 0, content.height > 0 {
                let rendered = ink.image(from: content, scale: 2)
                let scale = min(size.width / content.width, size.height / content.height)
                let target = CGRect(
                    x: (size.width - content.width * scale) / 2,
                    y: (size.height - content.height * scale) / 2,
                    width: content.width * scale,
                    height: content.height * scale
                )
                blitUnflipped(rendered, in: target)
            }
        }
        return image
    }

    // MARK: - Input

    private enum Gesture {
        case none, ink, erase
    }

    private enum History {
        static let limit = 50
    }

    private struct Sample {
        var location: CGPoint
        var time: TimeInterval
        var pressure: CGFloat
        var size: CGFloat
    }

    private var drawing = PKDrawing()

    // Committed-ink cache.
    private var committedImage: NSImage?
    private var committedImageRect: CGRect = .null
    private var committedImageScale: CGFloat = 0

    // Live tile (the stroke or erase trail in progress).
    private var liveTile: NSImage?
    private var liveTileRect: CGRect = .null

    // Gesture state.
    private var gesture: Gesture = .none
    private var gestureStartData: Data?
    private var previewBaseStrokes: [PKStroke] = []
    private var samples: [Sample] = []
    private var strokeBounds: CGRect = .null
    private var strokeStartTime: TimeInterval = 0
    private var strokeCreationDate = Date()
    private var lastSampleTime: TimeInterval = 0
    private var smoothedSpeed: CGFloat = 0
    private var firstPressure: CGFloat = 0
    private var hasRealPressure = false
    private var liveStroke: PKStroke?

    // Eraser state.
    private var eraseSamples: [CGPoint] = []
    private var eraseCreationDate = Date()

    // Snapshot history, newest last, index points at the committed state.
    private var snapshots: [Data] = []
    private var snapshotIndex = 0

    /// Fallback undo manager for windows that do not vend one.
    private let localUndoManager = UndoManager()

    // MARK: - View lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        resetHistory(with: drawing)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    /// `PKDrawing` uses a bottom-left origin. The canvas is also flipped, so
    /// `convert(_:from:)` yields top-down Y that must be inverted before
    /// sampling into the drawing's bottom-up coordinate space.
    override var isFlipped: Bool { true }

    override var isOpaque: Bool {
        guard let resolved = backgroundColor.usingColorSpace(.sRGB) else { return false }
        return resolved.alphaComponent >= 0.999
    }

    override var acceptsFirstResponder: Bool { true }

    override var canBecomeKeyView: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateRenderedContent()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateRenderedContent()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateRenderedContent()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Semantic paper/ink colours resolve per appearance: re-render both caches.
        invalidateRenderedContent()
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .eraser ? Self.eraserCursor : .crosshair)
    }

    /// A hollow ring shows the erase radius; `.disappearingItem` hides the
    /// pointer entirely, which makes it impossible to aim the eraser.
    private static let eraserCursor: NSCursor = {
        let diameter: CGFloat = 22
        let image = NSImage(size: NSSize(width: diameter + 2, height: diameter + 2))
        image.lockFocus()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: diameter - 1, height: diameter - 1))
        NSColor.white.setStroke()
        ring.lineWidth = 3
        ring.stroke()
        NSColor.black.setStroke()
        ring.lineWidth = 1.2
        ring.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: diameter / 2, y: diameter / 2))
    }()

    /// Undo manager from the window, or a private one so ⌘Z always works.
    override var undoManager: UndoManager? {
        super.undoManager ?? localUndoManager
    }

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let clip = dirtyRect.intersection(bounds)
        guard !clip.isEmpty else { return }
        ensureCommittedImage()

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()

        backgroundColor.setFill()
        clip.fill()

        // Imported art sits under the ink, aspect-fit on the paper.
        drawBackgroundImage()

        if let image = committedImage {
            blit(image, in: bounds)
        }

        if let tile = liveTile, !liveTileRect.isNull {
            // `liveTileRect` is drawing space (bottom-left origin); the view is
            // flipped, so convert before painting it here.
            let tileRect = viewRect(liveTileRect).intersection(bounds)
            if !tileRect.isEmpty {
                // The tile replaces the stale committed pixels under it,
                // including the paper and any background art.
                backgroundColor.setFill()
                tileRect.fill()
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: tileRect).addClip()
                drawBackgroundImage()
                NSGraphicsContext.restoreGraphicsState()
                blit(tile, in: tileRect)
            }
        }
    }

    private func drawBackgroundImage() {
        guard let image = backgroundImage else { return }
        let rect = backgroundImageRect
        guard !rect.isNull, !rect.isEmpty else { return }
        blit(image, in: rect)
    }

    /// Blits an image so it reads upright on the page.
    ///
    /// The canvas is flipped (y down) and the image's first row is its top, so
    /// a plain `CGContext.draw` into the destination rect is already correct.
    /// `NSImage.draw(..., respectFlipped: false)` is not: it mirrors about the
    /// *view's* centre, which put live tiles on the wrong side of the canvas.
    private func blit(_ image: NSImage, in rect: CGRect) {
        guard rect.width > 0, rect.height > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
        ctx.restoreGState()
    }

    /// Blits into a normal (unflipped) image context, such as `lockFocus`.
    private func blitUnflipped(_ image: NSImage, in rect: CGRect) {
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    /// Aspect-fit size of the background art in canvas space.
    private var backgroundImageRect: CGRect {
        guard let image = backgroundImage else { return .null }
        return fittedRect(for: image.size, in: bounds)
    }

    private func fittedRect(for contentSize: NSSize, in host: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0,
              host.width > 0, host.height > 0 else { return .null }
        let scale = min(host.width / contentSize.width, host.height / contentSize.height)
        let width = contentSize.width * scale
        let height = contentSize.height * scale
        return CGRect(x: host.minX + (host.width - width) / 2,
                      y: host.minY + (host.height - height) / 2,
                      width: width, height: height)
    }

    private var renderingScale: CGFloat {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return max(1, scale)
    }

    private func invalidateRenderedContent() {
        committedImage = nil
        committedImageRect = .null
        committedImageScale = 0
        if gesture != .none, !liveTileRect.isNull {
            // Keep the in-progress ink alive across an appearance/scale change.
            refreshLiveTile(covering: [liveTileRect])
        } else {
            liveTile = nil
            liveTileRect = .null
        }
    }

    private func ensureCommittedImage() {
        let scale = renderingScale
        guard bounds.width > 0, bounds.height > 0 else { return }
        if committedImage != nil, committedImageScale == scale, committedImageRect == bounds { return }
        committedImage = drawing.image(from: bounds, scale: scale)
        committedImageRect = bounds
        committedImageScale = scale
    }

    /// Re-renders only the region the live stroke covers, growing to include everything
    /// the gesture has touched so far. Never re-renders the committed drawing.
    private func refreshLiveTile(covering rects: [CGRect]) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        var union = liveTileRect
        for rect in rects { union = union.union(rect) }
        guard !union.isNull else { return }
        union = union.intersection(bounds)
        guard !union.isNull, !union.isEmpty else { return }

        let preview = drawingIncludingLive
        let previous = liveTileRect
        liveTile = preview.image(from: union, scale: renderingScale)
        liveTileRect = union
        var dirty = viewRect(union)
        if !previous.isNull { dirty = dirty.union(viewRect(previous)) }
        setNeedsDisplay(dirty)
    }

    /// Drawing space (bottom-left origin) to view space (flipped, y down).
    private func viewRect(_ rect: CGRect) -> CGRect {
        guard !rect.isNull else { return .null }
        return CGRect(x: rect.minX,
                      y: bounds.height - rect.maxY,
                      width: rect.width,
                      height: rect.height)
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        // `PKDrawing` uses a bottom-left origin; the canvas view is flipped
        // (`isFlipped = true`), so convert the event point to bottom-left space.
        let drawingPoint = CGPoint(x: location.x, y: bounds.height - location.y)
        guard bounds.contains(drawingPoint) else { return }
        if gesture != .none { endGesture(at: nil, timestamp: nil, pressure: nil) }
        beginGesture(at: drawingPoint, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard gesture != .none else { return }
        let location = convert(event.locationInWindow, from: nil)
        let drawingPoint = CGPoint(x: location.x, y: bounds.height - location.y)
        extendGesture(to: drawingPoint, time: event.timestamp, pressure: CGFloat(event.pressure))
    }

    override func mouseUp(with event: NSEvent) {
        guard gesture != .none else { return }
        let location = convert(event.locationInWindow, from: nil)
        let drawingPoint = CGPoint(x: location.x, y: bounds.height - location.y)
        endGesture(at: drawingPoint, timestamp: event.timestamp, pressure: CGFloat(event.pressure))
    }

    private func beginGesture(at location: CGPoint, event: NSEvent) {
        gestureStartData = drawing.dataRepresentation()
        previewBaseStrokes = drawing.strokes
        samples.removeAll(keepingCapacity: true)
        eraseSamples.removeAll(keepingCapacity: true)
        strokeBounds = .null
        liveStroke = nil
        liveTile = nil
        liveTileRect = .null

        strokeStartTime = event.timestamp
        lastSampleTime = event.timestamp
        strokeCreationDate = Date()
        smoothedSpeed = 0
        hasRealPressure = false
        firstPressure = CGFloat(event.pressure)

        eraseCreationDate = Date()

        if tool == .eraser {
            gesture = .erase
            addEraseSample(at: location)
            applyErase(tail: 1)
            refreshLiveTile(covering: [eraserStampRect(near: location)])
        } else {
            gesture = .ink
            addInkSample(at: location, time: event.timestamp, pressure: CGFloat(event.pressure))
            rebuildLiveStroke()
            refreshLiveTile(covering: [strokeDirtyRect])
        }
    }

    private func extendGesture(to location: CGPoint, time: TimeInterval, pressure: CGFloat) {
        switch gesture {
        case .none:
            break
        case .ink:
            addInkSample(at: location, time: time, pressure: pressure)
            rebuildLiveStroke()
            refreshLiveTile(covering: [strokeDirtyRect])
        case .erase:
            addEraseSample(at: location)
            applyErase(tail: 2)
            refreshLiveTile(covering: [eraserStampRect(near: location)])
        }
    }

    private func endGesture(at location: CGPoint?, timestamp: TimeInterval?, pressure: CGFloat?) {
        guard gesture != .none else { return }
        switch gesture {
        case .ink:
            if let location, let timestamp {
                addInkSample(at: location, time: timestamp, pressure: pressure ?? firstPressure)
            }
            rebuildLiveStroke()
            if let stroke = liveStroke {
                drawing = PKDrawing(strokes: previewBaseStrokes + [stroke])
            }
        case .erase:
            if let location {
                addEraseSample(at: location)
                applyErase(tail: 2)
            }
            eraseSamples.removeAll(keepingCapacity: true)
        case .none:
            break
        }

        gesture = .none
        liveStroke = nil
        liveTile = nil
        liveTileRect = .null
        samples.removeAll(keepingCapacity: true)
        strokeBounds = .null
        invalidateRenderedContent()
        setNeedsDisplay(bounds)
        commitGestureHistory()
    }

    private func cancelGesture() {
        gesture = .none
        gestureStartData = nil
        previewBaseStrokes = []
        samples.removeAll(keepingCapacity: true)
        eraseSamples.removeAll(keepingCapacity: true)
        strokeBounds = .null
        liveStroke = nil
        liveTile = nil
        liveTileRect = .null
    }

    // MARK: - Stroke sampling

    private func addInkSample(at location: CGPoint, time: TimeInterval, pressure: CGFloat) {
        guard gesture == .ink else { return }
        guard samples.count < 6000 else { return }

        var deltaTime = time - lastSampleTime
        if deltaTime < 0 { deltaTime = 0 }
        lastSampleTime = time

        var distance: CGFloat = 0
        if let last = samples.last?.location {
            distance = hypot(location.x - last.x, location.y - last.y)
            // Drop duplicate points at the same pixel; PencilKit dislikes zero-length tangents.
            if distance < 0.35, samples.count > 1 { return }
        }

        let instantaneous = deltaTime > 0.0005 ? distance / CGFloat(deltaTime) : 0
        smoothedSpeed = smoothedSpeed <= 0 ? instantaneous : smoothedSpeed * 0.55 + instantaneous * 0.45

        // A plain mouse reports a constant pressure: detect that and use speed instead.
        if samples.count > 1, abs(pressure - firstPressure) > 0.03 { hasRealPressure = true }

        let size = pointSize(pressure: pressure, speed: smoothedSpeed)
        samples.append(Sample(
            location: location,
            time: max(0, time - strokeStartTime),
            pressure: hasRealPressure ? min(max(pressure, 0.01), 1) : 1,
            size: size
        ))
        strokeBounds = strokeBounds.union(CGRect(origin: location, size: .zero))
    }

    private var toolWidthScale: CGFloat {
        switch tool {
        case .monoline: return 1
        case .marker: return 1.15
        case .pencil: return 0.8
        case .crayon: return 1.25
        case .fountainPen: return 0.9
        case .reed: return 0.95
        case .watercolor: return 1.3
        case .eraser: return 1
        }
    }

    /// Per-point width: pressure when the device reports real pressure, otherwise a
    /// speed taper (fast = thinner), which is what Notes and Ink do with a mouse.
    private func pointSize(pressure: CGFloat, speed: CGFloat) -> CGFloat {
        let base = max(0.5, lineWidth) * toolWidthScale
        let factor: CGFloat
        if hasRealPressure {
            let normalized = min(max(pressure, 0.02), 1)
            factor = 0.32 + 0.68 * pow(normalized, 0.65)
        } else {
            let t = min(max((speed - 90) / 1500, 0), 1)
            let eased = t * t * (3 - 2 * t)
            factor = 1 - 0.45 * eased
        }
        return max(0.5, base * factor)
    }

    private func rebuildLiveStroke() {
        guard !samples.isEmpty else {
            liveStroke = nil
            return
        }
        let points = smoothedPoints(from: samples)
        let path = PKStrokePath(controlPoints: points, creationDate: strokeCreationDate)
        liveStroke = PKStroke(ink: PKInk(currentInkType, color: inkColor), path: path)
    }

    private var currentInkType: PKInk.InkType {
        switch tool {
        case .monoline, .eraser: return .monoline
        case .marker: return .marker
        case .pencil: return .pencil
        case .crayon: return .crayon
        case .fountainPen: return .fountainPen
        case .watercolor: return .watercolor
        case .reed:
            if #available(macOS 26.0, *) { return .reed }
            return .monoline
        }
    }

    /// Catmull-Rom through the raw samples, resampled at ~1.6pt so the stroke is a
    /// curve rather than a polyline. Size and pressure interpolate with it.
    private func smoothedPoints(from samples: [Sample]) -> [PKStrokePoint] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else {
            return [makePoint(at: first.location, timeOffset: 0, size: first.size, pressure: first.pressure)]
        }

        var points: [PKStrokePoint] = []
        points.reserveCapacity(samples.count * 4)
        var lastOffset: TimeInterval = -1

        for index in 0..<(samples.count - 1) {
            let p0 = samples[max(index - 1, 0)]
            let p1 = samples[index]
            let p2 = samples[index + 1]
            let p3 = samples[min(index + 2, samples.count - 1)]

            let segmentLength = hypot(p2.location.x - p1.location.x, p2.location.y - p1.location.y)
            let steps = max(1, min(24, Int((segmentLength / 1.6).rounded(.up))))

            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                let location = catmullRom(p0.location, p1.location, p2.location, p3.location, t)
                let timeOffset = p1.time + (p2.time - p1.time) * Double(t)
                let size = p1.size + (p2.size - p1.size) * t
                let pressure = p1.pressure + (p2.pressure - p1.pressure) * t
                let offset = max(timeOffset, lastOffset + 0.0005)
                lastOffset = offset
                points.append(makePoint(at: location, timeOffset: offset, size: size, pressure: pressure))
            }
        }

        let last = samples[samples.count - 1]
        lastOffset = max(last.time, lastOffset + 0.0005)
        points.append(makePoint(at: last.location, timeOffset: lastOffset, size: last.size, pressure: last.pressure))
        return points
    }

    private func makePoint(at location: CGPoint, timeOffset: TimeInterval, size: CGFloat, pressure: CGFloat) -> PKStrokePoint {
        let width = max(0.5, size)
        return PKStrokePoint(
            location: location,
            timeOffset: timeOffset,
            size: CGSize(width: width, height: width),
            opacity: 1,
            force: min(max(pressure, 0), 1),
            azimuth: .pi / 2,
            altitude: .pi / 2
        )
    }

    private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        func axis(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return CGPoint(
            x: axis(p0.x, p1.x, p2.x, p3.x),
            y: axis(p0.y, p1.y, p2.y, p3.y)
        )
    }

    private var strokeDirtyRect: CGRect {
        guard !strokeBounds.isNull else { return .null }
        let padding = max(lineWidth, 2) * 2 + 8
        return strokeBounds.insetBy(dx: -padding, dy: -padding)
    }

    // MARK: - Eraser

    private var eraserRadius: CGFloat {
        max(6, lineWidth)
    }

    private func addEraseSample(at location: CGPoint) {
        if let last = eraseSamples.last, hypot(location.x - last.x, location.y - last.y) < 1 { return }
        eraseSamples.append(location)
    }

    /// Applies the eraser so far. macOS 27 erases pixels exactly; earlier systems
    /// remove whole strokes that the eraser touches. Only the newest segment of the
    /// drag is re-applied so a long erase does not re-process the drawing.
    private func applyErase(tail: Int) {
        guard !eraseSamples.isEmpty else { return }
        if #available(macOS 27.0, *) {
            let path = eraserPath(tail: tail)
            drawing = drawing.erasingPath(path, mask: nil, transform: .identity)
        } else {
            drawing = removingStrokes(from: drawing, near: eraseSamples, radius: eraserRadius)
        }
    }

    private func eraserPath(tail: Int) -> PKStrokePath {
        let diameter = eraserRadius * 2
        let count = max(1, min(tail, eraseSamples.count))
        var locations = Array(eraseSamples.suffix(count))
        // A single-point path erases nothing; a stamp needs two coincident points.
        if locations.count == 1, let only = locations.first { locations.append(only) }
        let points = locations.enumerated().map { index, location in
            PKStrokePoint(
                location: location,
                timeOffset: Double(index) * 0.004,
                size: CGSize(width: diameter, height: diameter),
                opacity: 1,
                force: 1,
                azimuth: .pi / 2,
                altitude: .pi / 2
            )
        }
        return PKStrokePath(controlPoints: points, creationDate: eraseCreationDate)
    }

    private func eraserStampRect(near location: CGPoint) -> CGRect {
        eraserDirtyRect(from: eraseSamples.last ?? location, to: location)
    }

    private func eraserDirtyRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let radius = eraserRadius + 2
        let minX = min(start.x, end.x) - radius
        let minY = min(start.y, end.y) - radius
        let maxX = max(start.x, end.x) + radius
        let maxY = max(start.y, end.y) + radius
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Stroke eraser for macOS 14–26: drops any stroke whose ink comes within the
    /// eraser radius of the drag path.
    private func removingStrokes(from drawing: PKDrawing, near points: [CGPoint], radius: CGFloat) -> PKDrawing {
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { return drawing }

        var eraserPoints = points
        if eraserPoints.count > 48 {
            let step = max(1, eraserPoints.count / 48)
            eraserPoints = stride(from: 0, to: eraserPoints.count, by: step).map { eraserPoints[$0] }
        }
        let eraserRects = eraserPoints.map {
            CGRect(x: $0.x - radius, y: $0.y - radius, width: radius * 2, height: radius * 2)
        }

        let kept = strokes.filter { stroke in
            let bounds = stroke.renderBounds
            guard !bounds.isEmpty else { return true }
            let candidates = bounds.insetBy(dx: -radius, dy: -radius)
            guard eraserRects.contains(where: { $0.intersects(candidates) }) else { return true }
            return !strokeHits(stroke, eraser: eraserPoints, radius: radius)
        }
        guard kept.count != strokes.count else { return drawing }
        return PKDrawing(strokes: kept)
    }

    private func strokeHits(_ stroke: PKStroke, eraser: [CGPoint], radius: CGFloat) -> Bool {
        let path = stroke.path
        guard !path.isEmpty else { return false }
        let step = max(1, path.count / 240)
        var index = 0
        while index < path.count {
            let point = path[index]
            let reach = radius + point.size.width / 2
            for target in eraser where hypot(point.location.x - target.x, point.location.y - target.y) <= reach {
                return true
            }
            index += step
        }
        return false
    }

    // MARK: - Undo / redo

    private var drawingIncludingLive: PKDrawing {
        guard gesture == .ink, let stroke = liveStroke else { return drawing }
        return PKDrawing(strokes: drawing.strokes + [stroke])
    }

    private func resetHistory(with drawing: PKDrawing) {
        snapshots = [drawing.dataRepresentation()]
        snapshotIndex = 0
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Records the gesture's end state and registers one undo step for it.
    private func commitGestureHistory() {
        guard let startData = gestureStartData else { return }
        gestureStartData = nil
        let current = drawing.dataRepresentation()
        guard current != startData else { return }
        if snapshots.isEmpty || snapshots[snapshotIndex] != startData {
            // A commit slipped in without its start snapshot; keep the stack honest.
            snapshots = [startData]
            snapshotIndex = 0
        }
        recordHistory(current, actionName: gestureActionName)
    }

    private var gestureActionName: String {
        tool == .eraser ? "Erase" : "Draw"
    }

    private func recordHistory(_ data: Data, actionName: String) {
        if snapshotIndex < snapshots.count - 1 {
            snapshots.removeSubrange((snapshotIndex + 1)...)
        }
        if snapshots.last != data {
            snapshots.append(data)
        }
        snapshotIndex = snapshots.count - 1
        let overflow = snapshots.count - History.limit
        if overflow > 0 {
            snapshots.removeFirst(overflow)
            snapshotIndex -= overflow
        }
        registerUndoStep(selector: #selector(performUndoStep(_:)), actionName: actionName)
        onDrawingChanged?()
    }

    /// Selector-based registration (rather than the closure API) so that
    /// `removeAllActions(withTarget: self)` really clears our steps when a
    /// different note is loaded — the closure API hides the target in a wrapper.
    private func registerUndoStep(selector: Selector, actionName: String) {
        undoManager?.registerUndo(withTarget: self, selector: selector, object: nil)
        undoManager?.setActionName(actionName)
    }

    @objc private func performUndoStep(_ sender: Any?) {
        stepBack()
    }

    @objc private func performRedoStep(_ sender: Any?) {
        stepForward()
    }

    private func stepBack() {
        guard snapshotIndex > 0 else { return }
        snapshotIndex -= 1
        apply(snapshots[snapshotIndex])
        registerUndoStep(selector: #selector(performRedoStep(_:)), actionName: "Drawing")
    }

    private func stepForward() {
        guard snapshotIndex < snapshots.count - 1 else { return }
        snapshotIndex += 1
        apply(snapshots[snapshotIndex])
        registerUndoStep(selector: #selector(performUndoStep(_:)), actionName: "Drawing")
    }

    private func apply(_ data: Data) {
        guard let restored = try? PKDrawing(data: data) else { return }
        cancelGesture()
        drawing = restored
        invalidateRenderedContent()
        setNeedsDisplay(bounds)
        onDrawingChanged?()
    }
}
