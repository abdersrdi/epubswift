import UIKit
import XCTest

final class BookMakerTests: XCTestCase {
    // MARK: Helpers

    private func jpeg(_ w: Int, _ h: Int) -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }())
        let image = renderer.image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func sample(language: String = "en") -> (BookProject, [String: Data]) {
        var book = BookProject(title: "My <First> Book & Co", author: "Sam Writer", language: language)
        book.coverImageID = "cover"
        book.chapters = [
            BookChapter(title: "Beginnings", blocks: [.text("First paragraph.\nSecond paragraph.\n\n  \nThird & last."), .heading("A heading"),
                                                     .image(id: "pic1", caption: "A \"quoted\" caption")]),
            BookChapter(title: "", blocks: [.text("Only text here.")]),
        ]
        return (book, ["cover": jpeg(300, 450), "pic1": jpeg(800, 600)])
    }

    private final class WellFormed: NSObject, XMLParserDelegate {
        var error: Error?
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { error = parseError }
    }

    private func assertWellFormed(_ data: Data, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let parser = XMLParser(data: data)
        let d = WellFormed()
        parser.delegate = d
        XCTAssertTrue(parser.parse(), "\(name) is not well-formed XML: \(String(describing: d.error))", file: file, line: line)
    }

    // MARK: Model

    func testParagraphsAreOnePerNonEmptyLine() {
        XCTAssertEqual(BookProject.paragraphs("a\n\n  b  \r\nc\n"), ["a", "b", "c"])
        XCTAssertEqual(BookProject.paragraphs("   \n\n"), [])
    }

    func testWordCountExact() {
        let (book, _) = sample()
        // "First paragraph." 2, "Second paragraph." 2, "Third & last." 3, heading 2, "Only text here." 3
        XCTAssertEqual(book.wordCount, 12)
        XCTAssertEqual(book.imageIDs, ["cover", "pic1"])
        XCTAssertEqual(book.chapterTitle(0), "Beginnings")
        XCTAssertEqual(book.chapterTitle(1), "Chapter 2")
        XCTAssertEqual(BookProject(title: "  ").displayTitle, "Untitled")
    }

    func testRightToLeftLanguages() {
        XCTAssertTrue(BookProject(title: "x", language: "ar").rtl)
        XCTAssertFalse(BookProject(title: "x", language: "en").rtl)
    }

    func testBookRoundTripsThroughJSON() throws {
        let (book, _) = sample()
        let back = try JSONDecoder().decode(BookProject.self, from: try JSONEncoder().encode(book))
        XCTAssertEqual(back, book)
    }

    // MARK: TXT

    func testTxtHasTitleChaptersParagraphsAndTheNoteOnlyWhenAsked() {
        let (book, _) = sample()
        let clean = String(decoding: BookExporter.txt(book, watermark: nil), as: UTF8.self)
        XCTAssertTrue(clean.hasPrefix("My <First> Book & Co\nSam Writer\n"))
        XCTAssertTrue(clean.contains("\nBeginnings\n"))
        XCTAssertTrue(clean.contains("\nSecond paragraph.\n"))
        XCTAssertTrue(clean.contains("\nChapter 2\n"))
        XCTAssertTrue(clean.contains("[Image: A \"quoted\" caption]"))
        XCTAssertFalse(clean.contains("Made with EPUBSwift"))
        let marked = String(decoding: BookExporter.txt(book, watermark: BookExporter.watermarkText), as: UTF8.self)
        XCTAssertTrue(marked.hasSuffix("— Made with EPUBSwift —\n"))
    }

    // MARK: EPUB

    func testEpubIsAValidPackageWithCoverChaptersImagesAndOptionalNote() throws {
        let (book, images) = sample()
        let data = BookExporter.epub(book, images: images, watermark: BookExporter.watermarkText)
        let zip = try ZipArchive(data: data)
        XCTAssertEqual(zip.entries.first?.name, "mimetype")
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/images/cover.jpg",
                     "OEBPS/images/img-001.jpg", "OEBPS/text/chapter-001.xhtml", "OEBPS/text/chapter-002.xhtml",
                     "OEBPS/text/chapter-003.xhtml", "OEBPS/notice.xhtml"] {
            XCTAssertTrue(zip.has(name), "missing \(name)")
        }
        for name in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/toc.ncx", "OEBPS/text/chapter-001.xhtml",
                     "OEBPS/text/chapter-002.xhtml", "OEBPS/text/chapter-003.xhtml", "OEBPS/notice.xhtml"] {
            assertWellFormed(try zip.read(name), name)
        }
        let opf = String(decoding: try zip.read("OEBPS/content.opf"), as: UTF8.self)
        XCTAssertTrue(opf.contains("<dc:title>My &lt;First&gt; Book &amp; Co</dc:title>"))
        XCTAssertTrue(opf.contains("<dc:creator>Sam Writer</dc:creator>"))
        XCTAssertTrue(opf.contains("<dc:language>en</dc:language>"))
        let chapter = String(decoding: try zip.read("OEBPS/text/chapter-002.xhtml"), as: UTF8.self)
        XCTAssertTrue(chapter.contains("<h1>Beginnings</h1>"))
        XCTAssertTrue(chapter.contains("<p>Third &amp; last.</p>"))
        XCTAssertTrue(chapter.contains("<h2>A heading</h2>"))
        XCTAssertTrue(chapter.contains("src=\"../images/img-001.jpg\""))
        XCTAssertTrue(chapter.contains("alt=\"A &quot;quoted&quot; caption\""))
        XCTAssertTrue(String(decoding: try zip.read("OEBPS/text/chapter-003.xhtml"), as: UTF8.self).contains("<h1>Chapter 2</h1>"))
        XCTAssertTrue(String(decoding: try zip.read("OEBPS/notice.xhtml"), as: UTF8.self).contains("Made with EPUBSwift"))

        let clean = try ZipArchive(data: BookExporter.epub(book, images: images, watermark: nil))
        XCTAssertFalse(clean.has("OEBPS/notice.xhtml"))
    }

    func testArabicEpubIsRightToLeft() throws {
        var (book, images) = sample(language: "ar")
        book.title = "كتابي الأول"
        book.chapters[0].blocks = [.text("فقرة أولى.\nفقرة ثانية.")]
        images = [:]
        let zip = try ZipArchive(data: BookExporter.epub(book, images: images, watermark: nil))
        XCTAssertTrue(String(decoding: try zip.read("OEBPS/content.opf"), as: UTF8.self).contains("page-progression-direction=\"rtl\""))
        let ch = String(decoding: try zip.read("OEBPS/text/chapter-002.xhtml"), as: UTF8.self)
        XCTAssertTrue(ch.contains("dir=\"rtl\""))
        XCTAssertTrue(ch.contains("<p>فقرة أولى.</p>"))
    }

    func testEmptyBookStillMakesAReadableEpub() throws {
        let zip = try ZipArchive(data: BookExporter.epub(BookProject.blank(), images: [:], watermark: nil))
        XCTAssertTrue(zip.has("OEBPS/text/chapter-001.xhtml"))
        assertWellFormed(try zip.read("OEBPS/text/chapter-002.xhtml"), "chapter 2")
    }

    // MARK: Word

    func testJpegSizeReadsTheHeader() {
        let s = BookExporter.jpegSize(jpeg(321, 123))
        XCTAssertEqual(s?.width, 321)
        XCTAssertEqual(s?.height, 123)
        XCTAssertNil(BookExporter.jpegSize(Data([1, 2, 3, 4, 5])))
        XCTAssertNil(BookExporter.jpegSize(Data()))
    }

    func testDocxHasTheRequiredPartsAndEveryRelationshipPointsToAPart() throws {
        let (book, images) = sample()
        let data = BookExporter.docx(book, images: images, watermark: BookExporter.watermarkText)
        let zip = try ZipArchive(data: data)
        XCTAssertEqual(zip.entries.first?.name, "[Content_Types].xml")
        for name in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/_rels/document.xml.rels",
                     "docProps/core.xml", "word/media/image1.jpg", "word/media/image2.jpg"] {
            XCTAssertTrue(zip.has(name), "missing \(name)")
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") { assertWellFormed(try zip.read(name), name) }
        }
        let doc = String(decoding: try zip.read("word/document.xml"), as: UTF8.self)
        let rels = String(decoding: try zip.read("word/_rels/document.xml.rels"), as: UTF8.self)
        // every picture reference in the document has a relationship, and every relationship target exists
        let embeds = doc.components(separatedBy: "r:embed=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
        XCTAssertEqual(embeds.count, 2)
        for id in embeds { XCTAssertTrue(rels.contains("Id=\"\(id)\""), "no relationship \(id)") }
        XCTAssertTrue(rels.contains("Target=\"media/image1.jpg\""))
        XCTAssertTrue(rels.contains("Target=\"media/image2.jpg\""))

        XCTAssertTrue(doc.contains("<w:pStyle w:val=\"Title\"/>"))
        XCTAssertTrue(doc.contains("My &lt;First&gt; Book &amp; Co"))
        XCTAssertTrue(doc.contains("<w:pStyle w:val=\"Heading1\"/><w:pageBreakBefore/>"))
        XCTAssertTrue(doc.contains(">Third &amp; last.<"))
        XCTAssertTrue(doc.contains("Chapter 2"))
        XCTAssertTrue(doc.contains("— Made with EPUBSwift —"))
        XCTAssertFalse(doc.contains("<w:bidi/><w:jc"), "an English book is not right to left")
    }

    func testDocxPicturesKeepTheirProportionsAndFitThePage() throws {
        let (book, images) = sample()
        let zip = try ZipArchive(data: BookExporter.docx(book, images: images, watermark: nil))
        let doc = String(decoding: try zip.read("word/document.xml"), as: UTF8.self)
        var extents: [(Int, Int)] = []
        for part in doc.components(separatedBy: "<wp:extent cx=\"").dropFirst() {
            let cx = Int(part.prefix { $0 != "\"" })!
            let cy = Int(part.components(separatedBy: "cy=\"")[1].prefix { $0 != "\"" })!
            extents.append((cx, cy))
        }
        XCTAssertEqual(extents.count, 2)
        XCTAssertEqual(Double(extents[0].0) / Double(extents[0].1), 300.0 / 450.0, accuracy: 0.01)     // the cover
        XCTAssertEqual(Double(extents[1].0) / Double(extents[1].1), 800.0 / 600.0, accuracy: 0.01)
        for (w, h) in extents { XCTAssertLessThanOrEqual(w, 5_486_400); XCTAssertLessThanOrEqual(h, 6_400_800) }
        XCTAssertFalse(doc.contains("Made with EPUBSwift"))
    }

    func testArabicDocxIsRightToLeft() throws {
        var book = BookProject(title: "كتابي", author: "كاتب", language: "ar")
        book.chapters = [BookChapter(title: "البداية", blocks: [.text("نص عربي.")])]
        let zip = try ZipArchive(data: BookExporter.docx(book, images: [:], watermark: nil))
        let doc = String(decoding: try zip.read("word/document.xml"), as: UTF8.self)
        XCTAssertTrue(doc.contains("<w:bidi/>"))
        XCTAssertTrue(doc.contains("<w:rtl/>"))
        XCTAssertTrue(doc.contains("نص عربي."))
        assertWellFormed(try zip.read("word/document.xml"), "document.xml")
    }

    // MARK: Quota

    func testFiveFreeExportsThenNone() {
        var q = BookExportQuota(month: "2026-11")
        for i in 1...5 {
            XCTAssertTrue(q.canExport(isPremium: false), "export \(i)")
            q.record(isPremium: false)
        }
        XCTAssertEqual(q.remaining, 0)
        XCTAssertFalse(q.canExport(isPremium: false))
        XCTAssertTrue(q.canExport(isPremium: true))
    }

    func testThreeVideosEarnOneMoreExport() {
        var q = BookExportQuota(month: "2026-11", used: 5)
        XCTAssertFalse(q.watchVideoForExtraExport())
        XCTAssertFalse(q.watchVideoForExtraExport())
        XCTAssertEqual(q.remaining, 0)
        XCTAssertTrue(q.watchVideoForExtraExport(), "the third video earns the export")
        XCTAssertEqual(q.remaining, 1)
        XCTAssertEqual(q.videosTowardExtra, 0)
        q.record(isPremium: false)
        XCTAssertEqual(q.remaining, 0)
        XCTAssertFalse(q.canExport(isPremium: false))
        // the next set of three starts from zero
        XCTAssertFalse(q.watchVideoForExtraExport())
        XCTAssertEqual(q.videosTowardExtra, 1)
    }

    func testOneVideoRemovesTheNoteFromOneExportOnly() {
        var q = BookExportQuota(month: "2026-11")
        XCTAssertTrue(q.shouldWatermark(isPremium: false))
        XCTAssertFalse(q.shouldWatermark(isPremium: true))
        q.earnCleanExport()
        XCTAssertFalse(q.shouldWatermark(isPremium: false))
        q.record(isPremium: false)                                   // that export was clean
        XCTAssertTrue(q.shouldWatermark(isPremium: false))
        XCTAssertEqual(q.used, 1)
    }

    func testPremiumIsNotCountedAndNewMonthRefillsButKeepsEarnedThings() {
        var p = BookExportQuota(month: "2026-11", used: 5, cleanExports: 1)
        p.record(isPremium: true)
        XCTAssertEqual(p, BookExportQuota(month: "2026-11", used: 5, cleanExports: 1))

        var q = BookExportQuota(month: "2026-11", used: 5, bonus: 2, videosTowardExtra: 2, cleanExports: 3)
        q.roll(to: "2026-11")
        XCTAssertEqual(q.used, 5)
        q.roll(to: "2026-12")
        XCTAssertEqual(q.used, 0)
        XCTAssertEqual(q.bonus, 2)
        XCTAssertEqual(q.videosTowardExtra, 2)
        XCTAssertEqual(q.cleanExports, 3)
        XCTAssertEqual(q.remaining, 7)
    }

    func testFreeExportsAreSpentBeforeEarnedOnes() {
        var q = BookExportQuota(month: "2026-11", bonus: 2)
        q.record(isPremium: false)
        XCTAssertEqual(q.used, 1)
        XCTAssertEqual(q.bonus, 2)
    }

    func testMonthKeyUsesUTCAndQuotaStoresAsJSON() throws {
        XCTAssertEqual(BookExportQuota.monthKey(for: Date(timeIntervalSince1970: 1_793_491_199)), "2026-10")
        XCTAssertEqual(BookExportQuota.monthKey(for: Date(timeIntervalSince1970: 1_793_491_200)), "2026-11")
        let q = BookExportQuota(month: "2026-11", used: 3, bonus: 1, videosTowardExtra: 2, cleanExports: 1)
        XCTAssertEqual(try JSONDecoder().decode(BookExportQuota.self, from: try JSONEncoder().encode(q)), q)
    }
}
