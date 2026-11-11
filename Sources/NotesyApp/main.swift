import AppKit
import UniformTypeIdentifiers

@main
@MainActor
enum NotesyApp {
    static func main() {
        let app = NSApplication.shared
        applyAppearanceOverride()
        setupMainMenu()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // NSApplication.delegate is weak. Keep the delegate alive for the
        // entire event loop; otherwise ARC may release this local after the
        // assignment and AppKit later sends messages through a dangling pointer.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    /// Screenshot hook: `CANVASNOTES_APPEARANCE=dark|light` pins the whole app
    /// to one appearance before any window exists. This is the only place the
    /// app forces an appearance; everything else follows the system.
    private static func applyAppearanceOverride() {
        let requested = ProcessInfo.processInfo.environment["CANVASNOTES_APPEARANCE"]?.lowercased()
        if requested == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        } else if requested == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        }
    }

    private static func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu(title: "Notesy")
        appMenu.addItem(NSMenuItem(title: "About Notesy", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(AppDelegate.openSettingsFromMenu(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Notesy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        if let item = appMenu.items.last { item.keyEquivalentModifierMask = [.command, .option] }
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Notesy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem(title: "Notesy", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        mainMenu.setSubmenu(appMenu, for: appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Note", action: #selector(AppDelegate.newNoteFromMenu(_:)), keyEquivalent: "n"))
        let newCanvasItem = NSMenuItem(title: "New Canvas", action: #selector(AppDelegate.newCanvasFromMenu(_:)), keyEquivalent: "n")
        newCanvasItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newCanvasItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Import from Apple Notes…", action: #selector(AppDelegate.importFromMenu(_:)), keyEquivalent: "i"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        mainMenu.setSubmenu(fileMenu, for: fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find", action: #selector(AppDelegate.showFindPanel(_:)), keyEquivalent: "f"))
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)
        mainMenu.setSubmenu(editMenu, for: editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(AppDelegate.toggleSidebarFromMenu(_:)), keyEquivalent: "s")
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleSidebarItem)
        let toggleToolbarItem = NSMenuItem(title: "Toggle Toolbar", action: #selector(AppDelegate.toggleToolbarFromMenu(_:)), keyEquivalent: "t")
        toggleToolbarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toggleToolbarItem)
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Zoom In", action: #selector(AppDelegate.zoomInFromMenu(_:)), keyEquivalent: "+"))
        viewMenu.addItem(NSMenuItem(title: "Zoom Out", action: #selector(AppDelegate.zoomOutFromMenu(_:)), keyEquivalent: "-"))
        viewMenu.addItem(NSMenuItem(title: "Actual Size", action: #selector(AppDelegate.actualSizeFromMenu(_:)), keyEquivalent: "0"))
        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        mainMenu.setSubmenu(viewMenu, for: viewMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        mainMenu.setSubmenu(windowMenu, for: windowMenuItem)

        // Help menu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "Notesy Help", action: #selector(AppDelegate.showOnboardingGuide(_:)), keyEquivalent: "?"))
        let helpMenuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
        mainMenu.addItem(helpMenuItem)
        mainMenu.setSubmenu(helpMenu, for: helpMenuItem)

        NSApp.mainMenu = mainMenu

        // Resolve menu actions explicitly. Nil-target items rely on the
        // responder chain, which drops the delegate for this window setup.
        if let delegate = NSApp.delegate {
            for topItem in mainMenu.items {
                guard let submenu = topItem.submenu else { continue }
                for item in submenu.items {
                    if let action = item.action, delegate.responds(to: action) {
                        item.target = delegate
                    }
                }
            }
        }
    }
}

/// Window/titlebar color sampled from the top edge of `AmbientBackdropView(.chrome)`
/// so a transparent titlebar reads as part of the content backdrop in both appearances.
/// The value is a dynamic color resolved by AppKit, so switching appearance
/// retints the titlebar without the app having to rebuild it.
private func chromeBackgroundColor(for themeID: ThemeID) -> NSColor {
    let light = themeForID(themeID).lightBackground
    let dark = notesyPalette(for: themeID, dark: true).darkBackground
    return NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// Shared chrome treatment: the titlebar dissolves into the backdrop, with no
/// separator line, so glass bars inside the content own the visible edges.
@MainActor
private func applyGlassChrome(to window: NSWindow, themeID: ThemeID) {
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.titlebarSeparatorStyle = .none
    window.backgroundColor = chromeBackgroundColor(for: themeID)
    // Remove the titlebar shadow line
    if let titlebar = window.standardWindowButton(.closeButton)?.superview?.superview {
        titlebar.wantsLayer = true
        titlebar.layer?.backgroundColor = NSColor.clear.cgColor
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private weak var workspace: NotesWorkspaceView?
    /// The chosen theme, kept as an ID so every surface can resolve the light or
    /// dark palette for whatever appearance is current. Storing a resolved
    /// palette instead let a dark theme leak into a light window (and back).
    private var currentThemeID: ThemeID = UserDefaults.standard.selectedThemeID ?? .amber {
        didSet {
            UserDefaults.standard.selectedThemeID = currentThemeID
            updateWindowThemes()
        }
    }

    private func updateWindowThemes() {
        if let window = window {
            applyGlassChrome(to: window, themeID: currentThemeID)
        }
        if let settingsWindow = settingsWindow {
            applyGlassChrome(to: settingsWindow, themeID: currentThemeID)
            (settingsWindow.contentView as? SettingsView)?.applyTheme(currentThemeID)
        }
        workspace?.setTheme(currentThemeID)
        workspace?.needsDisplay = true
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = NotesWorkspaceView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        workspace = content
        content.onOpenSettings = { [weak self, weak content] in
            guard let self, let content else { return }
            self.openSettings(for: content)
        }
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Notesy"
        applyGlassChrome(to: window, themeID: currentThemeID)
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(content)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Show first-run guide if needed
        if !UserDefaults.standard.bool(forKey: "hasSeenGuide") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak content] in
                content?.showWelcomeGuide()
            }
        }

        // Screenshot hook: open Settings on launch so the theme grid can be
        // captured without driving the menu bar. `cycle` also closes and
        // reopens it, which is the path that used to dereference a freed window.
        let settingsHook = ProcessInfo.processInfo.environment["CANVASNOTES_OPEN_SETTINGS"]?.lowercased()
        if settingsHook == "1" || settingsHook == "cycle" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak content] in
                guard let self, let content else { return }
                self.openSettings(for: content)
                guard settingsHook == "cycle" else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    guard let self else { return }
                    self.settingsWindow?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak content] in
                        guard let self, let content else { return }
                        self.openSettings(for: content)
                    }
                }
            }
        }

        // Screenshot hook: press a theme tile through hit-testing.
        if let raw = ProcessInfo.processInfo.environment["CANVASNOTES_THEME_CLICK"],
           let themeID = ThemeID(rawValue: raw.lowercased()) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                (self?.settingsWindow?.contentView as? SettingsView)?.simulateThemeClick(themeID)
            }
        }

        // Screenshot hook: flip appearance a moment after launch so the live
        // light/dark transition can be captured mid-run.
        if let requested = ProcessInfo.processInfo.environment["CANVASNOTES_TOGGLE_APPEARANCE"]?.lowercased() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                NSApp.appearance = NSAppearance(named: requested == "dark" ? .darkAqua : .aqua)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// An `NSWindow` releases itself on close by default, which leaves the
    /// `settingsWindow` reference pointing at freed memory and crashes the next
    /// time Settings is reopened. Drop the reference instead of trusting it.
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow,
              closing === settingsWindow else { return }
        settingsWindow = nil
    }

    // MARK: - Menu Actions

    @objc func openSettingsFromMenu(_ sender: Any?) {
        guard let workspace else { return }
        openSettings(for: workspace)
    }

    @objc func newNoteFromMenu(_ sender: Any?) {
        workspace?.newNote()
    }

    @objc func newCanvasFromMenu(_ sender: Any?) {
        workspace?.newCanvas()
    }

    @objc func importFromMenu(_ sender: Any?) {
        workspace?.importAppleNotes()
    }

    @objc func showFindPanel(_ sender: Any?) {
        workspace?.showFindPanel()
    }

    @objc func toggleSidebarFromMenu(_ sender: Any?) {
        workspace?.toggleSidebar()
    }

    @objc func toggleToolbarFromMenu(_ sender: Any?) {
        workspace?.toggleToolbar()
    }

    @objc func zoomInFromMenu(_ sender: Any?) {
        workspace?.zoomCanvasIn()
    }

    @objc func zoomOutFromMenu(_ sender: Any?) {
        workspace?.zoomCanvasOut()
    }

    @objc func actualSizeFromMenu(_ sender: Any?) {
        workspace?.actualSizeCanvas()
    }

    @objc func showOnboardingGuide(_ sender: Any?) {
        workspace?.showWelcomeGuide()
    }

    private func openSettings(for workspace: NotesWorkspaceView) {
        if settingsWindow == nil {
            let content = SettingsView(frame: NSRect(x: 0, y: 0, width: 560, height: 660))
            content.onImport = { [weak self, weak workspace] in
                guard let self, let workspace else { return }
                self.settingsWindow?.close()
                self.settingsWindow = nil
                workspace.importAppleNotes()
            }
            content.onThemeChange = { [weak self] themeID in
                self?.currentThemeID = themeID
            }
            content.configure(selectedTheme: UserDefaults.standard.selectedThemeID ?? .amber)
            let settings = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.title = "Notesy Settings"
            // AppKit's default is to release a window when it closes; under ARC
            // that deallocates it behind our strong reference and the next open
            // dereferences freed memory.
            settings.isReleasedWhenClosed = false
            settings.delegate = self
            applyGlassChrome(to: settings, themeID: currentThemeID)
            settings.contentView = content
            settings.center()
            settingsWindow = settings
        }
        settingsWindow.map { applyGlassChrome(to: $0, themeID: currentThemeID) }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Flipped container inside the glass panel so panel padding reads top-down.
@MainActor
private final class SettingsPanelContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class SettingsView: NSView {
    var onImport: (() -> Void)?
    var onThemeChange: ((ThemeID) -> Void)?
    override var isFlipped: Bool { true }
    
    private let backdrop = AmbientBackdropView()
    private let panel = GlassSurfaceView.panel(cornerRadius: 22)
    private let panelContent = SettingsPanelContentView()
    
    // Theme section
    private let themeHeading = NSTextField(labelWithString: "Color Theme")
    private let themeDescription = NSTextField(wrappingLabelWithString: "Choose a color theme for the entire app. Changes apply immediately.")
    private let themeGrid = ThemeGridContainer()
    
    // Import section
    private let importHeading = NSTextField(labelWithString: "Apple Notes")
    private let importDescription = NSTextField(wrappingLabelWithString: "Bring all your Apple Notes—including folders inside folders—into Notesy in one click. Nothing is removed from Notes.")
    private let importButton = NSButton(title: "Import All Notes", target: nil, action: nil)
    private let importFootnote = NSTextField(wrappingLabelWithString: "Notesy asks for permission the first time. You can change this later in System Settings › Privacy & Security › Automation.")
    private let divider = NSBox()
    
    /// Inset between the window edge and the glass panel on every side.
    private let panelInset: CGFloat = 16
    /// Inset between the panel edge and its content.
    private let contentInset: CGFloat = 24
    
    func configure(selectedTheme: ThemeID) {
        themeGrid.onThemeSelected = { [weak self] themeID in
            self?.applyTheme(themeID)
            self?.onThemeChange?(themeID)
        }
        themeGrid.configure(selectedTheme: selectedTheme)
        applyTheme(selectedTheme)

        // Refresh layout to include new height
        needsLayout = true
    }

    private var currentThemeID: ThemeID = .amber

    /// Retints the backdrop behind the settings panel for the chosen theme.
    func applyTheme(_ themeID: ThemeID) {
        currentThemeID = themeID
        backdrop.accent = themeForID(themeID).resolved(for: effectiveAppearance).accentColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backdrop.accent = themeForID(currentThemeID).resolved(for: effectiveAppearance).accentColor
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        
        backdrop.tone = .chrome
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        addSubview(backdrop)
        
        panel.frame = bounds.insetBy(dx: panelInset, dy: panelInset)
        panel.autoresizingMask = [.width, .height]
        addSubview(panel)
        
        panelContent.autoresizingMask = [.width, .height]
        
        // Theme section
        themeHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        themeHeading.textColor = .labelColor
        themeHeading.autoresizingMask = [.width]
        
        themeDescription.textColor = .secondaryLabelColor
        themeDescription.autoresizingMask = [.width]
        themeDescription.font = .systemFont(ofSize: 13)
        
        // Add the theme section to panel content
        [themeHeading, themeDescription, themeGrid].forEach(panelContent.addSubview)
        
        // Import section
        importHeading.font = .systemFont(ofSize: 20, weight: .semibold)
        importHeading.textColor = .labelColor
        importHeading.autoresizingMask = [.width]
        
        importDescription.textColor = .secondaryLabelColor
        importDescription.autoresizingMask = [.width]
        importDescription.font = .systemFont(ofSize: 13)
        
        importButton.target = self
        importButton.action = #selector(importAllNotes)
        importButton.bezelStyle = .rounded
        importButton.keyEquivalent = "\r"
        importButton.controlSize = .large
        importButton.autoresizingMask = [.minYMargin]
        
        importFootnote.font = .systemFont(ofSize: 11)
        importFootnote.textColor = .secondaryLabelColor
        importFootnote.autoresizingMask = [.width]

        // One divider for the life of the view; `layout()` only moves it.
        divider.boxType = .separator
        panelContent.addSubview(divider)

        [importHeading, importDescription, importButton, importFootnote].forEach(panelContent.addSubview)
        panel.contentView = panelContent
    }
    
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    
    @objc private func importAllNotes() {
        onImport?()
    }

    /// Screenshot hook: press a theme tile the way a mouse click would, through
    /// hit-testing, so the tile wiring itself is what gets exercised.
    func simulateThemeClick(_ themeID: ThemeID) {
        guard let tile = themeGrid.frame(for: themeID) else { return }
        let point = themeGrid.convert(NSPoint(x: tile.midX, y: tile.midY), to: self)
        guard let hit = hitTest(point) else { return }
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        if let event { hit.mouseDown(with: event) }
    }
    
    override func layout() {
        super.layout()
        backdrop.frame = bounds
        panel.frame = bounds.insetBy(dx: panelInset, dy: panelInset)

        let contentWidth = max(0, panel.bounds.width - contentInset * 2)
        var y: CGFloat = 24

        // Theme section
        themeHeading.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: 28)
        y += 28 + 8
        themeDescription.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: 34)
        y += 34 + 12

        // Theme grid: 3 rows of 76pt buttons with 12pt gaps.
        let gridHeight: CGFloat = 252
        themeGrid.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: gridHeight)
        y += gridHeight + 20

        // Divider
        divider.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: 1)
        y += 1 + 20

        // Import section
        importHeading.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: 28)
        y += 28 + 8
        importDescription.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: 34)
        y += 34 + 16
        importButton.frame = NSRect(x: contentInset, y: y, width: 220, height: 34)
        y += 34 + 12
        importFootnote.frame = NSRect(x: contentInset, y: y, width: contentWidth, height: 44)
    }
}
