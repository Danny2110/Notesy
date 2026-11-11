//
//  ThemeView.swift
//  Notesy
//
//  Simple visual theme selector UI component
//

import AppKit

/// Visual representation of a theme for the settings panel
@MainActor
class ThemeButtonView: NSView {
    let themeID: ThemeID
    var isSelected: Bool {
        didSet {
            needsDisplay = true
        }
    }
    let action: (() -> Void)?
    
    private let colorCircle = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    
    init(themeID: ThemeID, isSelected: Bool = false, action: (() -> Void)? = nil) {
        self.themeID = themeID
        self.isSelected = isSelected
        self.action = action
        super.init(frame: .zero)
        setupUI()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 10
        
        // Color circle
        colorCircle.wantsLayer = true
        colorCircle.layer?.cornerRadius = 18
        colorCircle.layer?.backgroundColor = themeID.getTheme().accentColor.cgColor
        addSubview(colorCircle)
        
        // Title
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.stringValue = themeID.name
        addSubview(titleLabel)
    }
    
    override func layout() {
        super.layout()
        let circleSize: CGFloat = 36
        let size = bounds.width
        colorCircle.frame = NSRect(x: (size - circleSize) / 2, y: bounds.height - circleSize - 10, width: circleSize, height: circleSize)
        titleLabel.frame = NSRect(x: 2, y: 8, width: size - 4, height: 16)
    }
    
    override func mouseDown(with event: NSEvent) {
        action?()
    }

    /// The tile is one target: clicks on the swatch or the caption select the
    /// theme instead of being swallowed by a child view. `point` arrives in the
    /// superview's coordinates, so convert before comparing with `bounds`.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0 else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        if isSelected {
            let accent = themeID.getTheme().accentColor
            // Subtle selection glow
            accent.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10).fill()

            accent.setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            path.lineWidth = 2
            path.stroke()
        } else {
            // Hover effect could go here, but for now just a very faint border
            NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
        }
    }
}

/// Container that lays out theme buttons in a grid
@MainActor
class ThemeGridContainer: NSView {
    private var buttons: [ThemeButtonView] = []
    var onThemeSelected: ((ThemeID) -> Void)?
    private var selectedThemeID: ThemeID = .amber
    
    override var isFlipped: Bool { true }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    
    func configure(selectedTheme: ThemeID) {
        self.selectedThemeID = selectedTheme
        
        if buttons.isEmpty {
            for themeID in ThemeID.allCases {
                let button = ThemeButtonView(
                    themeID: themeID,
                    isSelected: themeID == selectedTheme
                ) { [weak self] in
                    self?.selectTheme(themeID)
                }
                addSubview(button)
                buttons.append(button)
            }
        } else {
            for button in buttons {
                button.isSelected = button.themeID == selectedTheme
            }
        }
        needsLayout = true
    }
    
    private func selectTheme(_ themeID: ThemeID) {
        selectedThemeID = themeID
        for button in buttons {
            button.isSelected = button.themeID == themeID
        }
        onThemeSelected?(themeID)
    }
    
    /// Frame of one tile in this container's coordinates. Used by the click
    /// hook so a simulated press goes through the same hit-test path.
    func frame(for themeID: ThemeID) -> NSRect? {
        buttons.first { $0.themeID == themeID }?.frame
    }

    override func layout() {
        super.layout()
        let columns = 3
        let spacing: CGFloat = 12
        let buttonWidth = (bounds.width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        let buttonHeight: CGFloat = 76
        
        for (index, button) in buttons.enumerated() {
            let col = index % columns
            let row = index / columns
            
            let x = CGFloat(col) * (buttonWidth + spacing)
            let y = CGFloat(row) * (buttonHeight + spacing)
            
            button.frame = NSRect(x: x, y: y, width: buttonWidth, height: buttonHeight)
        }
    }
}
