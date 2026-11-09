import Foundation

/// A handwritten or drawn note on a page of a book, made with Apple Pencil or a finger.
///
/// Books reflow when the text size or theme changes, so a drawing cannot follow words around. Instead the picture of the page as it
/// looked when the sketch was made is kept behind the drawing, and the sketch is attached to the chapter and place in it.
struct SketchNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var chapterIndex: Int
    var chapterPath: String
    /// How far down the chapter the page was, from 0 to 1.
    var fraction: Double
    var created = Date()
}

/// Every book's sketches: a folder per book with `index.json`, and for each sketch the drawing and the page picture.
/// Stored apart from the PencilKit types so the storage can be tested without them; the drawing is just data here.
@MainActor
final class SketchStore: ObservableObject {
    static let shared = SketchStore()

    private let root: URL
    private var cache: [String: [SketchNote]] = [:]
    @Published private(set) var revision = 0

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sketches", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func folder(_ bookID: String) -> URL {
        let safe = bookID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        return root.appendingPathComponent(String(safe), isDirectory: true)
    }

    private func drawingFile(_ id: UUID, _ bookID: String) -> URL { folder(bookID).appendingPathComponent(id.uuidString + ".drawing") }
    private func backdropFile(_ id: UUID, _ bookID: String) -> URL { folder(bookID).appendingPathComponent(id.uuidString + ".jpg") }
    private func indexFile(_ bookID: String) -> URL { folder(bookID).appendingPathComponent("index.json") }

    /// Sketches in reading order: by chapter, then by place in the chapter.
    func sketches(for bookID: String) -> [SketchNote] {
        if let cached = cache[bookID] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: indexFile(bookID))).flatMap { try? decoder.decode([SketchNote].self, from: $0) } ?? []
        let sorted = Self.ordered(loaded)
        cache[bookID] = sorted
        return sorted
    }

    static func ordered(_ list: [SketchNote]) -> [SketchNote] {
        list.sorted { ($0.chapterIndex, $0.fraction, $0.created) < ($1.chapterIndex, $1.fraction, $1.created) }
    }

    func drawingData(_ id: UUID, book bookID: String) -> Data? { try? Data(contentsOf: drawingFile(id, bookID)) }
    func backdropData(_ id: UUID, book bookID: String) -> Data? { try? Data(contentsOf: backdropFile(id, bookID)) }

    /// Saves a new sketch with its drawing and the picture of the page.
    @discardableResult
    func add(_ note: SketchNote, drawing: Data, backdrop: Data, to bookID: String) -> Bool {
        try? FileManager.default.createDirectory(at: folder(bookID), withIntermediateDirectories: true)
        do {
            try drawing.write(to: drawingFile(note.id, bookID), options: .atomic)
            try backdrop.write(to: backdropFile(note.id, bookID), options: .atomic)
        } catch { return false }
        saveIndex(sketches(for: bookID).filter { $0.id != note.id } + [note], bookID)
        return true
    }

    /// Replaces the drawing of an existing sketch (the page picture stays as it was).
    @discardableResult
    func update(_ note: SketchNote, drawing: Data, in bookID: String) -> Bool {
        guard sketches(for: bookID).contains(where: { $0.id == note.id }) else { return false }
        do { try drawing.write(to: drawingFile(note.id, bookID), options: .atomic) } catch { return false }
        revision += 1
        return true
    }

    func delete(id: UUID, from bookID: String) {
        try? FileManager.default.removeItem(at: drawingFile(id, bookID))
        try? FileManager.default.removeItem(at: backdropFile(id, bookID))
        saveIndex(sketches(for: bookID).filter { $0.id != id }, bookID)
    }

    func deleteAll(for bookID: String) {
        cache[bookID] = nil
        try? FileManager.default.removeItem(at: folder(bookID))
        revision += 1
    }

    private func saveIndex(_ list: [SketchNote], _ bookID: String) {
        let sorted = Self.ordered(list)
        cache[bookID] = sorted
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try? FileManager.default.createDirectory(at: folder(bookID), withIntermediateDirectories: true)
        if let data = try? encoder.encode(sorted) { try? data.write(to: indexFile(bookID), options: .atomic) }
        revision += 1
    }
}
