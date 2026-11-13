import AppKit

private struct WorkspaceNote: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var body: String
    var folder: String
    var modified: Date = Date()
    var isCanvas = false
    /// Whether this note is a handwriting/drawing note (distinct from canvas cards).
    var isDrawing = false
    var canvasBlocks: [NoteBlock] = []
    var connections: [NoteConnection] = []
    var attachments: [Attachment] = []
    /// Identifier of the Apple Notes note this was imported from, if any.
    /// Used to make repeated imports idempotent.
    var sourceID: String? = nil
    /// PNG file name inside `DrawingMedia.drawingsDirectory`. Used when the
    /// drawing came from an imported Apple Notes attachment or a dragged-in
    /// image — it becomes the paper under the ink.
    var drawingFile: String? = nil
    /// Sidecar file name (`"<uuid>.pkdrawing"`) for the editable strokes.
    var drawingStrokeFile: String? = nil
    /// Small preview PNG rendered from the strokes, used as the list thumbnail.
    var drawingPreviewFile: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, title, body, folder, modified, isCanvas, isDrawing, canvasBlocks, connections, attachments, sourceID, drawingFile, drawingStrokeFile, drawingPreviewFile
    }

    init(id: UUID = UUID(), title: String, body: String, folder: String, modified: Date = Date(), isCanvas: Bool = false, isDrawing: Bool = false,
          canvasBlocks: [NoteBlock] = [], connections: [NoteConnection] = [], attachments: [Attachment] = [],
          sourceID: String? = nil, drawingFile: String? = nil, drawingStrokeFile: String? = nil, drawingPreviewFile: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.folder = folder
        self.modified = modified
        self.isCanvas = isCanvas
        self.isDrawing = isDrawing
        self.canvasBlocks = canvasBlocks
        self.connections = connections
        self.attachments = attachments
        self.sourceID = sourceID
        self.drawingFile = drawingFile
        self.drawingStrokeFile = drawingStrokeFile
        self.drawingPreviewFile = drawingPreviewFile
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        folder = try values.decode(String.self, forKey: .folder)
        modified = try values.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
        isCanvas = try values.decodeIfPresent(Bool.self, forKey: .isCanvas) ?? false
        isDrawing = try values.decodeIfPresent(Bool.self, forKey: .isDrawing) ?? false
        canvasBlocks = try values.decodeIfPresent([NoteBlock].self, forKey: .canvasBlocks) ?? []
        connections = try values.decodeIfPresent([NoteConnection].self, forKey: .connections) ?? []
        // Synthesized `Encodable` has always written attachments; without this
        // decode they were dropped on every load.
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID)
        drawingFile = try values.decodeIfPresent(String.self, forKey: .drawingFile)
        drawingStrokeFile = try values.decodeIfPresent(String.self, forKey: .drawingStrokeFile)
        drawingPreviewFile = try values.decodeIfPresent(String.self, forKey: .drawingPreviewFile)
    }

    /// Explicit, because relying on the synthesized encoder left `attachments`
    /// and `sourceID` out of the store: the custom `init(from:)` made the
    /// synthesis conservative, so imported notes came back without their
    /// Apple Notes id and every re-import duplicated all 257.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(folder, forKey: .folder)
        try container.encode(modified, forKey: .modified)
        try container.encode(isCanvas, forKey: .isCanvas)
        try container.encode(isDrawing, forKey: .isDrawing)
        try container.encode(canvasBlocks, forKey: .canvasBlocks)
        try container.encode(connections, forKey: .connections)
        try container.encode(attachments, forKey: .attachments)
        try container.encodeIfPresent(sourceID, forKey: .sourceID)
        try container.encodeIfPresent(drawingFile, forKey: .drawingFile)
        try container.encodeIfPresent(drawingStrokeFile, forKey: .drawingStrokeFile)
        try container.encodeIfPresent(drawingPreviewFile, forKey: .drawingPreviewFile)
    }
}
/// Outcome of one Apple Notes import pass, for the completion alert.
struct AppleNotesImportSummary {
    let imported: Int
    let updated: Int
    let skipped: Int
    let folders: Int
}

/// File attachment for text notes
struct Attachment: Codable, Identifiable {
    var id: UUID = UUID()
    var fileName: String
    var fileURL: URL?
    var fileData: Data?
    var mimeType: String
    var dateAdded: Date = Date()
    
    init(fileName: String, fileURL: URL? = nil, fileData: Data? = nil, mimeType: String) {
        self.fileName = fileName
        self.fileURL = fileURL
        self.fileData = fileData
        self.mimeType = mimeType
    }
}

/// Three-column, native Notes-style workspace backed by a small local JSON store.
@MainActor
final class NotesWorkspaceView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    var onOpenSettings: (() -> Void)?
    
    /// Chosen theme. Only the ID is stored; the palette is resolved on demand
    /// for the appearance in effect, so a dark palette can never end up in a
    /// light window (or the reverse).
    private var themeID: ThemeID = UserDefaults.standard.selectedThemeID ?? .amber
    private var theme: NotesyTheme { themeForID(themeID).resolved(for: effectiveAppearance) }

    /// True once `init` has finished wiring the view tree. Appearance
    /// notifications can arrive while the view is being attached to a window,
    /// before the subviews exist; syncing then would touch nil layers.
    private var isConfigured = false

    /// Update the theme and sync colors
    func setTheme(_ newThemeID: ThemeID) {
        themeID = newThemeID
        syncThemeColors()
    }
    
    private var notes: [WorkspaceNote] = [] { didSet { save() } }
    private var folders: [String] = ["Notes"] { didSet { save() } }
    private var selectedFolder = "Notes"
    private var selectedNoteID: UUID?
    private var canvasViews: [UUID: WorkspaceScrollView] = [:]
    private var canvasControlButtons: [NSButton] = []
    private var canvasControlSurfaces: [GlassSurfaceView] = []
    private var drawingViews: [UUID: DrawingEditorView] = [:]
    /// Id of the currently-loaded drawing note; nil means none loaded.
    /// Prevents `load(strokeData:)` from wiping ink when reselecting the same note.
    private var loadedDrawingID: UUID? = nil
    /// Regular (text) note currently shown in sketch mode. Stored per note so
    /// switching away and back keeps the sketch open, while other notes keep
    /// their normal text editor.
    private var sketchNoteID: UUID? = nil
    /// Toolbar button that opens / closes the inline sketch for a text note.
    private var sketchButton: NSButton? = nil
    /// Pending debounced save for a drawing note being edited.
    private var pendingDrawingSave: UUID? = nil
    /// Work item for the debounce timer.
    private var drawingSaveWorkItem: DispatchWorkItem? = nil
    private var toolbarButtonSurfaces: [ObjectIdentifier: GlassSurfaceView] = [:]
    /// Debounced store write for in-place note edits.
    private var storeSaveWorkItem: DispatchWorkItem? = nil
    private var leftToolbarButtons: [NSButton] = []
    private var formattingToolbarButtons: [NSButton] = []
    private var rightToolbarButtons: [NSButton] = []
    private var query = ""
    private var showsSidebar = true
    private var showsNotesList = true
    private var showsToolbar = true
    private var isUpdatingEditor = false
    /// True only while `load()` is populating the model from disk. `save()` is
    /// a no-op then, otherwise the first `didSet` writes an empty store back
    /// over the file we just read.
    private var isRestoring = false
    /// True while a bulk merge is assigning `notes` / `folders`. Suppresses the
    /// `didSet` saves so one import writes the store once, not per note.
    private var isBatchingSave = false
    private var isImportingNotes = false
    private var importProgressAlert: NSAlert?

    /// Ambient gradient behind every piece of chrome; gives the glass something to refract.
    private let backdrop = AmbientBackdropView()
    private lazy var toolbarGlass = GlassSurfaceView.bar(cornerRadius: 22)
    private lazy var sidebarGlass = GlassSurfaceView.panel(cornerRadius: 22)
    private let toolbarContent = NSView()
    /// Plain flipped container: folder rows are positioned by frame so the
    /// glass rows never fight AppKit's own constraints inside `NSStackView`.
    private let folderStack = FlippedStackView()
    /// Live folder row surfaces, top to bottom, used for frame layout.
    private var folderRows: [NSView] = []
    private let folderScroll = NSScrollView()
    private let notesTable = NSTableView()
    private let notesScroll = NSScrollView()
    /// Glass note list panel, matching the floating chrome.
    private lazy var listCard = GlassSurfaceView.panel(cornerRadius: 22)
    /// Opaque rounded page behind the title + editor for text notes.
    private let pageCard = RoundedCardView()
    private let editorScroll = NSScrollView()
    private let editor = NSTextView()
    private let titleField = NSTextField(string: "")
    private let searchField = NSSearchField()
    private let folderHeader = NSTextField(labelWithString: "Notes")
    /// Floating glass zoom control over the canvas.
    private let zoomHUD = GlassSurfaceView.control(cornerRadius: 18)
    private let zoomLabel = NSTextField(labelWithString: "100%")
    private var zoomOutButton: NSButton!
    private var zoomInButton: NSButton!
    /// The view inside the HUD's glass, laid out in HUD coordinates.
    private let zoomHUDContent = NSView()
    /// Floating control that stays visible while the toolbar is hidden, so the
    /// bar can always be brought back without hunting through the menu.
    private let toolbarReveal = GlassSurfaceView.control(cornerRadius: 14)
    private let toolbarRevealButton = NSButton()
    private var newNoteButton: NSButton!
    private var listColumnWidth: CGFloat = 242
    /// Guards `selectNote` against re-entry from `selectRowIndexes` while a
    /// text field is finishing its edit.
    private var isSelectingNote = false

    private var visibleNotes: [WorkspaceNote] {
        notes.filter { note in
            let inFolder: Bool
            if selectedFolder == "All iCloud" {
                inFolder = true
            } else if selectedFolder == "Canvas" {
                inFolder = note.isCanvas
            } else if selectedFolder == "Drawings" {
                inFolder = note.isDrawing
            } else {
                // A folder shows everything nested beneath it as well.
                inFolder = note.folder == selectedFolder || note.folder.hasPrefix(selectedFolder + "/")
            }
            let matches = query.isEmpty || note.title.localizedCaseInsensitiveContains(query) || note.body.localizedCaseInsensitiveContains(query)
            return inFolder && matches
        }.sorted { $0.modified > $1.modified }
    }

    override var isFlipped: Bool { true }
    // Takes focus so the search field does not launch with a focus ring.
    override var acceptsFirstResponder: Bool { true }

    /// Sidebar and list shift left when the sidebar is hidden, so no dead gutter remains.
    /// When notes list is hidden, detail view takes its place.
    private var listX: CGFloat {
        if !showsSidebar && !showsNotesList { return 8 }
        if showsSidebar && !showsNotesList { return 248 }
        return showsSidebar ? 248 : 8
    }
    private var listWidth: CGFloat { showsNotesList ? listColumnWidth : 0 }
    private var detailX: CGFloat { listX + listWidth + (showsNotesList ? 8 : 0) }
    private var detailWidth: CGFloat { max(0, bounds.width - detailX - 8) }
    private var detailFrame: NSRect {
        let detailTop: CGFloat = showsToolbar ? 68 : 12
        return NSRect(x: detailX, y: detailTop, width: detailWidth, height: max(0, bounds.height - detailTop - 8))
    }

    /// The page area below the title band. Drawing editors and the text editor
    /// share it so the title is never covered by ink.
    private var detailBodyFrame: NSRect {
        let detailTop: CGFloat = showsToolbar ? 68 : 12
        let bodyTop = detailTop + 24 + 40 + 10
        return NSRect(x: detailX, y: bodyTop, width: detailWidth, height: max(0, bounds.height - bodyTop - 8))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        load()
        backdrop.tone = .chrome
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        configureToolbar()
        configureSidebar()
        configureNotesList()
        configureEditor()
        configureCanvasHUD()
        [toolbarGlass, sidebarGlass, listCard, pageCard, editorScroll, titleField, zoomHUD].forEach(addSubview)
        rebuildFolderRows()
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) }
        else { showEmptyEditor() }

        // Apply theme colors after setup
        isConfigured = true
        syncThemeColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    /// A light/dark switch has to repaint every themed surface, not just the
    /// ones AppKit names as dynamic colors.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard isConfigured else { return }
        syncThemeColors()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        // Floating toolbar bar, inset from every window edge so its radius reads.
        let toolbarY: CGFloat = showsToolbar ? 8 : -56
        toolbarGlass.frame = NSRect(x: 10, y: toolbarY, width: max(0, bounds.width - 20), height: 56)
        toolbarGlass.isHidden = !showsToolbar
        toolbarContent.frame = NSRect(origin: .zero, size: toolbarGlass.bounds.size)

        // While the bar is hidden, leave a small pill afloat so it can be restored.
        toolbarReveal.isHidden = showsToolbar
        if !showsToolbar {
            let revealSide: CGFloat = 34
            toolbarReveal.frame = NSRect(x: max(12, bounds.width - revealSide - 16), y: 10,
                                         width: revealSide, height: revealSide)
            addSubview(toolbarReveal, positioned: .above, relativeTo: nil)
        }

        // Floating sidebar panel, inset from the window edges and above the bar's band.
        let sidebarTop: CGFloat = showsToolbar ? 68 : 12
        sidebarGlass.isHidden = !showsSidebar
        sidebarGlass.frame = NSRect(x: 8, y: sidebarTop, width: 232, height: max(0, bounds.height - sidebarTop - 8))
        folderScroll.frame = sidebarGlass.bounds
        folderStack.frame = NSRect(x: 0, y: 0, width: max(0, sidebarGlass.bounds.width),
                                   height: max(sidebarGlass.bounds.height, CGFloat(folderRows.count) * 40 + 22))
        layoutFolderRows()

        // Notes list panel (middle) - can be hidden
        let listTop: CGFloat = showsToolbar ? 68 : 12
        listCard.isHidden = !showsNotesList
        listCard.frame = NSRect(x: listX, y: listTop, width: listWidth, height: max(0, bounds.height - listTop - 8))
        notesScroll.frame = listCard.bounds
        notesTable.frame = NSRect(origin: .zero, size: notesScroll.contentSize)
        
        // Detail view (right) - expands when list is hidden
        let detailTop: CGFloat = showsToolbar ? 68 : 12
        pageCard.frame = NSRect(x: detailX, y: detailTop, width: detailWidth, height: max(0, bounds.height - detailTop - 8))
        // Title sits on its own band at the top of the page card; the editor
        // starts below it so body text never runs underneath the title.
        let titleTop = detailTop + 24
        let titleHeight: CGFloat = 40
        titleField.frame = NSRect(x: detailX + 48, y: titleTop, width: max(0, detailWidth - 96), height: titleHeight)
        let bodyTop = titleTop + titleHeight + 10
        let bodyHeight = max(0, bounds.height - bodyTop - 8)
        editorScroll.frame = NSRect(x: detailX, y: bodyTop, width: detailWidth, height: bodyHeight)
        editor.frame = NSRect(x: 0, y: 0, width: max(0, editorScroll.contentSize.width - 96), height: max(1000, editorScroll.contentSize.height))
        editor.textContainer?.containerSize = NSSize(width: max(0, editorScroll.contentSize.width - 96), height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        for canvas in canvasViews.values {
            canvas.frame = NSRect(x: detailX, y: detailTop, width: detailWidth, height: max(0, bounds.height - detailTop - 8))
        }
        // Drawing editors sit above the editor scroll so they show when a
        // drawing note is selected and hide otherwise; the title band stays
        // above the paper so the title never overlaps ink.
        let drawBodyTop = bodyTop
        let drawBodyHeight = bodyHeight
        for view in drawingViews.values {
            view.frame = NSRect(x: detailX, y: drawBodyTop, width: detailWidth, height: drawBodyHeight)
        }
        layoutToolbar()
        layoutHUD()
    }

    private func configureToolbar() {
        toolbarGlass.contentView = toolbarContent

        // Left group: sidebar, new folder, folder header, more
        leftToolbarButtons = [
            addGlassToolbarButton("sidebar.left", help: "Show or hide folders", action: #selector(toggleSidebar)),
            addGlassToolbarButton("folder.badge.plus", help: "New Folder", action: #selector(newFolder))
        ]
        folderHeader.font = .systemFont(ofSize: 15, weight: .semibold)
        toolbarContent.addSubview(folderHeader)
        leftToolbarButtons.append(addGlassToolbarButton("ellipsis", help: "More folder actions", action: #selector(openFolderActions)))
        newNoteButton = addGlassToolbarButton("square.and.pencil", help: "New Note", action: #selector(newNote))
        let newDrawingButton = addGlassToolbarButton("scribble", help: "New Drawing", action: #selector(newDrawing))
        leftToolbarButtons.append(newDrawingButton)

        let flexible = NSView()
        toolbarContent.addSubview(flexible)

        // Center group: formatting
        formattingToolbarButtons = [
            addGlassToolbarButton("textformat", help: "Text formatting", action: #selector(formatMenu)),
            addGlassToolbarButton("checklist", help: "Insert checklist item", action: #selector(insertChecklist)),
            addGlassToolbarButton("tablecells", help: "Insert table", action: #selector(insertTable)),
            addGlassToolbarButton("paperclip", help: "Attach a file", action: #selector(attachFile)),
            addGlassToolbarButton("arrow.down.doc", help: "Import Apple Notes", action: #selector(importAppleNotes))
        ]
        // Sketch toggle for ordinary text notes; hidden unless one is selected.
        let sketch = addGlassToolbarButton("pencil.tip.crop.circle", help: "Sketch on this note", action: #selector(toggleSketch))
        sketchButton = sketch
        formattingToolbarButtons.append(sketch)
        setSketchControlVisible(false)

        // Canvas controls
        canvasControlButtons = [
            addGlassToolbarButton("plus.square", help: "Add card to canvas", action: #selector(addCanvasCard)),
            addGlassToolbarButton("point.3.connected.trianglepath.dotted", help: "Connect the two newest cards", action: #selector(connectCanvasCards)),
            addGlassToolbarButton("minus.magnifyingglass", help: "Zoom out", action: #selector(zoomCanvasOut)),
            addGlassToolbarButton("plus.magnifyingglass", help: "Zoom in", action: #selector(zoomCanvasIn))
        ]
        canvasControlSurfaces = canvasControlButtons.compactMap(toolbarSurface(for:))

        // Right group: share, delete, settings
        rightToolbarButtons = [
            addGlassToolbarButton("square.and.arrow.up", help: "Share note", action: #selector(shareNote)),
            addGlassToolbarButton("trash", help: "Delete note", action: #selector(deleteSelectedNote)),
            addGlassToolbarButton("menubar.rectangle", help: "Show or hide toolbar", action: #selector(toggleToolbar)),
            addGlassToolbarButton("gearshape", help: "Settings", action: #selector(showSettings))
        ]

        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        toolbarContent.addSubview(searchField)

        // Always-available restore control for a hidden toolbar.
        toolbarReveal.isInteractive = true
        toolbarReveal.style = .clear
        toolbarRevealButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show toolbar")
        toolbarRevealButton.bezelStyle = .circular
        toolbarRevealButton.isBordered = false
        toolbarRevealButton.imageScaling = .scaleProportionallyDown
        toolbarRevealButton.contentTintColor = .labelColor
        toolbarRevealButton.toolTip = "Show toolbar (⌥⌘T)"
        toolbarRevealButton.target = self
        toolbarRevealButton.action = #selector(toggleToolbar)
        toolbarRevealButton.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        toolbarReveal.contentView = toolbarRevealButton
        toolbarReveal.isHidden = true
        addSubview(toolbarReveal)
    }

    @discardableResult
    private func addGlassToolbarButton(_ symbol: String, help: String, action: Selector) -> NSButton {
        // Create a glass surface for the button
        let glass = GlassSurfaceView.control(cornerRadius: 12)
        glass.isInteractive = true
        glass.style = .clear
        toolbarContent.addSubview(glass)

        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .circular
        button.isBordered = false
        button.cell?.backgroundStyle = .raised
        button.toolTip = help
        button.contentTintColor = .labelColor
        button.imageScaling = .scaleProportionallyDown
        glass.contentView = button
        toolbarButtonSurfaces[ObjectIdentifier(button)] = glass

        // Set fixed size for glass and button - layoutToolbar will position them.
        // The button fills the whole glass so the entire circle is clickable.
        glass.frame = NSRect(x: 0, y: 0, width: 40, height: 40)
        button.frame = NSRect(x: 0, y: 0, width: 40, height: 40)

        return button
    }

    /// Lays out inside the glass bar's own bounds using Auto Layout for glass buttons.
    private func layoutToolbar() {
        let bar = toolbarGlass.frame
        // One deterministic left-to-right pass. The old version anchored the
        // center group, the right group and the canvas controls all from the
        // right edge, so the canvas controls landed exactly on top of
        // Share / Trash / Menu / Gear.
        let side: CGFloat = 40
        let gap: CGFloat = 6
        let buttonY = (bar.height - side) / 2

        let leftGlass = leftToolbarButtons.compactMap(toolbarSurface(for:))
        let newNoteGlass = toolbarSurface(for: newNoteButton)
        let canvasGlass = canvasControlSurfaces.filter { !$0.isHidden }
        let centerGlass = formattingToolbarButtons.compactMap(toolbarSurface(for:)).filter { !$0.isHidden }
        let rightGlass = rightToolbarButtons.compactMap(toolbarSurface(for:))

        let searchWidth: CGFloat = min(280, max(180, bounds.width * 0.18))
        searchField.frame = NSRect(x: bar.width - searchWidth - 14, y: (bar.height - 36) / 2,
                                   width: searchWidth, height: 36)

        // Right edge -> left: search, actions, canvas controls, formatting,
        // then New Note. Keep every note action in one right-aligned cluster.
        var x = searchField.frame.minX - gap
        for glass in rightGlass.reversed() {
            x -= side
            glass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }
        for glass in canvasGlass.reversed() {
            x -= side
            glass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }
        for glass in centerGlass.reversed() {
            x -= side
            glass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }
        if let newNoteGlass {
            x -= side
            newNoteGlass.frame = NSRect(x: x, y: buttonY, width: side, height: side)
            x -= gap
        }

        // Left edge -> right: sidebar, new folder, ellipsis, folder header.
        var lx: CGFloat = 18 - bar.minX
        for glass in leftGlass {
            glass.frame = NSRect(x: lx, y: buttonY, width: side, height: side)
            lx += side + gap
        }
        folderHeader.frame = NSRect(x: lx + 2, y: (bar.height - 24) / 2, width: 150, height: 24)

        let flexible = toolbarContent.subviews.first(where: { !($0 is GlassSurfaceView) && $0 !== folderHeader && $0 !== searchField })
        if let flexible {
            let leftContentEnd = folderHeader.frame.maxX
            let rightControlsStart = x + gap
            flexible.frame = NSRect(x: leftContentEnd + 8, y: 0,
                                    width: max(8, rightControlsStart - leftContentEnd - 16), height: 1)
        }
    }

    private func toolbarSurface(for button: NSButton) -> GlassSurfaceView? {
        toolbarButtonSurfaces[ObjectIdentifier(button)]
    }

    private func configureSidebar() {
        folderScroll.drawsBackground = false
        folderScroll.hasVerticalScroller = true
        folderScroll.autoresizingMask = [.width, .height]
        folderScroll.documentView = folderStack
        sidebarGlass.contentView = folderScroll
        folderHeader.stringValue = folderDisplayName(selectedFolder)
    }

    private func configureNotesList() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        column.title = "Notes"
        column.width = listColumnWidth
        notesTable.addTableColumn(column)
        notesTable.headerView = nil
        notesTable.rowHeight = 72
        notesTable.dataSource = self
        notesTable.delegate = self
        notesTable.selectionHighlightStyle = .none
        notesTable.backgroundColor = .clear
        notesTable.gridColor = NSColor.clear
        notesTable.usesAlternatingRowBackgroundColors = false
        notesTable.intercellSpacing = NSSize(width: 0, height: 0)
        notesScroll.documentView = notesTable
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.backgroundColor = .clear
        notesScroll.autoresizingMask = [.width, .height]
        listCard.contentView = notesScroll
        listCard.style = .clear
    }

    private func configureEditor() {
        titleField.font = .systemFont(ofSize: 26, weight: .bold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.placeholderString = "Title"
        editor.isRichText = true
        editor.allowsUndo = true
        editor.font = .systemFont(ofSize: 15)
        editor.textColor = .labelColor
        editor.textContainerInset = NSSize(width: 48, height: 8)
        editor.delegate = self
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = false
        pageCard.cornerRadius = 14
        pageCard.fillColor = .textBackgroundColor
        pageCard.borderColor = .separatorColor
    }

    /// Floating glass control over the canvas: zoom out, percentage, zoom in.
    private func configureCanvasHUD() {
        zoomHUDContent.autoresizingMask = [.width, .height]
        zoomLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        zoomLabel.textColor = .labelColor
        zoomLabel.alignment = .center
        zoomLabel.isBordered = false
        zoomLabel.drawsBackground = false
        zoomOutButton = NSButton(image: NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out") ?? NSImage(),
                                 target: self, action: #selector(zoomCanvasOut))
        zoomOutButton.bezelStyle = .circular
        zoomOutButton.isBordered = true
        zoomOutButton.contentTintColor = .labelColor
        zoomInButton = NSButton(image: NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in") ?? NSImage(),
                                target: self, action: #selector(zoomCanvasIn))
        zoomInButton.bezelStyle = .circular
        zoomInButton.isBordered = true
        zoomInButton.contentTintColor = .labelColor
        [zoomOutButton, zoomLabel, zoomInButton].forEach(zoomHUDContent.addSubview)
        zoomHUD.contentView = zoomHUDContent
        zoomHUD.isHidden = true
    }

    private func layoutHUD() {
        let hudWidth: CGFloat = 200
        let hudHeight: CGFloat = 48
        // Position relative to canvas area (detailFrame), not window bounds
        let canvasFrame = detailFrame
        zoomHUD.frame = NSRect(x: canvasFrame.maxX - hudWidth - 12, 
                                y: canvasFrame.maxY - hudHeight - 12, 
                                width: hudWidth, height: hudHeight)
        zoomHUDContent.frame = zoomHUD.bounds
        let side: CGFloat = 42
        zoomOutButton.frame = NSRect(x: 4, y: 3, width: side, height: side)
        zoomInButton.frame = NSRect(x: zoomHUD.bounds.width - side - 4, y: 3, width: side, height: side)
        zoomLabel.frame = NSRect(x: side + 4, y: 3, width: zoomHUD.bounds.width - side * 2 - 8, height: side)
    }

    /// Pseudo folders that are not stored in `folders` and cannot be renamed,
    /// deleted, or used as a subfolder parent.
    private static let reservedFolders: Set<String> = ["Notes", "Quick Notes", "All iCloud", "Canvas", "Drawings"]

    /// Sidebar/toolbar label for a folder path: the last component, not the
    /// whole "LUOA/Science" path.
    private func folderDisplayName(_ path: String) -> String {
        guard let last = path.components(separatedBy: "/").last, !last.isEmpty else { return path }
        return last
    }

    /// True for a folder the user owns: a stored folder that isn't a pseudo row.
    private func isUserFolder(_ path: String) -> Bool {
        !Self.reservedFolders.contains(path) && folders.contains(path)
    }

    /// True when notes can live directly in this selection ("Notes" included).
    private func canHoldNotes(_ path: String) -> Bool {
        !["Quick Notes", "All iCloud", "Canvas", "Drawings"].contains(path)
    }

    private func folderIsSelectedOrNested(_ folder: String, in path: String) -> Bool {
        folder == path || folder.hasPrefix(path + "/")
    }

    private func rebuildFolderRows() {
        for row in folderRows {
            row.removeFromSuperview()
        }
        folderRows.removeAll()
        addFolderRow("Quick Notes", symbol: "bolt.fill", count: nil, folder: "Quick Notes")
        addFolderRow("All iCloud", symbol: "folder", count: nil, folder: "All iCloud")
        addFolderRow("Notes", symbol: "folder", count: nil, folder: "Notes")

        // Full paths, so ancestors sort ahead of their children and a child
        // whose parent is missing still shows up (indented, not hidden).
        let otherFolders = folders
            .filter { !Self.reservedFolders.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for folder in otherFolders {
            let depth = min(4, max(0, folder.components(separatedBy: "/").count - 1))
            addFolderRow(folderDisplayName(folder), symbol: "folder", count: nil, folder: folder, indent: CGFloat(depth) * 12)
        }
        addFolderRow("Canvas", symbol: "scribble.variable", count: nil, folder: "Canvas")
        addFolderRow("Drawings", symbol: "scribble", count: nil, folder: "Drawings")
        layoutFolderRows()
    }

    /// Positions every folder row from the sidebar's current width. Frame-based
    /// on purpose: Auto Layout here fought `NSGlassEffectView`'s internal
    /// content constraints and flooded the console.
    private func layoutFolderRows() {
        let width = max(0, folderStack.bounds.width - 20)
        var y: CGFloat = 10
        for row in folderRows {
            row.frame = NSRect(x: 10, y: y, width: width, height: 36)
            y += 40
        }
    }

    private func addFolderRow(_ title: String, symbol: String, count: Int?, folder: String, indent: CGFloat = 0) {
        let isSelected = folder == selectedFolder
        let effectiveTheme = theme

        // Create glass surface for the folder row
        let glass = GlassSurfaceView.control(cornerRadius: 12)
        glass.style = .clear
        glass.tintColor = isSelected ? effectiveTheme.selectionHighlight : nil
        glass.frame = NSRect(x: 10, y: CGFloat(folderRows.count) * 40 + 10, width: 212, height: 36)
        folderStack.addSubview(glass)
        folderRows.append(glass)

        let button = NSButton(title: title, target: self, action: #selector(folderSelected(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(folder)
        button.isBordered = false
        button.alignment = .left
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.contentTintColor = isSelected ? effectiveTheme.accentColor : effectiveTheme.textPrimary
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: isSelected ? effectiveTheme.accentColor : effectiveTheme.textPrimary,
                .font: NSFont.systemFont(ofSize: 13, weight: isSelected ? .semibold : .regular)
            ]
        )
        // The content view insets the button by frame; no constraints.
        let row = FolderRowContentView(button: button, leadingInset: 12 + indent)
        glass.contentView = row
    }

    @objc private func folderSelected(_ sender: NSButton) {
        guard let folder = sender.identifier?.rawValue else { return }
        selectedFolder = folder
        folderHeader.stringValue = folderDisplayName(folder)
        rebuildFolderRows()
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) } else { showEmptyEditor() }
    }


    @objc private func newFolder() {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Choose a name for this folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "Folder name"
        alert.accessoryView = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !Self.reservedFolders.contains(name),
              !folders.contains(name) else { return }
        folders.append(name)
        selectedFolder = name
        folderHeader.stringValue = folderDisplayName(name)
        rebuildFolderRows()
        notesTable.reloadData()
        showEmptyEditor()
    }

    /// Creates `selectedFolder/Name` inside the folder currently selected.
    @objc private func newSubfolder() {
        let parent = selectedFolder
        guard canHoldNotes(parent) else { return }
        promptForFolderName(initial: "", title: "New Subfolder") { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            guard !name.contains("/") else { NSSound.beep(); return }
            let path = "\(parent)/\(name)"
            guard !self.folders.contains(path) else { NSSound.beep(); return }
            self.folders.append(path)
            self.selectedFolder = path
            self.folderHeader.stringValue = self.folderDisplayName(path)
            self.rebuildFolderRows()
            self.notesTable.reloadData()
            self.showEmptyEditor()
        }
    }

    @objc private func openFolderActions() {
        let menu = NSMenu()
        // Explicit enablement below, so AppKit does not re-enable items with a
        // valid target/action when the menu opens.
        menu.autoenablesItems = false
        let subfolder = NSMenuItem(title: "New Subfolder…", action: #selector(newSubfolder), keyEquivalent: "")
        subfolder.target = self
        subfolder.isEnabled = canHoldNotes(selectedFolder)
        menu.addItem(subfolder)
        let rename = NSMenuItem(title: "Rename Folder…", action: #selector(renameSelectedFolder), keyEquivalent: "")
        rename.target = self
        rename.isEnabled = folders.contains(selectedFolder)
        menu.addItem(rename)
        let remove = NSMenuItem(title: "Delete Folder", action: #selector(deleteSelectedFolder), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = isUserFolder(selectedFolder)
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: toolbarContent)
    }

    @objc private func renameSelectedFolder() {
        let old = selectedFolder
        guard folders.contains(old) else { return }
        let parent = old.components(separatedBy: "/").dropLast().joined(separator: "/")
        promptForFolderName(initial: folderDisplayName(old)) { [weak self] name in
            guard let self, let name, !name.isEmpty else { return }
            guard !name.contains("/") else { NSSound.beep(); return }
            let new = parent.isEmpty ? name : "\(parent)/\(name)"
            guard new != old else { return }
            // A root folder named like a sidebar pseudo row would be shadowed
            // by it, so it is rejected up front.
            guard !(parent.isEmpty && Self.reservedFolders.contains(new)) else { NSSound.beep(); return }
            // Reject a name already taken by another folder, including one of
            // its descendants; a folder being renamed out of the way is fine.
            let collides = self.folders.contains { candidate in
                guard self.folderIsSelectedOrNested(candidate, in: new) else { return false }
                return !self.folderIsSelectedOrNested(candidate, in: old)
            }
            guard !collides else { NSSound.beep(); return }

            self.folders = self.folders.map { folder in
                if folder == old { return new }
                if folder.hasPrefix(old + "/") { return new + String(folder.dropFirst(old.count)) }
                return folder
            }
            self.notes = self.notes.map { note in
                var copy = note
                if note.folder == old {
                    copy.folder = new
                } else if note.folder.hasPrefix(old + "/") {
                    copy.folder = new + String(note.folder.dropFirst(old.count))
                }
                return copy
            }
            self.selectedFolder = new
            self.folderHeader.stringValue = self.folderDisplayName(new)
            self.rebuildFolderRows()
            self.notesTable.reloadData()
            self.reselectVisibleNote()
        }
    }

    @objc private func deleteSelectedFolder() {
        let removed = selectedFolder
        guard isUserFolder(removed) else { return }
        folders.removeAll { folderIsSelectedOrNested($0, in: removed) }
        notes = notes.map { note in
            var copy = note
            if folderIsSelectedOrNested(note.folder, in: removed) { copy.folder = "Notes" }
            return copy
        }
        selectedFolder = "Notes"
        folderHeader.stringValue = folderDisplayName(selectedFolder)
        rebuildFolderRows()
        notesTable.reloadData()
        reselectVisibleNote()
    }

    /// Keeps the current note selected when it is still visible, otherwise
    /// falls back to the first visible note or an empty editor.
    private func reselectVisibleNote() {
        let visible = visibleNotes
        if let selectedNoteID, visible.contains(where: { $0.id == selectedNoteID }) {
            selectNote(selectedNoteID)
        } else if let first = visible.first {
            selectNote(first.id)
        } else {
            showEmptyEditor()
        }
    }

    private func promptForFolderName(initial: String, title: String = "Rename Folder",
                                     completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        field.placeholderString = "Folder name"
        alert.accessoryView = field
        completion(alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
    }

    @objc func newNote() {
        let menu = NSMenu()
        let normal = NSMenuItem(title: "New Note", action: #selector(createNormalNote), keyEquivalent: "")
        normal.target = self
        menu.addItem(normal)
        let canvas = NSMenuItem(title: "New Canvas Note", action: #selector(createCanvasNote), keyEquivalent: "")
        canvas.target = self
        menu.addItem(canvas)
        let point = NSPoint(x: newNoteButton.frame.midX, y: newNoteButton.frame.minY)
        menu.popUp(positioning: nil, at: point, in: toolbarContent)
    }

    @objc private func createNormalNote() { createNote() }

    func createNote() {
        if ["All iCloud", "Canvas", "Drawings"].contains(selectedFolder) { selectedFolder = "Notes"; folderHeader.stringValue = folderDisplayName(selectedFolder) }
        let note = WorkspaceNote(title: "New Note", body: "", folder: selectedFolder)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
        window?.makeFirstResponder(editor)
    }

    @objc private func createCanvasNote() {
        if ["All iCloud", "Canvas", "Drawings"].contains(selectedFolder) {
            selectedFolder = "Notes"
            folderHeader.stringValue = folderDisplayName(selectedFolder)
            rebuildFolderRows()
        }
        let note = WorkspaceNote(title: "New Canvas", body: "", folder: selectedFolder, isCanvas: true)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
    }

    @objc func newDrawing() {
        if ["All iCloud", "Canvas", "Drawings"].contains(selectedFolder) {
            selectedFolder = "Notes"
            folderHeader.stringValue = folderDisplayName(selectedFolder)
            rebuildFolderRows()
        }
        let note = WorkspaceNote(title: "New Drawing", body: "", folder: selectedFolder, isDrawing: true)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
        if let dv = drawingViews[note.id] { dv.focusCanvas() }
    }

    // MARK: - Screenshot hooks

    /// Selects the first drawing note so the ink surface can be captured.
    func openFirstDrawingForTesting() {
        NSLog("Notesy hook: drawings=%d", notes.filter { $0.isDrawing }.count)
        guard let note = notes.first(where: { $0.isDrawing }) else { return }
        revealForTesting(note)
    }

    /// Selects the first text note and opens its inline sketch.
    func openSketchForTesting() {
        guard let note = notes.first(where: { !$0.isCanvas && !$0.isDrawing }) else { return }
        sketchNoteID = note.id
        revealForTesting(note)
    }

    private func revealForTesting(_ note: WorkspaceNote) {
        NSLog("Notesy hook: revealing %@ (drawing=%d, folder=%@, notes=%d)", note.title, note.isDrawing ? 1 : 0, note.folder, notes.count)
        selectedFolder = note.folder
        folderHeader.stringValue = folderDisplayName(selectedFolder)
        rebuildFolderRows()
        notesTable.reloadData()
        selectNote(note.id)
    }

    /// Imports handwriting drawings from Apple Notes alongside any plain-text notes.
    @objc func importDrawings() {
        guard !isImportingNotes else { return }
        isImportingNotes = true
        showImportProgress()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var textNotes: [ImportedNote] = []
            var drawError: Error?
            do {
                textNotes = try AppleNotesImporter.importAll()
            } catch let e as AppleNotesImporterError {
                drawError = e
            } catch {
                drawError = error
            }
            var drawings: [AppleNotesDrawings.ImportedDrawing] = []
            if AppleNotesDrawings.isStoreReadable {
                do {
                    drawings = try AppleNotesDrawings.importAll()
                } catch {
                    if drawError == nil { drawError = error }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isImportingNotes = false
                self.hideImportProgress { [weak self] in
                    guard let self else { return }
                    self.flushAllPendingDrawings()
                    self.mergeImportedNotes(textNotes)
                    if let err = drawError {
                        self.presentDrawingImportError(err)
                        return
                    }
                    if drawings.isEmpty {
                        self.presentDrawingImportResult(drawingsCount: 0, skipped: 0)
                        return
                    }
                    self.importDrawingDrafts(drawings)
                }
            }
        }
    }

    private func flushAllPendingDrawings() {
        if let id = pendingDrawingSave {
            saveDrawing(id: id)
            pendingDrawingSave = nil
            drawingSaveWorkItem = nil
        }
    }

    private func importDrawingDrafts(_ drawings: [AppleNotesDrawings.ImportedDrawing]) {
        var titles: [String: String] = [:]
        var folders: [String: [String]] = [:]
        for d in drawings {
            let t = d.noteTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { titles[d.noteID] = t }
            if !d.noteFolderPath.isEmpty { folders[d.noteID] = d.noteFolderPath }
        }
        var alreadyImported = Set(notes.compactMap { $0.sourceID })
        let existingDrawingIds = Set(notes.compactMap { $0.sourceID }.filter { $0.hasPrefix("apple-") })
        alreadyImported.formUnion(existingDrawingIds)

        do {
            let drafts = try DrawingNoteImport.makeDrafts(
                drawings: drawings,
                titles: titles,
                folders: folders,
                alreadyImported: alreadyImported
            )
            isBatchingSave = true
            var addedCount = 0
            var skippedCount = 0
            for draft in drafts {
                let path = draft.folderPath.joined(separator: "/")
                if draft.folderPath.count > 1 {
                    var prefix: [String] = []
                    for comp in draft.folderPath {
                        prefix.append(comp)
                        let p = prefix.joined(separator: "/")
                        if folders[p] == nil { folders[p] = [] }
                    }
                }
                let noteId = "apple-\(draft.sourceID)"
                if notes.first(where: { $0.sourceID == noteId }) != nil {
                    skippedCount += 1
                    continue
                }
                let note = WorkspaceNote(
                    title: draft.title,
                    body: "",
                    folder: path,
                    isDrawing: true,
                    sourceID: noteId,
                    drawingFile: draft.imageFile
                )
                notes.append(note)
                addedCount += 1
            }
            isBatchingSave = false
            save()
            rebuildFolderRows()
            notesTable.reloadData()
            presentDrawingImportResult(drawingsCount: addedCount, skipped: skippedCount)
        } catch {
            presentDrawingImportError(error)
        }
    }

    private func presentDrawingImportResult(drawingsCount: Int, skipped: Int) {
        var text = "Imported \(drawingsCount) drawing"
        if drawingsCount != 1 { text += "s" }
        if drawingsCount > 0 { text += "." }
        if skipped > 0 { text += " Skipped \(skipped) that were already imported." }
        let alert = NSAlert()
        alert.messageText = "Import Complete"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        presentImportAlert(alert)
    }

    private func presentDrawingImportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        presentImportAlert(alert)
    }

    /// Single-drag-and-drop or menu-driven import of drawing image files.
    @objc func importDrawingFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp]
        let ok = panel.runModal() == .OK
        guard ok, let rawUrls = (panel as AnyObject).value(forKey: "urls") as? [URL], !rawUrls.isEmpty else { return }
        let urls = rawUrls
        var created: [WorkspaceNote] = []
        var failed: [URL] = []
        for url in urls {
            guard let img = NSImage(contentsOf: url) else {
                failed.append(url)
                continue
            }
            let name = "import-\(UUID().uuidString.lowercased()).png"
            guard let storedName = try? DrawingMedia.storePNG(image: img, name: name) else {
                failed.append(url)
                continue
            }
            let folderPath = (["All iCloud", "Canvas", "Drawings"].contains(selectedFolder)) ? "Notes" : selectedFolder
            let note = WorkspaceNote(title: url.deletingPathExtension().lastPathComponent,
                                     body: "", folder: folderPath,
                                     isDrawing: true, drawingFile: storedName)
            notes.append(note)
            created.append(note)
        }
        if !failed.isEmpty {
            let names = failed.map { $0.lastPathComponent }.joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Some files could not be imported"
            alert.informativeText = "The following files were not recognized as images: \(names)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        if !created.isEmpty {
            notesTable.reloadData()
            selectNote(created[0].id)
        }
    }

    @objc private func searchChanged() {
        query = searchField.stringValue
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) } else { showEmptyEditor() }
    }

    @objc private func insertChecklist() { insertAtCursor("☐ ") }
    @objc private func insertTable() { insertAtCursor("\nColumn 1\tColumn 2\n────────\t────────\n") }

    @objc private func formatMenu() {
        let menu = NSMenu()
        for (title, size, weight) in [("Title", CGFloat(24), NSFont.Weight.bold), ("Heading", CGFloat(18), .semibold), ("Body", CGFloat(15), .regular), ("Monospaced", CGFloat(14), .regular)] {
            let item = NSMenuItem(title: title, action: #selector(applyFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["size": size, "weight": weight.rawValue] as [String: Any]
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: toolbarContent)
    }

    @objc private func applyFormat(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any], let size = values["size"] as? CGFloat,
              let weightValue = values["weight"] as? CGFloat else { return }
        let weight = NSFont.Weight(rawValue: weightValue)
        let font = sender.title == "Monospaced" ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let range = editor.selectedRange()
        let text = editor.string as NSString
        let target = range.length == 0 ? NSRange(location: 0, length: text.length) : range
        editor.textStorage?.addAttribute(.font, value: font, range: target)
        textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
    }

    // MARK: - Apple Notes import

    /// Single entry point for one-click import: the toolbar button and the
    /// Settings panel both call this with no arguments.
    @objc func importAppleNotes() {
        guard !isImportingNotes else { return }
        isImportingNotes = true
        showImportProgress()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let imported = try AppleNotesImporter.importAll()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImportingNotes = false
                    self.hideImportProgress { [weak self] in
                        self?.mergeImportedNotes(imported)
                    }
                }
            } catch let error as AppleNotesImporterError {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImportingNotes = false
                    self.hideImportProgress { [weak self] in
                        self?.presentImportError(error)
                    }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isImportingNotes = false
                    self.hideImportProgress { [weak self] in
                        self?.presentImportError(.failed(message))
                    }
                }
            }
        }
    }

    private func showImportProgress() {
        // A sheet without a window is impossible; import anyway, silently.
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Importing Apple Notes…"
        alert.informativeText = "Reading your notes and folders. This can take a few seconds."
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        alert.accessoryView = spinner
        alert.addButton(withTitle: "Importing…").isEnabled = false
        importProgressAlert = alert
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Ends the progress sheet, then runs `completion` only once the sheet is
    /// actually detached from the window.
    ///
    /// `endSheet` is not synchronous with `attachedSheet`: the window keeps
    /// pointing at the progress sheet for the whole dismissal animation. A
    /// result alert presented during that window would find the window busy and
    /// fall back to a free-floating modal window, so hide-then-present has to be
    /// sequenced through this completion.
    private func hideImportProgress(completion: (() -> Void)? = nil) {
        guard let alert = importProgressAlert, let window, alert.window.sheetParent === window else {
            // No sheet was ever shown (no window, or a sheet was already up).
            importProgressAlert = nil
            completion?()
            return
        }
        importProgressAlert = nil
        let progressWindow = alert.window
        window.endSheet(progressWindow, returnCode: .OK)
        // `importProgressAlert` is cleared above so a second import cannot
        // short-circuit through the guard; the completion must still wait for
        // THIS sheet to actually detach, otherwise the result sheet is
        // presented while the window is still busy and falls back to a
        // separate blocking modal.
        waitForImportSheetToClose(progressWindow, attempts: 20, completion: completion)
    }

    /// Polls until the ended sheet is gone (first check after 0.3s, then every
    /// 0.1s, up to ~2s) so the next sheet is only attached once this one has
    /// finished dismissing.
    private func waitForImportSheetToClose(_ progressWindow: NSWindow, attempts: Int,
                                           completion: (() -> Void)?) {
        guard attempts > 0 else {
            completion?()
            return
        }
        let delay: TimeInterval = attempts == 20 ? 0.3 : 0.1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if self.window?.attachedSheet === progressWindow {
                self.waitForImportSheetToClose(progressWindow, attempts: attempts - 1, completion: completion)
            } else {
                completion?()
            }
        }
    }

    /// Merges the importer's result into the store. `notes` / `folders` are
    /// built in local copies, assigned under the batching guard, then written
    /// to disk by one explicit `save()`.
    private func mergeImportedNotes(_ imported: [ImportedNote]) {
        var folderSet = Set(folders)
        var newFolders = folders
        var newNotes = notes
        var knownSourceIDs = Set(notes.compactMap(\.sourceID))
        var importedCount = 0
        var updatedCount = 0
        var skippedCount = 0
        var touchedFolders = Set<String>()

        for note in imported {
            // A note at the root of Apple Notes has no folder path.
            let components = note.folderPath.isEmpty ? ["Notes"] : note.folderPath
            var prefix: [String] = []
            for component in components {
                prefix.append(component)
                let path = prefix.joined(separator: "/")
                if folderSet.insert(path).inserted { newFolders.append(path) }
            }
            let folderPath = components.joined(separator: "/")
            touchedFolders.insert(folderPath)

            if let index = newNotes.firstIndex(where: { $0.sourceID == note.identifier }) {
                // Earlier imports stored Apple Notes' plaintext title line in
                // the body. Remove that exact repeated line on re-import while
                // preserving all other local edits and note metadata.
                if let cleanedBody = AppleNotesImporter.removeRepeatedTitle(
                    from: newNotes[index].body, title: newNotes[index].title
                ) {
                    newNotes[index].body = cleanedBody
                    updatedCount += 1
                } else {
                    skippedCount += 1
                }
                continue
            }
            // A note already in the store by hand (pre-import copy): adopt it
            // instead of storing a duplicate.
            if let index = newNotes.firstIndex(where: {
                $0.sourceID == nil && $0.folder == folderPath && $0.title == note.title && $0.body == note.body
            }) {
                newNotes[index].sourceID = note.identifier
                knownSourceIDs.insert(note.identifier)
                updatedCount += 1
                continue
            }
            newNotes.append(WorkspaceNote(title: note.title, body: note.body, folder: folderPath,
                                          isCanvas: false, sourceID: note.identifier))
            knownSourceIDs.insert(note.identifier)
            importedCount += 1
        }

        isBatchingSave = true
        notes = newNotes
        folders = newFolders
        isBatchingSave = false
        save()

        rebuildFolderRows()
        notesTable.reloadData()
        reselectVisibleNote()

        let summary = AppleNotesImportSummary(imported: importedCount, updated: updatedCount,
                                              skipped: skippedCount, folders: touchedFolders.count)
        // Already called from `hideImportProgress`'s completion: the progress
        // sheet is gone, so this attaches as a sheet on the main window.
        presentImportResult(summary)
    }

    private func presentImportResult(_ summary: AppleNotesImportSummary) {
        print("[import] result: imported=\(summary.imported) updated=\(summary.updated) skipped=\(summary.skipped) folders=\(summary.folders) window=\(window != nil) attachedSheet=\(window?.attachedSheet != nil)")
        let alert = NSAlert()
        alert.messageText = "Import Complete"
        if summary.imported == 0 && summary.updated == 0 && summary.skipped > 0 {
            alert.informativeText = "All \(summary.skipped) notes are already imported. Nothing was changed."
        } else {
            var text = "Imported \(summary.imported) notes into \(summary.folders) folders."
            if summary.skipped > 0 { text += " Skipped \(summary.skipped) notes that were already imported." }
            if summary.updated > 0 { text += " Updated \(summary.updated) existing matches." }
            alert.informativeText = text
        }
        alert.addButton(withTitle: "OK")
        presentImportAlert(alert)
    }

    private func presentImportError(_ error: AppleNotesImporterError) {
        print("[import] error: \(error.localizedDescription)")
        let alert = NSAlert()
        switch error {
        case .notAuthorized:
            alert.alertStyle = .warning
            alert.messageText = "Notesy can’t access Apple Notes"
            alert.informativeText = "Allow Notesy to control the Notes app, then try importing again: System Settings › Privacy & Security › Automation."
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            presentImportAlert(alert) { response in
                guard response == .alertFirstButtonReturn,
                      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
                NSWorkspace.shared.open(url)
            }
        case .noNotes, .notesUnavailable, .failed:
            alert.messageText = "Import Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            presentImportAlert(alert)
        }
    }

    private func presentImportAlert(_ alert: NSAlert, completion: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else if let window {
            // A sheet is still attached (the progress sheet animating away).
            // Retry as a sheet once it clears instead of spawning a separate
            // blocking modal window that lands behind other apps.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.presentImportAlert(alert, completion: completion)
            }
        } else {
            let response = alert.runModal()
            completion?(response)
        }
    }

    private func insertAtCursor(_ string: String) {
        if selectedNoteID == nil { newNote() }
        editor.insertText(string, replacementRange: editor.selectedRange())
        window?.makeFirstResponder(editor)
    }

    @objc private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .plainText, .rtf, .rtfd, .html, .jpeg, .png, .tiff, .gif, .bmp]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        guard let note = selectedNote else { return }
        
        if note.isCanvas {
            // For canvas: create a card with the image/file
            guard let canvas = canvasViews[note.id]?.canvasView else { return }
            let visible = canvas.visibleRect
            let box = canvas.addBox(frame: NSRect(x: visible.midX - 140, y: visible.midY - 95, width: 280, height: 190), title: url.deletingPathExtension().lastPathComponent)
            if let image = NSImage(contentsOf: url) {
                box.displayImage(image, sourceURL: url)
            }
            box.noteBody = "Attachment: \(url.lastPathComponent)"
        } else {
            // For text notes: add to attachments array and insert reference
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                let mimeType = mimeTypeForURL(url)
                let attachment = Attachment(fileName: url.lastPathComponent, fileURL: url, mimeType: mimeType)
                notes[index].attachments.append(attachment)
                insertAtCursor("\n[Attachment: \(url.lastPathComponent)]\n")
            }
        }
    }
    
    private func mimeTypeForURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        case "pdf": return "application/pdf"
        case "txt": return "text/plain"
        case "rtf": return "application/rtf"
        case "html", "htm": return "text/html"
        default: return "application/octet-stream"
        }
    }

    @objc private func shareNote() {
        guard let note = selectedNote else { return }
        let picker = NSSharingServicePicker(items: ["\(note.title)\n\n\(note.body)"])
        picker.show(relativeTo: NSRect(x: bounds.maxX - 100, y: 0, width: 1, height: 1), of: self, preferredEdge: .minY)
    }

    @objc private func deleteSelectedNote() {
        guard let id = selectedNoteID else { return }
        canvasViews.removeValue(forKey: id)?.removeFromSuperview()
        drawingViews.removeValue(forKey: id)?.removeFromSuperview()
        // Clean up drawing media files (drawing notes and text notes that carry
        // an inline sketch both store sidecars).
        if let note = notes.first(where: { $0.id == id }) {
            if let f = note.drawingFile { DrawingMedia.remove(f) }
            if let p = note.drawingPreviewFile { DrawingMedia.remove(p) }
            if let s = note.drawingStrokeFile { DrawingMedia.removeStrokeFile(s) }
        }
        if sketchNoteID == id { sketchNoteID = nil }
        notes.removeAll { $0.id == id }
        self.selectedNoteID = nil
        notesTable.reloadData()
        if let first = visibleNotes.first { selectNote(first.id) } else { showEmptyEditor() }
    }

    @objc private func showSettings() { onOpenSettings?() }

    @objc private func addCanvasCard() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        let visible = canvas.canvasView.visibleRect
        let offset = CGFloat(canvas.canvasView.cards.count % 7) * 28
        _ = canvas.canvasView.addBox(frame: NSRect(x: visible.midX - 140 + offset, y: visible.midY - 95 + offset, width: 280, height: 190), title: "New card")
    }

    @objc private func connectCanvasCards() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }), !canvas.canvasView.connectMostRecentBoxes(type: .directional) else { return }
        NSSound.beep()
    }


    private var selectedNote: WorkspaceNote? { notes.first { $0.id == selectedNoteID } }

    /// Loads the sidecar stroke data for a note, or nil when there is none.
    private func loadingStrokeData(_ note: WorkspaceNote) -> Data? {
        guard let fname = note.drawingStrokeFile else { return nil }
        return DrawingMedia.strokeData(for: fname)
    }

    private func drawingView(for note: WorkspaceNote) -> DrawingEditorView {
        if let existing = drawingViews[note.id] { return existing }
        let view = DrawingEditorView(frame: detailBodyFrame)
        view.configure(theme: theme)
        view.onDrawingChanged = { [weak self] in self?.scheduleDrawingSave(id: note.id) }
        drawingViews[note.id] = view
        view.isHidden = true
        addSubview(view)
        needsLayout = true
        return view
    }

    // MARK: - Sketching on a text note

    private func setSketchControlVisible(_ visible: Bool) {
        sketchButton?.isHidden = !visible
        if let sketchButton { toolbarSurface(for: sketchButton)?.isHidden = !visible }
    }

    private func updateSketchControl(for note: WorkspaceNote?) {
        guard let note, !note.isCanvas, !note.isDrawing else {
            setSketchControlVisible(false)
            return
        }
        setSketchControlVisible(true)
        let sketching = sketchNoteID == note.id
        sketchButton?.image = NSImage(
            systemSymbolName: sketching ? "text.alignleft" : "pencil.tip.crop.circle",
            accessibilityDescription: sketching ? "Back to text" : "Sketch on this note"
        )
        sketchButton?.toolTip = sketching ? "Back to text" : "Draw on this note"
    }

    /// Opens the handwriting surface on an ordinary text note, or returns it to
    /// the text editor. The ink is stored in the same sidecar as a drawing note,
    /// so a note can hold text and a sketch at the same time.
    @objc func toggleSketch() {
        guard let note = selectedNote, !note.isCanvas, !note.isDrawing else { return }
        if sketchNoteID == note.id {
            flushDrawingSave(id: note.id)
            sketchNoteID = nil
        } else {
            sketchNoteID = note.id
        }
        needsLayout = true
        selectNote(note.id)
        notesTable.reloadData()
        layoutToolbar()
    }

    private func canvasView(for note: WorkspaceNote) -> WorkspaceScrollView {
        if let existing = canvasViews[note.id] { return existing }
        let scroll = WorkspaceScrollView(frame: detailFrame)
        // Float the canvas as a rounded sheet on the desk, like the other surfaces.
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 14
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderWidth = 0.5
        scroll.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        scroll.canvasView.restore(blocks: note.canvasBlocks, connections: note.connections)
        if note.canvasBlocks.isEmpty {
            let box = scroll.canvasView.addBox(frame: NSRect(x: 420, y: 320, width: 320, height: 240), title: note.title)
            box.noteBody = note.body
        }
        canvasViews[note.id] = scroll
        scroll.canvasView.onCanvasChanged = { [weak self] in self?.saveCanvas(id: note.id) }
        scroll.frame = detailFrame
        scroll.isHidden = true
        addSubview(scroll)
        return scroll
    }

    private func saveCanvas(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), let canvas = canvasViews[id]?.canvasView else { return }
        notes[index].canvasBlocks = canvas.exportBlocks()
        notes[index].connections = canvas.connections
        notes[index].modified = Date()
        scheduleStoreSave()
    }

    /// Debounced persistence: waits 0.7s after the last ink change before writing.
    private func scheduleDrawingSave(id: UUID) {
        // Cancel any previous pending save for a different note.
        drawingSaveWorkItem?.cancel()
        pendingDrawingSave = id
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingDrawingSave = nil
            self.saveDrawing(id: id)
        }
        drawingSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func saveDrawing(id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              let dv = drawingViews[id] else { return }
        // A drawing that was erased back to empty must stop loading its old ink.
        guard !dv.isEmpty else {
            if let strokeName = notes[index].drawingStrokeFile {
                DrawingMedia.removeStrokeFile(strokeName)
                notes[index].drawingStrokeFile = nil
            }
            if let previewName = notes[index].drawingPreviewFile {
                DrawingMedia.remove(previewName)
                notes[index].drawingPreviewFile = nil
            }
            notes[index].modified = Date()
            scheduleStoreSave()
            return
        }
        // Flush strokes to sidecar.
        if let strokeName = try? DrawingMedia.storeStrokeData(dv.strokeData, noteID: id) {
            notes[index].drawingStrokeFile = strokeName
        }
        // Render a small preview thumbnail for the list.
        if let thumb = dv.thumbnail(size: NSSize(width: 320, height: 240)) {
            if let previewName = try? DrawingMedia.storePNG(image: thumb, name: "preview-\(id)") {
                notes[index].drawingPreviewFile = previewName
            }
        }
        notes[index].modified = Date()
        scheduleStoreSave()
    }

    /// Force-flush a pending debounce so switching away from a drawing does not
    /// lose uncommitted ink.
    private func flushDrawingSave(id: UUID) {
        drawingSaveWorkItem?.cancel()
        drawingSaveWorkItem = nil
        pendingDrawingSave = nil
        saveDrawing(id: id)
    }

    private func selectNote(_ id: UUID) {
        guard !isSelectingNote else { return }
        isSelectingNote = true
        defer { isSelectingNote = false }
        selectedNoteID = id
        if let index = visibleNotes.firstIndex(where: { $0.id == id }) { notesTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        guard let note = selectedNote else { showEmptyEditor(); return }
        isUpdatingEditor = true
        titleField.stringValue = note.title
        editor.string = note.body
        isUpdatingEditor = false
        setCanvasControlsVisible(note.isCanvas)
        updateSketchControl(for: note)
        layoutToolbar()
        if note.isDrawing || sketchNoteID == id {
            let sketching = !note.isDrawing
            let dv = drawingView(for: note)
            // A drawing note is its own sheet; a sketch on a text note has to
            // leave the page showing so ink lands on top of the words.
            dv.showsPaper = !sketching
            dv.configure(theme: theme)
            dv.noteIdentity = id
            dv.load(strokeData: loadingStrokeData(note), imageFile: note.drawingFile)
            loadedDrawingID = id
            for (canvasID, view) in canvasViews { view.isHidden = true }
            pageCard.isHidden = !sketching
            titleField.isHidden = false
            editorScroll.isHidden = !sketching
            zoomHUD.isHidden = true
            zoomHUD.removeFromSuperview()
            for view in drawingViews.values { view.isHidden = view !== dv }
            dv.isHidden = false
            dv.window?.makeFirstResponder(dv.canvas)
        } else if note.isCanvas {
            let selectedCanvas = canvasView(for: note)
            for (canvasID, view) in canvasViews { view.isHidden = canvasID != id }
            pageCard.isHidden = true
            titleField.isHidden = false
            editorScroll.isHidden = true
            selectedCanvas.isHidden = false
            zoomHUD.isHidden = false
            // Canvas scroll views are added after the HUD, so re-raise it above
            // whichever canvas is on screen; otherwise the HUD is painted under it.
            addSubview(zoomHUD, positioned: .above, relativeTo: nil)
            layoutHUD()
        } else {
            for canvas in canvasViews.values { canvas.isHidden = true }
            for view in drawingViews.values { view.isHidden = true }
            pageCard.isHidden = false
            titleField.isHidden = false
            editorScroll.isHidden = false
            zoomHUD.isHidden = true
            zoomHUD.removeFromSuperview()
        }
    }

    private func showEmptyEditor() {
        selectedNoteID = nil
        titleField.stringValue = ""
        editor.string = ""
        pageCard.isHidden = true
        titleField.isHidden = true
        editorScroll.isHidden = true
        zoomHUD.isHidden = true
        setCanvasControlsVisible(false)
        for canvas in canvasViews.values { canvas.isHidden = true }
        for view in drawingViews.values { view.isHidden = true }
        loadedDrawingID = nil
        setSketchControlVisible(false)
    }

    /// Hide the glass as well as its hosted button. Hiding only the button
    /// leaves an empty white control behind in regular note mode.
    private func setCanvasControlsVisible(_ visible: Bool) {
        for button in canvasControlButtons {
            button.isHidden = !visible
        }
        for surface in canvasControlSurfaces { surface.isHidden = !visible }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleNotes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleNotes.indices.contains(row) else { return nil }
        let note = visibleNotes[row]
        let effectiveTheme = theme.resolved(for: effectiveAppearance)
        
        let cell = NSTableCellView()
        let heading = NSTextField(labelWithString: note.title)
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = effectiveTheme.textPrimary
        
        let date = NSTextField(labelWithString: note.modified.formatted(date: .abbreviated, time: .shortened))
        date.font = .systemFont(ofSize: 11)
        date.textColor = effectiveTheme.textSecondary
        
        let previewText: String
        if note.isDrawing {
            previewText = note.drawingStrokeFile == nil && note.drawingFile != nil ? "Imported drawing" : "Drawing"
        } else if note.isCanvas {
            previewText = "Canvas · \(note.canvasBlocks.count) cards"
        } else if note.drawingStrokeFile != nil {
            previewText = "Sketch · " + note.body.replacingOccurrences(of: "\n", with: " ")
        } else {
            previewText = note.body.replacingOccurrences(of: "\n", with: " ")
        }
        let preview = NSTextField(labelWithString: previewText)
        preview.font = .systemFont(ofSize: 11)
        preview.textColor = effectiveTheme.textSecondary
        preview.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [heading, date, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.frame = NSRect(x: 12, y: 9, width: listColumnWidth - 24, height: 54)
        cell.addSubview(stack)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notesTable.selectedRow >= 0, visibleNotes.indices.contains(notesTable.selectedRow) else { return }
        selectNote(visibleNotes[notesTable.selectedRow].id)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let effectiveTheme = theme.resolved(for: effectiveAppearance)
        return CozyTableRowView(accentColor: effectiveTheme.accentColor, selectionHighlight: effectiveTheme.selectionHighlight)
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingEditor, let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].body = editor.string
        notes[index].modified = Date()
        scheduleStoreSave()
    }

    func textDidEndEditing(_ notification: Notification) {
        // Ending an edit is delivered while AppKit is still tearing down the
        // field editor. Rebuilding the note UI synchronously here can reach a
        // half-destroyed editor (the ⌘. crash), so hop to the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notesTable.reloadData()
            if let id = self.selectedNoteID { self.selectNote(id) }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard !isUpdatingEditor, let id = selectedNoteID, let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].title = titleField.stringValue
        notes[index].modified = Date()
        if notes[index].isCanvas, let firstCard = canvasViews[id]?.canvasView.cards.first?.1 {
            firstCard.title = titleField.stringValue
        }
        scheduleStoreSave()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notesTable.reloadData()
            if let id = self.selectedNoteID { self.selectNote(id) }
        }
    }

    /// ⌘. is AppKit's cancel. Without an override it falls through to the
    /// default responder while the inline editor is live; end the edit on the
    /// next turn instead so the field editor is never rebuilt mid-teardown.
    override func cancelOperation(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window?.firstResponder is NSTextView {
                self.window?.makeFirstResponder(nil)
            }
        }
    }


    private var storeURL: URL {
        // Use iCloud Drive Documents folder directly: ~/Library/Mobile Documents/com~apple~CloudDocs/Documents/Notesy/
        let icloudBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Notesy", isDirectory: true)
        let localBase = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notesy", isDirectory: true)
        // Prefer iCloud Drive if it exists, otherwise local
        let useURL = FileManager.default.fileExists(atPath: icloudBase.path) ? icloudBase : localBase
        try? FileManager.default.createDirectory(at: useURL, withIntermediateDirectories: true)
        return useURL.appendingPathComponent("Notes.json")
    }

    private func load() {
        isRestoring = true
        defer { isRestoring = false }
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode(SavedNotes.self, from: data) {
            notes = saved.notes
            folders = saved.folders
        } else {
            // First run under the new name: pull in the user's notes from the
            // previous app's store so nothing is lost on the rename.
            if let migrated = migrateFromOldStore(), migrated.notes.count > 0 {
                notes = migrated.notes
                folders = migrated.folders
            } else {
                notes = [
                    WorkspaceNote(title: "Welcome to Notesy", body: "Your notes live here. Create folders, write freely, and switch to Canvas when you want to arrange ideas spatially.", folder: "Notes"),
                    WorkspaceNote(title: "A note can be more than text", body: "Use the toolbar to add checklist items, tables, and attachments. Your edits save automatically on this Mac.", folder: "Notes")
                ]
            }
        }
    }

    /// Migration: check old storage locations (both iCloud/Documents CanvasNotes and Application Support CanvasNotes).
    private func migrateFromOldStore() -> SavedNotes? {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/CanvasNotes/Notes.json"),
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CanvasNotes/Notes.json"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CanvasNotes/Notes.json")
        ]
        for oldURL in candidates {
            guard let data = try? Data(contentsOf: oldURL),
                  let saved = try? JSONDecoder().decode(SavedNotes.self, from: data),
                  saved.notes.count > 0 else { continue }
            let encoded = try? JSONEncoder().encode(saved)
            try? encoded?.write(to: storeURL, options: .atomic)
            return saved
        }
        return nil
    }

    /// Coalesces in-place note edits into one atomic store write. Mutating
    /// `notes[index]` does not fire `notes`'s `didSet`, so typing a note body
    /// or title never reached disk until an unrelated structural change.
    private func scheduleStoreSave() {
        guard !isRestoring, !isBatchingSave else { return }
        storeSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.storeSaveWorkItem = nil
            self?.save()
        }
        storeSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Writes everything pending: used when the app quits or the window closes.
    func flushPendingSaves() {
        storeSaveWorkItem?.cancel()
        storeSaveWorkItem = nil
        drawingSaveWorkItem?.cancel()
        drawingSaveWorkItem = nil
        if let id = pendingDrawingSave {
            pendingDrawingSave = nil
            saveDrawing(id: id)
        }
        save()
    }

    private func save() {
        guard !isRestoring, !isBatchingSave, isViewLoaded else { return }
        let data = try? JSONEncoder().encode(SavedNotes(notes: notes, folders: folders))
        try? data?.write(to: storeURL, options: .atomic)
    }

    /// True once this view is actually inside a window. Before that, `save()`
    /// would write an empty store back over the file we just loaded.
    private var isViewLoaded: Bool { window != nil }

    // MARK: - Public menu actions

    func newCanvas() {
        if ["All iCloud", "Canvas", "Drawings"].contains(selectedFolder) {
            selectedFolder = "Notes"
            folderHeader.stringValue = folderDisplayName(selectedFolder)
            rebuildFolderRows()
        }
        let note = WorkspaceNote(title: "New Canvas", body: "", folder: selectedFolder, isCanvas: true)
        notes.append(note)
        notesTable.reloadData()
        selectNote(note.id)
    }

    @objc func showFindPanel() {
        window?.makeFirstResponder(searchField)
    }

    @objc func toggleSidebar() {
        showsSidebar.toggle()
        animateLayout()
    }

    @objc func toggleNotesList() {
        showsNotesList.toggle()
        animateLayout()
    }

    @objc func toggleToolbar() {
        showsToolbar.toggle()
        animateLayout()
    }

    private func animateLayout() {
        // Toggling a flag does not mark the view dirty, so ask for a layout pass
        // explicitly; otherwise the frames never update and the buttons look dead.
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    @objc func zoomCanvasIn() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        canvas.setZoomScale(canvas.zoomScale * 1.15)
        zoomLabel.stringValue = "\(Int(canvas.zoomScale * 100))%"
    }

    @objc func zoomCanvasOut() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        canvas.setZoomScale(canvas.zoomScale / 1.15)
        zoomLabel.stringValue = "\(Int(canvas.zoomScale * 100))%"
    }

    @objc func actualSizeCanvas() {
        guard let canvas = selectedNote.flatMap({ canvasViews[$0.id] }) else { return }
        canvas.setZoomScale(1.0)
        zoomLabel.stringValue = "100%"
    }

    func showWelcomeGuide() {
        // The launch guide and Help > Notesy Help can both fire; never stack
        // two overlays, or the two text layers draw on top of each other.
        for case let existing as OnboardingGuideView in subviews {
            existing.removeFromSuperview()
        }
        let guide = OnboardingGuideView(frame: bounds)
        guide.theme = theme
        guide.autoresizingMask = [.width, .height]
        addSubview(guide, positioned: .above, relativeTo: nil)
        guide.frame = bounds
        guide.start()
    }
    
    /// Sync all UI colors to match the current theme
    private func syncThemeColors() {
        // `theme` is already resolved for the appearance in effect.
        let effectiveTheme = theme

        // The backdrop sits behind every glass surface; tinting it with the
        // accent is what makes a theme read as more than a border color.
        backdrop.accent = effectiveTheme.accentColor

        // Apply accent color tint to all glass surfaces
        let tint = effectiveTheme.accentColor.withAlphaComponent(0.12)
        toolbarGlass.tintColor = tint
        sidebarGlass.tintColor = tint
        listCard.tintColor = tint
        zoomHUD.tintColor = tint
        toolbarReveal.tintColor = tint

        // Set content background colors on the glass surfaces' content views.
        // Translucent so the glass still refracts; the reading surfaces below
        // stay opaque so text contrast never depends on the wallpaper.
        let barFill = effectiveTheme.contentBackground.withAlphaComponent(0.45)
        let panelFill = effectiveTheme.contentBackground.withAlphaComponent(0.55)
        toolbarGlass.contentView?.layer?.backgroundColor = barFill.cgColor
        sidebarGlass.contentView?.layer?.backgroundColor = panelFill.cgColor
        listCard.contentView?.layer?.backgroundColor = panelFill.cgColor
        pageCard.fillColor = effectiveTheme.contentBackground
        pageCard.borderColor = effectiveTheme.borderColor
        
        // Notes table
        notesTable.backgroundColor = effectiveTheme.contentBackground
        notesTable.gridColor = effectiveTheme.borderColor
        
        // Editor
        editor.backgroundColor = effectiveTheme.contentBackground
        editor.textColor = effectiveTheme.textPrimary
        editor.insertionPointColor = effectiveTheme.accentColor
        // Existing body text keeps its attributes; only the base color changes.
        if let storage = editor.textStorage, storage.length > 0 {
            isUpdatingEditor = true
            storage.addAttribute(.foregroundColor,
                                 value: effectiveTheme.textPrimary,
                                 range: NSRange(location: 0, length: storage.length))
            isUpdatingEditor = false
        }

        // Toolbar icons follow the theme rather than the system label color.
        for button in leftToolbarButtons + formattingToolbarButtons + rightToolbarButtons + canvasControlButtons {
            button.contentTintColor = effectiveTheme.textSecondary
        }
        newNoteButton?.contentTintColor = effectiveTheme.accentColor
        toolbarRevealButton.contentTintColor = effectiveTheme.textPrimary
        
        // Title field
        titleField.textColor = effectiveTheme.textPrimary
        titleField.backgroundColor = effectiveTheme.contentBackground
        
        // Search field
        searchField.backgroundColor = effectiveTheme.cardBackground
        searchField.textColor = effectiveTheme.textPrimary
        
        // Folder header
        folderHeader.textColor = effectiveTheme.textSecondary
        
        // Zoom HUD
        zoomHUD.contentView?.layer?.backgroundColor = effectiveTheme.cardBackground.cgColor
        zoomLabel.textColor = effectiveTheme.textPrimary
        
        // Toolbar reveal
        toolbarReveal.contentView?.layer?.backgroundColor = effectiveTheme.cardBackground.cgColor
        
        // Rebuild folder rows with new theme colors
        rebuildFolderRows()

        // Keep an open guide in step with the theme.
        for case let guide as OnboardingGuideView in subviews {
            guide.theme = effectiveTheme
        }
        
        // Reload notes table to update selection colors
        notesTable.reloadData()
        
        // Update canvas views
        for canvas in canvasViews.values {
            canvas.backgroundColor = effectiveTheme.contentBackground
        }
        // Drawing editors keep their own paper + palette in step with the theme.
        for drawing in drawingViews.values {
            drawing.configure(theme: effectiveTheme)
        }
        
        // Force redraw
        needsDisplay = true
    }
}

/// Top-down container for the sidebar's folder rows. Rows are placed by frame,
/// so the scroll view's document height can be computed without Auto Layout.
private final class FlippedStackView: NSView {
    override var isFlipped: Bool { true }
}

/// Content of one folder-row glass: a single button inset from the left edge.
/// Frame layout keeps `NSGlassEffectView`'s internal content constraints happy.
private final class FolderRowContentView: NSView {
    private let button: NSButton
    private let leadingInset: CGFloat

    init(button: NSButton, leadingInset: CGFloat) {
        self.button = button
        self.leadingInset = leadingInset
        super.init(frame: .zero)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let height: CGFloat = 24
        button.frame = NSRect(
            x: leadingInset,
            y: max(0, (bounds.height - height) / 2),
            width: max(0, bounds.width - leadingInset - 12),
            height: height
        )
    }
}

/// Custom row view with theme-based selection
private class CozyTableRowView: NSTableRowView {
    private let accentColor: NSColor
    private let selectionHighlight: NSColor
    
    init(accentColor: NSColor, selectionHighlight: NSColor) {
        self.accentColor = accentColor
        self.selectionHighlight = selectionHighlight
        super.init(frame: .zero)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let rect = bounds.insetBy(dx: 4, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        selectionHighlight.setFill()
        path.fill()
        
        // Subtle border
        accentColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
    
    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent background
    }
}

private struct SavedNotes: Codable {
    var notes: [WorkspaceNote]
    var folders: [String]
}
