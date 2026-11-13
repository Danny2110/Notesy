import Foundation
import CoreGraphics
import ImageIO
import SQLite3

/// Reads handwriting/drawing attachments out of the Apple Notes store.
///
/// Apple Notes keeps a PencilKit drawing as an attachment (`com.apple.paper`)
/// with a flattened preview image next to it. The scripting dictionary exposes
/// note text only, so the store is read directly.
///
/// The type is a namespace of static functions over immutable inputs, so it is
/// safe to call from any thread, including off the main thread.
enum AppleNotesDrawings {
    /// One drawing found in Apple Notes, ready to become a drawing note.
    struct ImportedDrawing: Sendable {
        /// Apple Notes note id the drawing belongs to.
        let noteID: String
        /// Position of the drawing inside that note, for stable identity.
        ///
        /// Zero-based, ordered by the attachment's creation date and then by
        /// `Z_PK`, so the same drawing keeps the same index across runs.
        let index: Int
        /// PNG bytes of the flattened drawing.
        let pngData: Data
        /// Pixel width/height of the image, 0 when unknown.
        let pixelWidth: Int
        let pixelHeight: Int
        /// Apple Notes attachment identifier, i.e. the `Media/<id>` folder name.
        /// Defaults to empty so existing call sites keep compiling.
        var attachmentID: String = ""
        /// Title of the Apple Notes note that owns the drawing, when the store
        /// exposes a title column (`""` otherwise).
        var noteTitle: String = ""
        /// Folder path of the owning note, top-level first. Empty when unknown.
        var noteFolderPath: [String] = []
    }

    /// What one full scan of a store root produced, including the rows that
    /// were skipped because they were malformed or had no readable image.
    struct ScanReport: Sendable {
        let drawings: [ImportedDrawing]
        /// Attachment rows that looked like drawings but could not be used.
        let skippedRows: Int
        /// `NoteStore.sqlite` files that were opened successfully.
        let stores: [String]
    }

    // MARK: - Locations

    /// Name of the group container Apple Notes keeps its data in.
    private static let containerName = "group.com.apple.notes"

    /// `~/Library/Group Containers/group.com.apple.notes`.
    static var containerDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(containerName, isDirectory: true)
    }

    /// One sentence the settings UI can show next to a "Open System Settings" button.
    static var fullDiskAccessHint: String {
        "Open System Settings > Privacy & Security > Full Disk Access, turn on Notesy, then quit and reopen Notesy so it can read your Apple Notes drawings."
    }

    /// Cheap check: can this process even see the Notes container?
    ///
    /// Without Full Disk Access macOS reports the container as missing and
    /// every read fails with "Operation not permitted", so a directory listing
    /// is the honest test.
    static var isStoreReadable: Bool {
        let fm = FileManager.default
        let root = containerDirectory
        guard (try? fm.contentsOfDirectory(atPath: root.path)) != nil else { return false }
        return fm.isReadableFile(atPath: root.path)
    }

    // MARK: - Entry points

    /// Returns every drawing in the local Apple Notes store, keyed nowhere in
    /// particular: callers join on `noteID`.
    static func importAll() throws -> [ImportedDrawing] {
        try importAll(rootDirectory: containerDirectory)
    }

    /// Same as `importAll()`, reading a store rooted at `rootDirectory`.
    ///
    /// Exists so the parser can be exercised against a fixture: the directory
    /// only has to look like the real container (`NoteStore.sqlite` plus
    /// `Media/<attachment id>/...`).
    static func importAll(rootDirectory: URL) throws -> [ImportedDrawing] {
        try scan(rootDirectory: rootDirectory).drawings
    }

    /// Full scan including the skipped-row count, for diagnostics.
    static func scan(rootDirectory: URL) throws -> ScanReport {
        let stores = discoverStores(in: rootDirectory)
        guard !stores.isEmpty else {
            throw ImportError.storeUnavailable(storeAccessDetail(rootDirectory))
        }

        let mediaRoots = self.mediaRoots(in: rootDirectory, stores: stores)
        var records: [Record] = []
        var skipped = 0
        var opened: [String] = []
        var firstFailure: Error?

        for store in stores {
            do {
                try readStore(at: store, mediaRoots: mediaRoots, records: &records, skipped: &skipped)
                opened.append(store.path)
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }

        // Every store failed: surface the first concrete reason (usually the
        // permission error) instead of pretending the store was empty.
        guard !opened.isEmpty else {
            throw firstFailure ?? ImportError.storeUnavailable(storeAccessDetail(rootDirectory))
        }

        // The same note can be reachable from more than one account store.
        var seen = Set<String>()
        var unique: [Record] = []
        unique.reserveCapacity(records.count)
        for record in records where seen.insert(record.identity).inserted {
            unique.append(record)
        }

        // Group per note, then number the drawings in a stable order.
        var order: [String] = []
        var groups: [String: [Record]] = [:]
        for record in unique {
            if groups[record.noteID] == nil { order.append(record.noteID) }
            groups[record.noteID, default: []].append(record)
        }

        var drawings: [ImportedDrawing] = []
        drawings.reserveCapacity(unique.count)
        for noteID in order {
            guard let rows = groups[noteID] else { continue }
            let sorted = rows.sorted { lhs, rhs in
                if lhs.created != rhs.created { return lhs.created < rhs.created }
                if lhs.pk != rhs.pk { return lhs.pk < rhs.pk }
                return lhs.attachmentID < rhs.attachmentID
            }
            for (index, row) in sorted.enumerated() {
                drawings.append(
                    ImportedDrawing(
                        noteID: noteID,
                        index: index,
                        pngData: row.pngData,
                        pixelWidth: row.pixelWidth,
                        pixelHeight: row.pixelHeight,
                        attachmentID: row.attachmentID,
                        noteTitle: row.noteTitle,
                        noteFolderPath: row.noteFolderPath
                    )
                )
            }
        }

        return ScanReport(drawings: drawings, skippedRows: skipped, stores: opened)
    }

    // MARK: - Store discovery

    /// Every `NoteStore.sqlite` under `rootDirectory`, classic layout first.
    ///
    /// Newer macOS keeps one store per account in `Accounts/<uuid>/`, older
    /// installs keep a single store in the container root. Both are read so a
    /// machine with several accounts returns all drawings.
    static func discoverStores(in rootDirectory: URL) -> [URL] {
        let fm = FileManager.default
        var stores: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path), fm.fileExists(atPath: path) else { return }
            seen.insert(path)
            stores.append(url.standardizedFileURL)
        }

        add(rootDirectory.appendingPathComponent("NoteStore.sqlite"))

        let accounts = rootDirectory.appendingPathComponent("Accounts", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(
            at: accounts,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                add(child.appendingPathComponent("NoteStore.sqlite"))
            }
        }

        if stores.isEmpty {
            // Last resort: the container is shaped differently than expected.
            // Bounded so this stays cheap on a large home directory.
            for url in searchForStores(in: rootDirectory, depth: 3) {
                add(url)
            }
        }

        return stores
    }

    private static func searchForStores(in directory: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var found: [URL] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if child.lastPathComponent == "NoteStore.sqlite" {
                found.append(child)
                continue
            }
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                found.append(contentsOf: searchForStores(in: child, depth: depth - 1))
            }
        }
        return found
    }

    /// Directories that may contain `Media/<attachment id>` folders.
    static func mediaRoots(in rootDirectory: URL, stores: [URL]) -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
            seen.insert(path)
            roots.append(url.standardizedFileURL)
        }

        add(rootDirectory.appendingPathComponent("Media", isDirectory: true))
        for store in stores {
            let account = store.deletingLastPathComponent()
            add(account.appendingPathComponent("Media", isDirectory: true))
            add(account.deletingLastPathComponent().appendingPathComponent("Media", isDirectory: true))
        }

        let accounts = rootDirectory.appendingPathComponent("Accounts", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(
            at: accounts,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                add(child.appendingPathComponent("Media", isDirectory: true))
            }
        }

        return roots
    }

    /// Reads a store that cannot be found or opened, and says which of the two
    /// happened so the UI can point at Full Disk Access rather than shrug.
    private static func storeAccessDetail(_ rootDirectory: URL) -> String {
        let fm = FileManager.default
        let path = rootDirectory.path

        do {
            let entries = try fm.contentsOfDirectory(atPath: path)
            if entries.isEmpty {
                return "Notesy found no Apple Notes data in \(path). Open Notes once so it creates its local store, then try again."
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileReadUnknownError {
                return "Notesy was denied access to \(path). macOS only allows this for apps you trust with Full Disk Access. \(fullDiskAccessHint)"
            }
            return "Notesy could not read \(path) (\(nsError.localizedDescription)). \(fullDiskAccessHint)"
        }

        return "Notesy found no NoteStore.sqlite inside \(path). Open Notes once so it creates its local store, then try again. If that does not help, grant Full Disk Access: \(fullDiskAccessHint)"
    }

    // MARK: - Reading one store

    /// One usable drawing row, before note-relative numbering.
    private struct Record {
        let noteID: String
        let created: Double
        let pk: Int64
        let attachmentID: String
        let pngData: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let noteTitle: String
        let noteFolderPath: [String]

        /// Stable dedupe key across account stores.
        var identity: String { attachmentID.isEmpty ? "\(noteID)#\(pk)" : "\(noteID)#\(attachmentID)" }
    }

    /// A row of `ZICCLOUDSYNCINGOBJECT` looked up by primary key.
    private struct ObjectRow {
        let identifier: String?
        let title: String?
        let folderPK: Int64
        let parentPK: Int64
    }

    private static func readStore(
        at url: URL,
        mediaRoots: [URL],
        records: inout [Record],
        skipped: inout Int
    ) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard status == SQLITE_OK, let db = handle else {
            let detail = sqliteErrorMessage(handle, status)
            if let handle { sqlite3_close_v2(handle) }
            if status == SQLITE_CANTOPEN || status == SQLITE_PERM || status == SQLITE_AUTH
                || detail.localizedCaseInsensitiveContains("authorization denied")
                || detail.localizedCaseInsensitiveContains("not permitted") {
                throw ImportError.storeUnavailable(
                    "macOS blocked access to \(url.path), so Notesy cannot read your Apple Notes drawings. \(fullDiskAccessHint)"
                )
            }
            throw ImportError.storeUnavailable("SQLite could not open \(url.path) (\(detail)). \(fullDiskAccessHint)")
        }
        defer { sqlite3_close_v2(db) }
        // The Notes app keeps this database open; wait rather than fail.
        sqlite3_busy_timeout(db, 2_000)

        let columns = try columnNames(in: db, table: "ZICCLOUDSYNCINGOBJECT")
        guard columns.contains("Z_PK") else {
            throw ImportError.unsupportedLayout("\(url.lastPathComponent) has no ZICCLOUDSYNCINGOBJECT.Z_PK column, so it is not an Apple Notes store Notesy understands.")
        }
        guard let utiColumn = pick(columns, ["ZTYPEUTI"]) else {
            throw ImportError.unsupportedLayout("\(url.lastPathComponent) has no ZICCLOUDSYNCINGOBJECT.ZTYPEUTI column, so Notesy cannot tell drawings from other attachments.")
        }

        let identifierSQL = pick(columns, ["ZIDENTIFIER"]) ?? "NULL"
        let noteSQL = pick(columns, ["ZNOTE"]) ?? "NULL"
        let dateSQL = pick(columns, ["ZCREATIONDATE"]) ?? "NULL"
        let titleSQL = pick(columns, ["ZTITLE", "ZTITLE1", "ZTITLE2"]) ?? "NULL"
        let folderSQL = pick(columns, ["ZFOLDER"]) ?? "NULL"
        let parentSQL = pick(columns, ["ZPARENT"]) ?? "NULL"

        let drawingSQL = """
            SELECT Z_PK, \(identifierSQL), \(noteSQL), \(dateSQL)
            FROM ZICCLOUDSYNCINGOBJECT
            WHERE \(utiColumn) IS NOT NULL
              AND (lower(\(utiColumn)) = 'com.apple.paper' OR lower(\(utiColumn)) LIKE '%drawing%')
            ORDER BY \(noteSQL), \(dateSQL), Z_PK
            """

        let lookupSQL = """
            SELECT \(identifierSQL), \(titleSQL), \(folderSQL), \(parentSQL)
            FROM ZICCLOUDSYNCINGOBJECT
            WHERE Z_PK = ?
            """

        let drawingStatement = try prepare(db, drawingSQL)
        defer { sqlite3_finalize(drawingStatement) }
        let lookupStatement = try prepare(db, lookupSQL)
        defer { sqlite3_finalize(lookupStatement) }

        while sqlite3_step(drawingStatement) == SQLITE_ROW {
            let pk = sqlite3_column_int64(drawingStatement, 0)
            let attachmentID = text(drawingStatement, 1) ?? ""
            let notePK = sqlite3_column_type(drawingStatement, 2) == SQLITE_NULL
                ? Int64(0)
                : sqlite3_column_int64(drawingStatement, 2)
            let created = sqlite3_column_type(drawingStatement, 3) == SQLITE_NULL
                ? 0
                : sqlite3_column_double(drawingStatement, 3)

            guard !attachmentID.isEmpty, notePK != 0 else {
                skipped += 1
                continue
            }

            guard let note = objectRow(db: db, statement: lookupStatement, pk: notePK),
                  let noteID = note.identifier, !noteID.isEmpty else {
                skipped += 1
                continue
            }

            // "Recently Deleted" is skipped whenever the store exposes note
            // folders. Stores too old to have ZFOLDER keep deleted notes in the
            // regular folder tree, where they are indistinguishable from live ones.
            if isTrash(folderPK: note.folderPK, db: db, statement: lookupStatement) {
                continue
            }

            guard let folder = attachmentFolder(id: attachmentID, mediaRoots: mediaRoots),
                  let imageURL = flattenedImage(in: folder),
                  let data = try? Data(contentsOf: imageURL, options: .mappedIfSafe),
                  let image = png(from: data) else {
                skipped += 1
                continue
            }

            records.append(
                Record(
                    noteID: noteID,
                    created: created,
                    pk: pk,
                    attachmentID: attachmentID,
                    pngData: image.data,
                    pixelWidth: image.width,
                    pixelHeight: image.height,
                    noteTitle: note.title ?? "",
                    noteFolderPath: folderPath(for: note.folderPK, db: db, statement: lookupStatement)
                )
            )
        }
    }

    // MARK: - Schema helpers

    private static func columnNames(in db: OpaquePointer, table: String) throws -> Set<String> {
        let statement = try prepare(db, "PRAGMA table_info(\"\(table)\")")
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = text(statement, 1) { names.insert(name) }
        }
        return names
    }

    private static func pick(_ columns: Set<String>, _ candidates: [String]) -> String? {
        for name in candidates where columns.contains(name) { return name }
        return nil
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw ImportError.unsupportedLayout("Apple Notes' database rejected a query (\(sqliteErrorMessage(db, status))).")
        }
        return statement
    }

    private static func objectRow(db: OpaquePointer, statement: OpaquePointer, pk: Int64) -> ObjectRow? {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        guard sqlite3_bind_int64(statement, 1, pk) == SQLITE_OK else { return nil }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            sqlite3_reset(statement)
            return nil
        }
        let row = ObjectRow(
            identifier: text(statement, 0),
            title: text(statement, 1),
            folderPK: sqlite3_column_type(statement, 2) == SQLITE_NULL ? 0 : sqlite3_column_int64(statement, 2),
            parentPK: sqlite3_column_type(statement, 3) == SQLITE_NULL ? 0 : sqlite3_column_int64(statement, 3)
        )
        sqlite3_reset(statement)
        return row
    }

    /// Walks up from a folder to the account root, collecting folder titles.
    ///
    /// The first element is the top-level folder (e.g. `Notes`), so the result
    /// can be joined with `/` and used as a Notesy folder path. Bounded so a
    /// malformed parent chain cannot loop forever.
    private static func folderPath(for folderPK: Int64, db: OpaquePointer, statement: OpaquePointer) -> [String] {
        var parts: [String] = []
        var pk = folderPK
        var hops = 0
        while pk != 0 && hops < 12 {
            guard let row = objectRow(db: db, statement: statement, pk: pk) else { break }
            if let title = row.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                parts.append(title)
            }
            if row.parentPK == 0 || row.parentPK == pk { break }
            pk = row.parentPK
            hops += 1
        }
        return parts.reversed()
    }

    /// Walks up from a note's folder looking for the system trash folder.
    private static func isTrash(folderPK: Int64, db: OpaquePointer, statement: OpaquePointer) -> Bool {
        var pk = folderPK
        var hops = 0
        while pk != 0 && hops < 8 {
            guard let row = objectRow(db: db, statement: statement, pk: pk) else { return false }
            let title = row.title?.lowercased() ?? ""
            let identifier = row.identifier?.lowercased() ?? ""
            if title == "recently deleted" || title == "trash" || title == "deleted" { return true }
            if identifier.contains("trashfolder") || identifier.hasPrefix("trash") { return true }
            pk = row.parentPK
            hops += 1
        }
        return false
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: raw)
    }

    private static func sqliteErrorMessage(_ db: OpaquePointer?, _ code: Int32) -> String {
        if let db, let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "SQLite error \(code)"
    }

    // MARK: - Media

    /// `Media/<attachment id>` for one attachment, or nil when it was pruned.
    static func attachmentFolder(id: String, mediaRoots: [URL]) -> URL? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        for root in mediaRoots {
            for candidate in [id, id.uppercased(), id.lowercased()] {
                let folder = root.appendingPathComponent(candidate, isDirectory: true)
                if fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return folder
                }
            }
        }
        return nil
    }

    /// The flattened pixels Apple Notes renders next to a drawing.
    ///
    /// `FallbackImages` holds the full-size render; `Previews` is the smaller
    /// one kept for list views. Prefer the former, then the latter, then any
    /// image directly in the attachment folder.
    static func flattenedImage(in folder: URL) -> URL? {
        for subdirectory in ["FallbackImages", "Previews"] {
            if let best = largestImage(in: folder.appendingPathComponent(subdirectory, isDirectory: true)) {
                return best
            }
        }
        return largestImage(in: folder)
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp"]

    private static func largestImage(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        let candidates = children.filter {
            imageExtensions.contains($0.pathExtension.lowercased())
        }
        guard !candidates.isEmpty else { return nil }

        // Largest file first, then name, so repeated runs pick the same image.
        let sorted = candidates.sorted { lhs, rhs in
            let leftSize = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let rightSize = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if leftSize != rightSize { return leftSize > rightSize }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
        return sorted.first
    }

    // MARK: - Image conversion

    /// PNG bytes plus pixel size for any image Apple Notes stored on disk.
    ///
    /// JPEGs are re-encoded once, at their original pixel size: no downscaling,
    /// no color management changes, no metadata carry-over.
    static func png(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

        let width = image.width
        let height = image.height

        if isPNG(data) {
            return (data, width, height)
        }

        guard let output = CFDataCreateMutable(kCFAllocatorDefault, 0),
              let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        return (output as Data, width, height)
    }

    private static func isPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return Array(data.prefix(signature.count)) == signature
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case notImplemented
        case storeUnavailable(String)
        case unsupportedLayout(String)

        var errorDescription: String? {
            switch self {
            case .notImplemented:
                return "Drawing import is not implemented yet."
            case .storeUnavailable(let detail):
                return "Apple Notes' drawing store could not be read: \(detail)"
            case .unsupportedLayout(let detail):
                return "Apple Notes' drawing store has an unexpected layout: \(detail)"
            }
        }
    }
}
