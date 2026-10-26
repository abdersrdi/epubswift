import Foundation

struct TextChapter: Identifiable {
    var id: Int { index }
    var index: Int
    var title: String
    var path: String
    var blocks: [TextBlock]

    var text: String {
        blocks.compactMap { b -> String? in
            if case .image = b.kind { return nil }
            return b.text
        }.joined(separator: "\n\n")
    }
}

enum EpubText {
    static func chapters(_ pkg: EpubPackage, progress: ((Double) -> Void)? = nil) -> [TextChapter] {
        let paths = pkg.spinePaths
        var result: [TextChapter] = []
        for (i, path) in paths.enumerated() {
            progress?(Double(i) / Double(max(1, paths.count)))
            guard let data = try? pkg.archive.read(path) else { continue }
            let blocks = Html.blocks(Html.string(from: data))
            var title = ""
            for b in blocks {
                if case .heading = b.kind { title = b.text; break }
            }
            if title.isEmpty { title = pkg.toc.first { $0.path == path }?.title ?? "" }
            if title.isEmpty { title = String(format: L("Chapter %d"), i + 1) }
            result.append(TextChapter(index: i, title: title, path: path, blocks: blocks))
        }
        return result
    }

    /// Search folding: ignores case, Latin accents, Arabic diacritics and tatweel, and unifies alef forms.
    static func fold(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        t = t.replacingOccurrences(of: "\u{0640}", with: "")
        for a in ["\u{0623}", "\u{0625}", "\u{0622}"] { t = t.replacingOccurrences(of: a, with: "\u{0627}") }
        t = t.replacingOccurrences(of: "\u{0649}", with: "\u{064A}")
        return t
    }

    static func isArabicScript(_ s: String) -> Bool {
        var arabic = 0
        var latin = 0
        for u in s.unicodeScalars.prefix(200) {
            if (0x0590...0x08FF).contains(u.value) || (0xFB50...0xFEFF).contains(u.value) { arabic += 1 }
            else if u.properties.isAlphabetic { latin += 1 }
        }
        return arabic > latin
    }

    /// Plain-text export of a chapter list.
    static func plainText(_ chapters: [TextChapter]) -> String {
        chapters.map { "\($0.title)\n\n\($0.text)" }.joined(separator: "\n\n\n")
    }
}
