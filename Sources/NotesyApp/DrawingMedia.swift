import AppKit

/// File storage for drawings that live beside the notes store, so the JSON
/// document stays small and every write is atomic.
enum DrawingMedia {
    /// Directory holding imported drawing images.
    static var drawingsDirectory: URL {
        notesDirectory.appendingPathComponent("Media/drawings", isDirectory: true)
    }

    /// Directory holding `Notes.json`.
    static var notesDirectory: URL {
        let icloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Documents/Notesy", isDirectory: true)
        if FileManager.default.fileExists(atPath: icloud.path) { return icloud }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notesy", isDirectory: true)
    }

    /// Writes PNG bytes under the drawings directory and returns the final,
    /// sanitized file name (always ends in `.png`).
    @discardableResult
    static func storePNG(_ data: Data, name: String) throws -> String {
        let file = sanitizedName(name)
        let directory = drawingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        return file
    }

    /// Encodes an image as PNG and stores it, for drag/paste imports of art
    /// that arrived as an `NSImage` rather than bytes.
    @discardableResult
    static func storePNG(image: NSImage, name: String) throws -> String {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw StorageError.imageEncodingFailed
        }
        return try storePNG(png, name: name)
    }

    // MARK: - Editable strokes

    /// Extension for a note's `PKDrawing` data, kept out of `Notes.json` so a
    /// handwriting blob never turns every keystroke into a multi-megabyte write.
    static let strokeExtension = "pkdrawing"

    /// Writes a note's `PKDrawing` data and returns the sidecar file name
    /// (`<uuid>.pkdrawing`), stable per note so repeated saves replace it.
    @discardableResult
    static func storeStrokeData(_ data: Data, noteID: UUID) throws -> String {
        let file = "\(noteID.uuidString.lowercased()).\(strokeExtension)"
        let directory = drawingsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(file), options: .atomic)
        return file
    }

    /// The stored stroke data for a sidecar file name, or nil when missing.
    static func strokeData(for name: String) -> Data? {
        guard name.lowercased().hasSuffix("." + strokeExtension) else { return nil }
        return try? Data(contentsOf: drawingsDirectory.appendingPathComponent(name))
    }

    /// Deletes one stroke sidecar; a missing file is not an error.
    static func removeStrokeFile(_ name: String) {
        guard name.lowercased().hasSuffix("." + strokeExtension) else { return }
        try? FileManager.default.removeItem(at: drawingsDirectory.appendingPathComponent(name))
    }

    /// Deletes stroke sidecars no note references, mirroring `pruneOrphans`.
    @discardableResult
    static func pruneOrphanStrokes(keeping: Set<String>) -> [String] {
        let manager = FileManager.default
        let directory = drawingsDirectory
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let kept = Set(keeping.map { ($0 as NSString).lastPathComponent })
        var removed: [String] = []
        for entry in entries where entry.pathExtension.lowercased() == strokeExtension {
            let file = entry.lastPathComponent
            guard !kept.contains(file) else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed.append(file) }
        }
        return removed.sorted()
    }

    enum StorageError: LocalizedError {
        case imageEncodingFailed

        var errorDescription: String? {
            switch self {
            case .imageEncodingFailed:
                return "That image could not be converted to PNG."
            }
        }
    }

    /// Absolute URL for a stored drawing file name.
    static func url(for name: String) -> URL {
        drawingsDirectory.appendingPathComponent(sanitizedName(name))
    }

    /// Whether a drawing file exists on disk.
    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: name).path)
    }

    /// Deletes a drawing file; a missing file is not an error.
    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// The stored image, or nil when the file is gone or unreadable.
    static func image(for name: String) -> NSImage? {
        NSImage(contentsOf: url(for: name))
    }

    /// Deletes PNG files in the drawings directory that no note references.
    /// Returns the removed file names. Safe when the directory is missing and
    /// ignores files that are not PNGs.
    @discardableResult
    static func pruneOrphans(keeping: Set<String>) -> [String] {
        let manager = FileManager.default
        let directory = drawingsDirectory
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let kept = Set(keeping.map(sanitizedName))
        var removed: [String] = []
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            let file = entry.lastPathComponent
            guard !kept.contains(file) else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed.append(file) }
        }
        return removed.sorted()
    }

    /// Last path component, no path separators, forced `.png` extension.
    private static func sanitizedName(_ name: String) -> String {
        var base = (name as NSString).lastPathComponent
        base = base.replacingOccurrences(of: ":", with: "-")
        base = base.replacingOccurrences(of: "/", with: "-")
        base = base.replacingOccurrences(of: "\\", with: "-")
        base = base.replacingOccurrences(of: "\0", with: "")
        if base.lowercased().hasSuffix(".png") { base.removeLast(4) }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if base.isEmpty { base = "drawing" }
        return base + ".png"
    }
}
