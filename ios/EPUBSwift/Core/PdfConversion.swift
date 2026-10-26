import Foundation
import UIKit
import PDFKit
import CoreText

struct PdfOptions {
    var letter = false
    var margin: CGFloat = 54
    var fontSize: CGFloat = 12
    var chapterBreaks = true
    var includeCover = true
}

private final class PdfLayout {
    let ctx: UIGraphicsPDFRendererContext
    let page: CGSize
    let o: PdfOptions
    var y: CGFloat = 0
    var started = false
    var pendingBreak = false

    init(ctx: UIGraphicsPDFRendererContext, page: CGSize, options: PdfOptions) {
        self.ctx = ctx
        self.page = page
        self.o = options
    }

    var contentWidth: CGFloat { page.width - 2 * o.margin }
    var bottom: CGFloat { page.height - o.margin }

    func newPage() {
        ctx.beginPage()
        y = o.margin
        started = true
        pendingBreak = false
    }

    func ensurePage() {
        if !started || pendingBreak { newPage() }
    }

    func drawText(_ s: NSAttributedString) {
        guard s.length > 0 else { return }
        ensurePage()
        let framesetter = CTFramesetterCreateWithAttributedString(s)
        var loc = 0
        let total = s.length
        while loc < total {
            if y > bottom - 30 { newPage() }
            let avail = bottom - y
            let cg = ctx.cgContext
            cg.saveGState()
            cg.textMatrix = .identity
            cg.translateBy(x: 0, y: page.height)
            cg.scaleBy(x: 1, y: -1)
            let rect = CGRect(x: o.margin, y: page.height - bottom, width: contentWidth, height: avail)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: loc, length: 0), CGPath(rect: rect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length > 0 { CTFrameDraw(frame, cg) }
            cg.restoreGState()
            if visible.length == 0 {
                if y <= o.margin + 1 { loc += 1 } else { newPage() }
                continue
            }
            let size = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: loc, length: visible.length), nil,
                CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude), nil)
            y += ceil(size.height)
            loc += visible.length
            if loc < total { newPage() }
        }
    }

    func drawImage(_ image: UIImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        ensurePage()
        let maxW = contentWidth
        let maxH = page.height - 2 * o.margin
        let scale = min(maxW / image.size.width, maxH / image.size.height, 1)
        let w = image.size.width * scale
        let h = image.size.height * scale
        if y + h > bottom { newPage() }
        image.draw(in: CGRect(x: o.margin + (maxW - w) / 2, y: y, width: w, height: h))
        y += h + 10
    }
}

enum EpubToPdf {
    static func make(_ pkg: EpubPackage, options o: PdfOptions, progress: @escaping (Double) -> Void) throws -> Data {
        let chapters = EpubText.chapters(pkg) { progress($0 * 0.4) }
        guard chapters.contains(where: { !$0.blocks.isEmpty }) else { throw EpubError.noText }
        let page = o.letter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: pkg.displayTitle,
            kCGPDFContextAuthor as String: pkg.authors.joined(separator: ", "),
            kCGPDFContextCreator as String: "EPUBSwift"
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: page), format: format)
        let bodyFont = UIFont(name: "Georgia", size: o.fontSize) ?? UIFont.systemFont(ofSize: o.fontSize)

        func attributes(font: UIFont, rtl: Bool, spacing: CGFloat, indent: CGFloat = 0) -> [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
            style.alignment = rtl ? .right : .left
            style.paragraphSpacing = spacing
            style.lineSpacing = o.fontSize * 0.25
            if indent > 0 {
                if rtl { style.headIndent = 0; style.firstLineHeadIndent = 0; style.tailIndent = -indent } else { style.headIndent = indent; style.firstLineHeadIndent = indent - 12 }
            }
            return [.font: font, .paragraphStyle: style, .foregroundColor: UIColor.black]
        }

        let data = renderer.pdfData { ctx in
            let layout = PdfLayout(ctx: ctx, page: page, options: o)
            if o.includeCover, let cover = pkg.coverData(), let image = UIImage(data: cover) {
                layout.drawImage(image)
                layout.pendingBreak = true
            }
            for (ci, chapter) in chapters.enumerated() {
                progress(0.4 + 0.6 * Double(ci) / Double(max(1, chapters.count)))
                if o.chapterBreaks && ci > 0 && layout.started { layout.pendingBreak = true }
                let pending = NSMutableAttributedString()
                func flush() {
                    layout.drawText(pending)
                    pending.deleteCharacters(in: NSRange(location: 0, length: pending.length))
                }
                for block in chapter.blocks {
                    let rtl = EpubText.isArabicScript(block.text) || (pkg.rtl && !block.text.contains(where: { $0.isLetter && $0.isASCII }))
                    switch block.kind {
                    case .heading(let level):
                        let factors: [CGFloat] = [1.9, 1.6, 1.35, 1.2, 1.1, 1.0]
                        let size = o.fontSize * factors[min(5, max(0, level - 1))]
                        let font = UIFont.boldSystemFont(ofSize: size)
                        pending.append(NSAttributedString(string: block.text + "\n", attributes: attributes(font: font, rtl: rtl, spacing: size * 0.5)))
                    case .paragraph:
                        pending.append(NSAttributedString(string: block.text + "\n", attributes: attributes(font: bodyFont, rtl: rtl, spacing: o.fontSize * 0.6)))
                    case .listItem:
                        let text = rtl ? block.text + " \u{2022}\n" : "\u{2022} " + block.text + "\n"
                        pending.append(NSAttributedString(string: text, attributes: attributes(font: bodyFont, rtl: rtl, spacing: o.fontSize * 0.3, indent: 18)))
                    case .image:
                        guard let src = block.src, !src.hasPrefix("http"), !src.hasPrefix("data:") else { continue }
                        let path = EpubPath.resolve(base: EpubPath.dir(chapter.path), href: src)
                        if let d = try? pkg.archive.read(path), let image = UIImage(data: d) {
                            flush()
                            layout.drawImage(image)
                        }
                    }
                }
                flush()
            }
            if !layout.started { layout.newPage() }
        }
        progress(1)
        return data
    }
}

// MARK: - PDF to EPUB

struct PdfImportOptions {
    var title = ""
    var author = ""
    var language = ""
    var includeCover = true
    var pagesPerFallbackChapter = 10
}

enum PdfToEpub {
    private struct Line { var text: String; var size: CGFloat; var page: Int }
    private enum Item {
        case heading(Int, String, Int)
        case para(String, Int)
        var page: Int {
            switch self { case .heading(_, _, let p): return p; case .para(_, let p): return p }
        }
    }

    static func make(url: URL, options: PdfImportOptions, progress: @escaping (Double) -> Void) throws -> (Data, [String]) {
        guard let doc = PDFDocument(url: url) else { throw EpubError.failed(L("The file could not be opened.")) }
        if doc.isLocked { throw EpubError.failed(L("This PDF is password protected.")) }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { throw EpubError.noText }
        var notes: [String] = []

        // 1. Lines with font sizes, page by page.
        var pages: [[Line]] = []
        var chars = 0
        for i in 0..<pageCount {
            progress(0.5 * Double(i) / Double(pageCount))
            guard let page = doc.page(at: i) else { pages.append([]); continue }
            let attr = page.attributedString ?? NSAttributedString(string: page.string ?? "")
            let ns = attr.string as NSString
            var lines: [Line] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byLines) { sub, range, _, _ in
                let text = Html.collapse(sub ?? "")
                var size: CGFloat = 0
                if range.length > 0, let font = attr.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont { size = font.pointSize }
                lines.append(Line(text: text, size: size, page: i))
            }
            chars += lines.reduce(0) { $0 + $1.text.count }
            pages.append(lines)
        }
        if chars < 20 * pageCount { throw EpubError.scanned }

        // 2. Drop running headers, footers and page numbers.
        var counts: [String: Int] = [:]
        func key(_ s: String) -> String { String(s.map { $0.isNumber ? "#" : $0 }) }
        for lines in pages {
            let nonEmpty = lines.filter { !$0.text.isEmpty }
            for l in [nonEmpty.first, nonEmpty.last].compactMap({ $0 }) { counts[key(l.text), default: 0] += 1 }
        }
        let repeatThreshold = max(3, Int(Double(pageCount) * 0.4))
        pages = pages.map { lines in
            let nonEmpty = lines.filter { !$0.text.isEmpty }
            let edgeTexts = Set([nonEmpty.first?.text, nonEmpty.last?.text].compactMap { $0 })
            return lines.filter { l in
                guard edgeTexts.contains(l.text), !l.text.isEmpty else { return true }
                if pageCount >= 4 && (counts[key(l.text)] ?? 0) >= repeatThreshold { return false }
                if l.text.count <= 4 && l.text.allSatisfy({ $0.isNumber }) { return false }
                return true
            }
        }

        // 3. Typical sizes.
        let allLines = pages.flatMap { $0 }.filter { !$0.text.isEmpty && $0.size > 0 }
        let sizes = allLines.map { $0.size }.sorted()
        let median = sizes.isEmpty ? 12 : sizes[sizes.count / 2]
        let lengths = allLines.map { $0.text.count }.sorted()
        let typical = max(20, lengths.isEmpty ? 60 : lengths[Int(Double(lengths.count) * 0.75)])
        let sample = allLines.prefix(200).map { $0.text }.joined(separator: " ")
        let rtl = EpubText.isArabicScript(sample)
        let language = options.language.isEmpty ? (rtl ? "ar" : "en") : options.language

        // 4. Items.
        var items: [Item] = []
        var para = ""
        var paraPage = 0
        var lastLen = 0
        var lastWasHeading = false
        func flushPara() {
            if !para.isEmpty { items.append(.para(para, paraPage)) }
            para = ""
        }
        for (pi, lines) in pages.enumerated() {
            progress(0.5 + 0.2 * Double(pi) / Double(pageCount))
            for l in lines {
                if l.text.isEmpty { flushPara(); lastWasHeading = false; continue }
                let ratio = median > 0 && l.size > 0 ? l.size / median : 1
                if ratio >= 1.25 && l.text.count < 140 {
                    flushPara()
                    let level = ratio >= 1.6 ? 1 : (ratio >= 1.4 ? 2 : 3)
                    if lastWasHeading, case .heading(let lv, let t, let p)? = items.last, lv == level {
                        items[items.count - 1] = .heading(lv, t + " " + l.text, p)
                    } else {
                        items.append(.heading(level, l.text, l.page))
                    }
                    lastWasHeading = true
                    continue
                }
                lastWasHeading = false
                let ends = ".!?:;\"\u{201D}\u{2019})\u{00BB}\u{061F}\u{06D4}".contains(para.last ?? "x")
                if !para.isEmpty && ends && lastLen < Int(Double(typical) * 0.7) { flushPara() }
                if para.isEmpty { paraPage = l.page; para = l.text } else { append(&para, l.text) }
                lastLen = l.text.count
            }
        }
        flushPara()
        guard !items.isEmpty else { throw EpubError.noText }

        // 5. Chapters.
        struct Chapter { var title: String; var items: [Item] }
        func split(_ maxLevel: Int) -> [Chapter] {
            var chapters: [Chapter] = []
            for it in items {
                if case .heading(let level, let text, _) = it, level <= maxLevel {
                    chapters.append(Chapter(title: text, items: [it]))
                } else {
                    if chapters.isEmpty { chapters.append(Chapter(title: "", items: [])) }
                    chapters[chapters.count - 1].items.append(it)
                }
            }
            return chapters.filter { !$0.items.isEmpty }
        }
        var chapters = split(1)
        if chapters.filter({ !$0.title.isEmpty }).count < 2 { chapters = split(2) }
        if chapters.filter({ !$0.title.isEmpty }).count < 2 { chapters = split(3) }
        if chapters.filter({ !$0.title.isEmpty }).count < 2 {
            let n = max(1, options.pagesPerFallbackChapter)
            var grouped: [Int: [Item]] = [:]
            for it in items { grouped[it.page / n, default: []].append(it) }
            chapters = grouped.keys.sorted().enumerated().map { i, k in
                Chapter(title: String(format: L("Part %d"), i + 1), items: grouped[k] ?? [])
            }
            notes.append(String(format: L("The PDF has no recognizable headings, so it was divided into sections of %d pages."), n))
        }
        chapters = chapters.enumerated().map { i, c in
            var c = c
            if c.title.isEmpty { c.title = i == 0 ? L("Beginning") : String(format: L("Section %d"), i + 1) }
            return c
        }

        // 6. Write.
        func attribute(_ key: PDFDocumentAttribute) -> String {
            (doc.documentAttributes?[key] as? String) ?? ""
        }
        let title = !options.title.isEmpty ? options.title
            : (!attribute(.titleAttribute).isEmpty ? attribute(.titleAttribute) : url.deletingPathExtension().lastPathComponent)
        let author = !options.author.isEmpty ? options.author : attribute(.authorAttribute)
        var built: [EpubBuilder.Chapter] = []
        for c in chapters {
            var body = ""
            for it in c.items {
                switch it {
                case .heading(let level, let text, _):
                    body += "<h\(level)>\(Xhtml.escape(Xhtml.clean(text)))</h\(level)>\n"
                case .para(let text, _):
                    body += "<p>\(Xhtml.escape(Xhtml.clean(text)))</p>\n"
                }
            }
            var startsWithHeading = false
            if let firstItem = c.items.first, case .heading = firstItem { startsWithHeading = true }
            if !startsWithHeading { body = "<h2>\(Xhtml.escape(Xhtml.clean(c.title)))</h2>\n" + body }
            built.append(EpubBuilder.Chapter(title: c.title, body: body))
        }
        var cover: Data?
        if options.includeCover, let first = doc.page(at: 0) {
            cover = first.thumbnail(of: CGSize(width: 900, height: 1200), for: .mediaBox).jpegData(compressionQuality: 0.85)
        }
        let builder = EpubBuilder(title: title, author: author, language: language, rtl: rtl,
                                  chapters: built, images: [], coverJPEG: cover, notice: nil)
        progress(1)
        notes.append(L("Complex layouts (tables, sidebars, footnotes) are flattened into reading order."))
        return (builder.build(), notes)
    }

    private static func append(_ s: inout String, _ text: String) {
        guard let last = s.last else { s = text; return }
        let first = text.first
        let hyphen = last == "-" && s.count >= 2 && s[s.index(s.endIndex, offsetBy: -2)].isLetter
            && first != nil && first!.isLowercase && !EpubText.isArabicScript(String(first!))
        if hyphen { s.removeLast(); s += text } else { s += " " + text }
    }
}
