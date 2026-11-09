import Foundation

/// A highlight, with an optional note, in one chapter of one book.
///
/// The position is the character range inside the chapter's text, as counted by the reader's web view (UTF-16 units over
/// `document.body`, which is what JavaScript's `Range.toString()` measures). `quote` keeps the highlighted words so the list,
/// the export and a changed layout never depend on the position alone.
struct Annotation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var chapterIndex: Int
    var chapterPath: String
    var start: Int
    var end: Int
    var quote: String
    var note: String = ""
    var color: HighlightColor = .yellow
    var created: Date = Date()

    var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

enum HighlightColor: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink
    var id: String { rawValue }
}

/// Where the reader's selection is, as reported by the page.
struct TextSelection: Equatable {
    var start: Int
    var end: Int
    var text: String
}

/// Every book's highlights and notes, one small JSON file per book. Nothing leaves the device.
@MainActor
final class AnnotationStore: ObservableObject {
    static let shared = AnnotationStore()

    private let root: URL
    private var cache: [String: [Annotation]] = [:]
    /// Bumped on every change so views can refresh.
    @Published private(set) var revision = 0

    init(root: URL? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Annotations", isDirectory: true)
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func file(_ bookID: String) -> URL {
        // Book ids are file names already; keep only safe characters anyway.
        let safe = bookID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        return root.appendingPathComponent(String(safe)).appendingPathExtension("json")
    }

    func annotations(for bookID: String) -> [Annotation] {
        if let cached = cache[bookID] { return cached }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = (try? Data(contentsOf: file(bookID))).flatMap { try? decoder.decode([Annotation].self, from: $0) } ?? []
        cache[bookID] = loaded
        return loaded
    }

    func add(_ annotation: Annotation, to bookID: String) {
        var list = annotations(for: bookID)
        list.append(annotation)
        save(list, bookID)
    }

    func update(_ annotation: Annotation, in bookID: String) {
        var list = annotations(for: bookID)
        guard let i = list.firstIndex(where: { $0.id == annotation.id }) else { return }
        list[i] = annotation
        save(list, bookID)
    }

    func delete(id: UUID, from bookID: String) {
        save(annotations(for: bookID).filter { $0.id != id }, bookID)
    }

    func deleteAll(for bookID: String) {
        cache[bookID] = nil
        try? FileManager.default.removeItem(at: file(bookID))
        revision += 1
    }

    private func save(_ list: [Annotation], _ bookID: String) {
        cache[bookID] = list
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(list) { try? data.write(to: file(bookID), options: .atomic) }
        revision += 1
    }
}

/// Turns highlights and notes into text a person can keep: Markdown with the book, chapter headings, quotes and notes.
enum AnnotationExport {
    /// Annotations in reading order: by chapter, then by position.
    static func ordered(_ list: [Annotation]) -> [Annotation] {
        list.sorted { ($0.chapterIndex, $0.start, $0.created) < ($1.chapterIndex, $1.start, $1.created) }
    }

    static func markdown(title: String, authors: String, annotations: [Annotation], chapterTitle: (Int) -> String,
                         heading: String, noteLabel: String) -> String {
        var out = "# \(heading): \(title)\n"
        if !authors.trimmingCharacters(in: .whitespaces).isEmpty { out += "\n*\(authors)*\n" }
        var current = -1
        for a in ordered(annotations) {
            if a.chapterIndex != current {
                current = a.chapterIndex
                out += "\n## \(chapterTitle(a.chapterIndex))\n"
            }
            let quote = a.quote.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            out += "\n> \(quote)\n"
            if a.hasNote {
                let note = a.note.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "\n**\(noteLabel):** \(note)\n"
            }
        }
        return out
    }
}
