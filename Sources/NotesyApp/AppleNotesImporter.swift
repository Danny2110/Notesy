import Foundation

/// A note read from Apple Notes, already flattened for the workspace.
struct ImportedNote: Sendable {
    let identifier: String
    let title: String
    let body: String
    let folderPath: [String]
}

enum AppleNotesImporterError: LocalizedError {
    case notAuthorized
    case notesUnavailable
    case noNotes
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Notesy does not have permission to read Apple Notes. Allow it in System Settings > Privacy & Security > Automation, then try the import again."
        case .notesUnavailable:
            return "Apple Notes could not be reached. Open Notes, make sure it is available, then try the import again."
        case .noNotes:
            return "No notes were found in Apple Notes."
        case .failed(let message):
            return message
        }
    }
}

enum AppleNotesImporter {
    /// Runs the AppleScript synchronously on the calling thread. Callers move it off the main thread.
    ///
    /// One Apple Event does the whole walk: for each folder it collects the names,
    /// plaintext bodies and ids of all notes in bulk, and streams them out as a single
    /// string with unit/record separators. No per-note property access, no JSON escaping.
    static func importAll() throws -> [ImportedNote] {
        guard let appleScript = NSAppleScript(source: script) else {
            throw AppleNotesImporterError.failed("The Apple Notes import script could not be compiled.")
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)

        if let errorInfo {
            throw mapError(errorInfo)
        }

        let notes = parse(result.stringValue ?? "")
        guard !notes.isEmpty else {
            throw AppleNotesImporterError.noNotes
        }
        return notes
    }

    // MARK: - Parsing

    private static let recordSeparator = "\u{1E}"
    private static let fieldSeparator = "\u{1F}"
    private static let folderSeparator = "\u{1D}"

    /// Parser for the separator-delimited payload produced by `script`.
    ///
    /// Records are separated by U+001E, fields by U+001F (folder path, id, title, body),
    /// and folder path components by U+001D. Anything after the final record separator
    /// (for example a trailing newline added by the scripting bridge) is ignored.
    static func parse(_ raw: String) -> [ImportedNote] {
        var notes: [ImportedNote] = []
        notes.reserveCapacity(512)

        for record in raw.components(separatedBy: recordSeparator) {
            let fields = record.components(separatedBy: fieldSeparator)
            guard fields.count >= 4 else { continue }

            let folderPath = makeFolderPath(fields[0])
            let identifier = fields[1]
            let split = splitTitleAndBody(
                title: fields[2],
                body: fields.dropFirst(3).joined(separator: fieldSeparator)
            )

            notes.append(ImportedNote(identifier: identifier, title: split.title, body: split.body, folderPath: folderPath))
        }

        return notes
    }

    /// Repairs notes imported before title/body splitting was applied.
    static func removeRepeatedTitle(from body: String, title: String) -> String? {
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let split = splitTitleAndBody(title: title, body: normalized)
        if split.body != normalized { return split.body }

        // Apple Notes caps long note names with an ellipsis but may leave the
        // full title prefix in plaintext, joined to the first body sentence.
        guard title.hasSuffix("\u{2026}"),
              let firstLine = firstContentLine(of: normalized) else { return nil }
        let titlePrefix = String(title.dropLast())
        if firstLine.value.count > titlePrefixLimit,
           firstLine.value.hasPrefix(titlePrefix),
           let range = normalized.range(of: firstLine.value) {
            let prefixEnd = normalized.index(range.lowerBound, offsetBy: titlePrefix.count)
            let remainder = normalized[prefixEnd...].drop(while: { $0.isWhitespace || $0 == "," || $0 == ";" })
            return String(normalized[..<range.lowerBound]) + String(remainder)
        }

        // A previous repair may already have removed the title prefix while
        // leaving its separator at the start of the continuation.
        guard firstLine.value.first == "," || firstLine.value.first == ";",
              let range = normalized.range(of: firstLine.value) else { return nil }
        let remainder = normalized[range.lowerBound...].drop(while: { $0.isWhitespace || $0 == "," || $0 == ";" })
        return String(normalized[..<range.lowerBound]) + String(remainder)
    }

    private static func makeFolderPath(_ raw: String) -> [String] {
        let components = raw
            .components(separatedBy: folderSeparator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.replacingOccurrences(of: "/", with: "\u{2044}") }
        return components.isEmpty ? ["Notes"] : components
    }

    private static let spacesAndTabs = CharacterSet(charactersIn: " \t")

    /// Splits an Apple Notes title/body pair. Notes stores the title as the first line of
    /// the plaintext body, so the body usually carries a duplicate of it.
    ///
    /// The duplicate is only removed when the first non-empty line really matches, with
    /// spaces and tabs ignored on both ends:
    /// 1. line == title, or
    /// 2. the title is truncated with "…" and the line continues that title.
    /// A matching line up to `titlePrefixLimit` characters becomes the title and is removed
    /// from the body. A longer line is a paragraph, not a title: the title is capped and the
    /// body keeps the whole line, so the note never ends up empty. Any other prefix
    /// relationship is left alone: a partial match is never guessed.
    private static func splitTitleAndBody(title rawTitle: String, body rawBody: String) -> (title: String, body: String) {
        let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = trimmedTitle.isEmpty ? "New Note" : trimmedTitle

        let normalized = rawBody
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")

        guard let firstLine = firstContentLine(of: normalized) else {
            return (fallbackTitle, normalized)
        }

        // Compare with spaces and tabs stripped from both ends: a note whose
        // first body line is " breakdown of the five key elements:" or
        // "\t\tPsalm 1 NIV" still matches its title.
        let matchesTitle = !trimmedTitle.isEmpty && firstLine.value == trimmedTitle
        let continuesTruncatedTitle = isTruncatedTitle(rawTitle: trimmedTitle, continuedBy: firstLine.value)
        guard matchesTitle || continuesTruncatedTitle else {
            return (fallbackTitle, normalized)
        }

        guard firstLine.value.count > titlePrefixLimit else {
            return (firstLine.value, bodyRemainder(of: normalized, after: firstLine.end))
        }

        let capped = String(firstLine.value.prefix(titlePrefixLimit)) + "\u{2026}"
        return (capped, normalized)
    }

    private static let titlePrefixLimit = 80

    /// The title was cut off with "…" and the body line carries the rest of it.
    private static func isTruncatedTitle(rawTitle: String, continuedBy line: String) -> Bool {
        guard rawTitle.hasSuffix("\u{2026}") else { return false }
        let truncated = String(rawTitle.dropLast())
        return !truncated.isEmpty && line.hasPrefix(truncated)
    }

    /// First line that is not blank, skipping blank lines at the start of the body.
    /// `value` has spaces and tabs removed from both ends; `end` is the end of that line.
    private static func firstContentLine(of text: String) -> (value: String, end: String.Index)? {
        var start = text.startIndex

        while start < text.endIndex {
            let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
            let rawLine = text[start..<end]

            if !rawLine.trimmingCharacters(in: spacesAndTabs).isEmpty {
                var valueStart = start
                while valueStart < end, text[valueStart] == " " || text[valueStart] == "\t" {
                    valueStart = text.index(after: valueStart)
                }
                var valueEnd = end
                while valueEnd > valueStart {
                    let previous = text.index(before: valueEnd)
                    let character = text[previous]
                    if character == " " || character == "\t" {
                        valueEnd = previous
                    } else {
                        break
                    }
                }
                return (String(text[valueStart..<valueEnd]), end)
            }

            guard end < text.endIndex else { return nil }
            start = text.index(after: end)
        }

        return nil
    }

    /// Everything after the matched line, without the newline that ends it.
    private static func bodyRemainder(of text: String, after lineEnd: String.Index) -> String {
        guard lineEnd < text.endIndex else { return "" }
        return String(text[text.index(after: lineEnd)...])
    }

    // MARK: - Errors

    private static func mapError(_ info: NSDictionary) -> AppleNotesImporterError {
        let number = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
        let message = info[NSAppleScript.errorMessage] as? String

        switch number {
        case -1743:
            return .notAuthorized
        case -1728, -600, -609, -1712:
            return .notesUnavailable
        default:
            let text = message ?? "Apple Notes could not be read."
            return .failed("\(text) (error \(number))")
        }
    }

    // MARK: - AppleScript

    /// Bulk export: one event per folder, three list queries, separators instead of escaping.
    private static let script: String = #"""
    set RS to (ASCII character 30)
    set US to (ASCII character 31)
    set GS to (ASCII character 29)
    set out to ""
    tell application "Notes"
        repeat with fRef in folders
            set f to contents of fRef
            set p to ""
            set acct to ""
            set skipNote to false
            set c to f
            set depth to 0
            repeat while depth < 16
                try
                    if class of c is folder then
                        set fname to name of c
                        if fname is "Recently Deleted" then set skipNote to true
                        if p is "" then
                            set p to fname
                        else
                            set p to fname & GS & p
                        end if
                        set c to container of c
                        set depth to depth + 1
                    else if class of c is account then
                        set acct to name of c
                        exit repeat
                    else
                        exit repeat
                    end if
                on error
                    exit repeat
                end try
            end repeat
            if skipNote is false then
                if acct is not "iCloud" and acct is not "" then
                    if p is "" then
                        set p to acct
                    else
                        set p to acct & GS & p
                    end if
                end if
                try
                    set ns to name of every note of f
                    set bs to plaintext of every note of f
                    set ids to id of every note of f
                    repeat with i from 1 to (count of ns)
                        set out to out & p & US & (item i of ids) & US & (item i of ns) & US & (item i of bs) & RS
                    end repeat
                end try
            end if
        end repeat
    end tell
    return out
    """#
}
