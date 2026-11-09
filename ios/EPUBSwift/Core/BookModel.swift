import Foundation

/// One piece of a chapter in the Book Maker. Kept deliberately simple so a first-time author can use it on a phone.
enum BookBlock: Codable, Equatable {
    /// Text. Every line is its own paragraph, so pressing Return starts a new paragraph, as people expect.
    case text(String)
    case heading(String)
    /// A picture. The pixels are kept apart from the book's text, under this id.
    case image(id: String, caption: String)
}

struct BookChapter: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var blocks: [BookBlock] = []
}

/// A book being written. Plain data, saved as JSON next to its pictures.
struct BookProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var author: String = ""
    /// A language code such as "en" or "ar". Arabic, Hebrew, Persian and Urdu are written right to left.
    var language: String = "en"
    var chapters: [BookChapter] = []
    var coverImageID: String?
    var modified = Date()

    var rtl: Bool { ["ar", "he", "fa", "ur"].contains(language) }

    /// A new book with one empty chapter, so there is somewhere to start typing.
    static func blank(title: String = "", language: String = "en") -> BookProject {
        BookProject(title: title, language: language, chapters: [BookChapter(title: "", blocks: [.text("")])])
    }

    /// Paragraphs of a text block: one per non-empty line.
    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var wordCount: Int {
        var n = 0
        for c in chapters {
            for b in c.blocks {
                switch b {
                case .text(let t): n += t.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                case .heading(let t): n += t.split(whereSeparator: { $0.isWhitespace }).count
                case .image: break
                }
            }
        }
        return n
    }

    /// Every picture id the book uses, the cover first, once each.
    var imageIDs: [String] {
        var seen = Set<String>(), out: [String] = []
        func add(_ id: String) { if seen.insert(id).inserted { out.append(id) } }
        if let cover = coverImageID { add(cover) }
        for c in chapters { for b in c.blocks { if case .image(let id, _) = b { add(id) } } }
        return out
    }

    /// The title to print: a book without one is called "Untitled".
    var displayTitle: String { title.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : title.trimmingCharacters(in: .whitespaces) }

    func chapterTitle(_ index: Int) -> String {
        let t = chapters[index].title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Chapter \(index + 1)" : t
    }
}

/// What the free plan allows: five book exports a month, with a small "Made with EPUBSwift" note at the end. Watching one video
/// removes the note from one export; watching three videos earns one more export. Premium has no limits and no note.
struct BookExportQuota: Codable, Equatable {
    static let freePerMonth = 5
    static let videosPerExtraExport = 3

    private(set) var month: String
    /// Exports made this month from the free allowance.
    private(set) var used: Int
    /// Extra exports earned with videos. They carry over from month to month until used.
    private(set) var bonus: Int
    /// Videos watched towards the next extra export (0, 1 or 2).
    private(set) var videosTowardExtra: Int
    /// Videos watched to remove the note from one export each, kept until used.
    private(set) var cleanExports: Int

    init(month: String, used: Int = 0, bonus: Int = 0, videosTowardExtra: Int = 0, cleanExports: Int = 0) {
        self.month = month; self.used = used; self.bonus = bonus
        self.videosTowardExtra = videosTowardExtra; self.cleanExports = cleanExports
    }

    /// A new month starts the free allowance again. Earned extras and clean exports stay.
    mutating func roll(to newMonth: String) {
        if newMonth != month { month = newMonth; used = 0 }
    }

    var remaining: Int { max(0, Self.freePerMonth - used) + bonus }

    func canExport(isPremium: Bool) -> Bool { isPremium || remaining > 0 }

    func shouldWatermark(isPremium: Bool) -> Bool { !isPremium && cleanExports == 0 }

    /// A watched video that removes the note from one export.
    mutating func earnCleanExport() { cleanExports += 1 }

    /// A watched video towards an extra export. Returns true when this one completed the set of three and earned the export.
    @discardableResult
    mutating func watchVideoForExtraExport() -> Bool {
        videosTowardExtra += 1
        guard videosTowardExtra >= Self.videosPerExtraExport else { return false }
        videosTowardExtra = 0
        bonus += 1
        return true
    }

    /// Counts one export. The free allowance is used first, then earned extras; a clean export is used up if one was earned.
    /// Premium exports are not counted.
    mutating func record(isPremium: Bool) {
        guard !isPremium else { return }
        if used < Self.freePerMonth { used += 1 } else if bonus > 0 { bonus -= 1 }
        if cleanExports > 0 { cleanExports -= 1 }
    }

    /// "2026-11" for a date, in UTC so every device agrees on when the month turns.
    static func monthKey(for date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}
