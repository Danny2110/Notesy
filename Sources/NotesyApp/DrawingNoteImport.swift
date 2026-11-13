import Foundation

/// Turns Apple Notes drawings into drawing-note payloads for the workspace.
enum DrawingNoteImport {
    /// One importable drawing note: everything the workspace needs except the
    /// note's own UUID, which the store assigns when it merges the import.
    struct Draft: Sendable {
        let sourceID: String
        let title: String
        let folderPath: [String]
        /// File name inside `DrawingMedia.drawingsDirectory`.
        let imageFile: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// A PNG could not be stored; `written` has already been cleaned up.
    struct WriteFailure: LocalizedError {
        let sourceID: String
        let underlying: Error

        var errorDescription: String? {
            "Could not save the drawing for \(sourceID): \(underlying.localizedDescription)"
        }
    }

    /// Converts drawings found in Apple Notes into drafts, writing their PNGs
    /// into the notes folder and dropping duplicates of an already imported
    /// drawing (same `sourceID`). Order is deterministic: noteID, then index.
    static func makeDrafts(
        drawings: [AppleNotesDrawings.ImportedDrawing],
        titles: [String: String],
        folders: [String: [String]],
        alreadyImported: Set<String>
    ) throws -> [Draft] {
        let ordered = drawings.sorted {
            $0.noteID == $1.noteID ? $0.index < $1.index : $0.noteID < $1.noteID
        }

        var seen = alreadyImported
        var drafts: [Draft] = []
        var written: [String] = []
        /// How many drawings of each note have become drafts so far.
        var perNote: [String: Int] = [:]
        var current = ""

        do {
            for drawing in ordered {
                let sourceID = "\(drawing.noteID)#\(drawing.index)"
                guard seen.insert(sourceID).inserted else { continue }
                current = sourceID

                let file = try DrawingMedia.storePNG(
                    drawing.pngData,
                    name: "apple-\(drawing.noteID)-\(drawing.index).png"
                )
                written.append(file)

                let ordinal = (perNote[drawing.noteID] ?? 0) + 1
                perNote[drawing.noteID] = ordinal
                var title = baseTitle(titles[drawing.noteID])
                if ordinal > 1 { title += " \(ordinal)" }

                drafts.append(
                    Draft(
                        sourceID: sourceID,
                        title: title,
                        folderPath: folder(for: drawing.noteID, folders: folders),
                        imageFile: file,
                        pixelWidth: drawing.pixelWidth,
                        pixelHeight: drawing.pixelHeight
                    )
                )
            }
        } catch {
            for file in written { DrawingMedia.remove(file) }
            throw WriteFailure(sourceID: current, underlying: error)
        }

        return drafts
    }

    /// Trimmed title, `"Drawing"` when missing or empty, capped at 80 chars.
    private static func baseTitle(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Drawing" : trimmed
        return name.count > 80 ? String(name.prefix(80)) + "…" : name
    }

    /// Folder for the source note, falling back to `["Notes"]`.
    private static func folder(for noteID: String, folders: [String: [String]]) -> [String] {
        let path = (folders[noteID] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return path.isEmpty ? ["Notes"] : path
    }
}
