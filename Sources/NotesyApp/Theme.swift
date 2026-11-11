//
//  Theme.swift
//  Notesy
//
//  Customizable color themes for the app.
//
//  Every theme carries a complete light palette and a complete dark palette.
//  `resolved(for:)` swaps between them as one unit, so a theme can never end up
//  with a light content surface inside a dark window (or the reverse).
//

import AppKit

// MARK: - Helpers

private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

private func blend(_ base: NSColor, _ tint: NSColor, _ amount: CGFloat) -> NSColor {
    guard let b = base.usingColorSpace(.sRGB), let t = tint.usingColorSpace(.sRGB) else { return base }
    return NSColor(
        srgbRed: b.redComponent + (t.redComponent - b.redComponent) * amount,
        green: b.greenComponent + (t.greenComponent - b.greenComponent) * amount,
        blue: b.blueComponent + (t.blueComponent - b.blueComponent) * amount,
        alpha: 1
    )
}

private func withAlpha(_ color: NSColor, _ alpha: CGFloat) -> NSColor {
    color.withAlphaComponent(alpha)
}

// MARK: - Theme

/// A fully resolved color scheme: one appearance, one accent, one set of
/// surfaces. The `lightBackground` / `darkBackground` pair is the window chrome
/// and is intentionally *not* rewritten by `resolved(for:)`; it stays valid as a
/// dynamic color source for the titlebar.
struct NotesyTheme {
    let id: ThemeID
    /// Primary accent for highlights, selection, and tinted chrome.
    let accentColor: NSColor
    /// Window/titlebar background in light appearance.
    let lightBackground: NSColor
    /// Window/titlebar background in dark appearance.
    let darkBackground: NSColor
    /// Sidebar, notes list, and page surface.
    let contentBackground: NSColor
    /// Floating card / HUD / search field surface.
    let cardBackground: NSColor
    let selectionHighlight: NSColor
    let borderColor: NSColor
    let textPrimary: NSColor
    let textSecondary: NSColor
    let textTertiary: NSColor
    let readingBackground: NSColor

    func resolved(for appearance: NSAppearance) -> NotesyTheme {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? notesyPalette(for: id, dark: true) : self
    }
}

// MARK: - Theme IDs

enum ThemeID: String, CaseIterable, Identifiable, Codable {
    case amber, blue, purple, green, red, ocean, midnight, forest, rose

    var id: String { rawValue }

    var name: String {
        switch self {
        case .amber: return "Amber"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .green: return "Green"
        case .red: return "Red"
        case .ocean: return "Ocean"
        case .midnight: return "Midnight"
        case .forest: return "Forest"
        case .rose: return "Rose"
        }
    }

    /// Accent used in the light palette.
    fileprivate var lightAccent: NSColor {
        switch self {
        case .amber: return srgb(0.94, 0.65, 0.22)
        case .blue: return srgb(0.28, 0.51, 0.93)
        case .purple: return srgb(0.65, 0.34, 0.92)
        case .green: return srgb(0.18, 0.63, 0.36)
        case .red: return srgb(0.83, 0.25, 0.25)
        case .ocean: return srgb(0.10, 0.52, 0.78)
        case .midnight: return srgb(0.32, 0.42, 0.72)
        case .forest: return srgb(0.26, 0.52, 0.28)
        case .rose: return srgb(0.76, 0.30, 0.47)
        }
    }

    /// Accent used in the dark palette (brighter so it survives a dark surface).
    fileprivate var darkAccent: NSColor {
        switch self {
        case .amber: return srgb(0.99, 0.76, 0.36)
        case .blue: return srgb(0.45, 0.66, 1.00)
        case .purple: return srgb(0.79, 0.53, 0.99)
        case .green: return srgb(0.35, 0.82, 0.53)
        case .red: return srgb(0.94, 0.40, 0.40)
        case .ocean: return srgb(0.26, 0.68, 0.94)
        case .midnight: return srgb(0.58, 0.70, 1.00)
        case .forest: return srgb(0.48, 0.76, 0.44)
        case .rose: return srgb(0.92, 0.47, 0.62)
        }
    }

    /// Light-appearance theme.
    func getTheme() -> NotesyTheme { themeForID(self) }
}

// MARK: - Palette construction

private func makeTheme(_ id: ThemeID, dark: Bool) -> NotesyTheme {
    if dark {
        let accent = id.darkAccent
        let chrome = blend(srgb(0.116, 0.112, 0.118), accent, 0.12)
        let content = blend(srgb(0.145, 0.140, 0.148), accent, 0.10)
        let card = blend(srgb(0.180, 0.175, 0.185), accent, 0.08)
        return NotesyTheme(
            id: id,
            accentColor: accent,
            lightBackground: blend(srgb(0.980, 0.972, 0.962), id.lightAccent, 0.10),
            darkBackground: chrome,
            contentBackground: content,
            cardBackground: card,
            selectionHighlight: withAlpha(accent, 0.32),
            borderColor: withAlpha(accent, 0.34),
            textPrimary: srgb(0.94, 0.94, 0.95),
            textSecondary: srgb(0.74, 0.74, 0.76),
            textTertiary: srgb(0.55, 0.55, 0.58),
            readingBackground: content
        )
    }

    let accent = id.lightAccent
    let chrome = blend(srgb(0.980, 0.972, 0.962), accent, 0.10)
    let content = blend(srgb(0.985, 0.978, 0.968), accent, 0.07)
    let card = blend(srgb(0.998, 0.995, 0.990), accent, 0.05)
    return NotesyTheme(
        id: id,
        accentColor: accent,
        lightBackground: chrome,
        darkBackground: blend(srgb(0.116, 0.112, 0.118), id.darkAccent, 0.12),
        contentBackground: content,
        cardBackground: card,
        selectionHighlight: withAlpha(accent, 0.24),
        borderColor: withAlpha(accent, 0.22),
        textPrimary: srgb(0.13, 0.13, 0.14),
        textSecondary: srgb(0.42, 0.42, 0.44),
        textTertiary: srgb(0.60, 0.60, 0.62),
        readingBackground: content
    )
}

/// Built once, on first use.
private let themeCache: [String: NotesyTheme] = {
    var cache: [String: NotesyTheme] = [:]
    for id in ThemeID.allCases {
        cache["\(id.rawValue)-light"] = makeTheme(id, dark: false)
        cache["\(id.rawValue)-dark"] = makeTheme(id, dark: true)
    }
    return cache
}()

func notesyPalette(for id: ThemeID, dark: Bool) -> NotesyTheme {
    themeCache["\(id.rawValue)-\(dark ? "dark" : "light")"] ?? makeTheme(id, dark: dark)
}

/// Light-appearance (base) theme for an ID.
func themeForID(_ id: ThemeID) -> NotesyTheme {
    notesyPalette(for: id, dark: false)
}

let amberTheme = themeForID(.amber)
let blueTheme = themeForID(.blue)
let purpleTheme = themeForID(.purple)
let greenTheme = themeForID(.green)
let redTheme = themeForID(.red)
let oceanTheme = themeForID(.ocean)
let midnightTheme = themeForID(.midnight)
let forestTheme = themeForID(.forest)
let roseTheme = themeForID(.rose)

func getDefaultTheme() -> NotesyTheme { amberTheme }

// MARK: - Storage

extension UserDefaults {
    private static let themeKey = "notesyTheme"

    var selectedThemeID: ThemeID? {
        get {
            guard let raw = string(forKey: UserDefaults.themeKey) else { return nil }
            return ThemeID(rawValue: raw)
        }
        set {
            set(newValue?.rawValue, forKey: UserDefaults.themeKey)
        }
    }
}

// MARK: - Current theme

@MainActor
func getCurrentTheme() -> NotesyTheme {
    let id = UserDefaults.standard.selectedThemeID ?? .amber
    return themeForID(id).resolved(for: NSApp.effectiveAppearance)
}
