import XCTest

@MainActor
final class AnnotationTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("annotations-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func note(_ chapter: Int, _ start: Int, _ quote: String, note: String = "", color: HighlightColor = .yellow) -> Annotation {
        Annotation(chapterIndex: chapter, chapterPath: "ch\(chapter).xhtml", start: start, end: start + quote.count, quote: quote, note: note, color: color)
    }

    func testAddUpdateDeleteAndPersistAcrossLaunches() {
        let store = AnnotationStore(root: dir)
        var a = note(0, 10, "first")
        store.add(a, to: "book1")
        store.add(note(2, 5, "second", note: "why?"), to: "book1")
        XCTAssertEqual(store.annotations(for: "book1").count, 2)
        XCTAssertEqual(store.annotations(for: "book2").count, 0, "books are kept apart")

        a.note = "changed"
        a.color = .pink
        store.update(a, in: "book1")

        let reopened = AnnotationStore(root: dir)                     // a new launch
        let loaded = reopened.annotations(for: "book1")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.id == a.id }?.note, "changed")
        XCTAssertEqual(loaded.first { $0.id == a.id }?.color, .pink)

        reopened.delete(id: a.id, from: "book1")
        XCTAssertEqual(AnnotationStore(root: dir).annotations(for: "book1").map(\.quote), ["second"])
        reopened.deleteAll(for: "book1")
        XCTAssertEqual(AnnotationStore(root: dir).annotations(for: "book1").count, 0)
    }

    func testRevisionChangesOnEveryEdit() {
        let store = AnnotationStore(root: dir)
        let r0 = store.revision
        store.add(note(0, 1, "x"), to: "b")
        XCTAssertGreaterThan(store.revision, r0)
    }

    func testUnsafeBookIDsStayInsideTheFolder() {
        let store = AnnotationStore(root: dir)
        store.add(note(0, 1, "x"), to: "../../escape")
        XCTAssertEqual(store.annotations(for: "../../escape").count, 1)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(files.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape.json").path))
    }

    func testDamagedFileIsTreatedAsNoNotes() throws {
        let store = AnnotationStore(root: dir)
        store.add(note(0, 1, "x"), to: "b")
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try Data("not json".utf8).write(to: dir.appendingPathComponent(f))
        }
        XCTAssertEqual(AnnotationStore(root: dir).annotations(for: "b"), [])
    }

    func testHasNoteIgnoresWhitespace() {
        XCTAssertFalse(note(0, 0, "a", note: "  \n ").hasNote)
        XCTAssertTrue(note(0, 0, "a", note: "yes").hasNote)
    }

    func testMarkdownIsInReadingOrderWithChapterHeadings() {
        let list = [note(2, 40, "late quote", note: "mine"), note(0, 90, "second in chapter one"), note(0, 5, "first in chapter one")]
        let md = AnnotationExport.markdown(title: "Alice", authors: "L. Carroll", annotations: list,
                                           chapterTitle: { "Chapter \($0 + 1)" }, heading: "Notes", noteLabel: "Note")
        let expected = """
        # Notes: Alice

        *L. Carroll*

        ## Chapter 1

        > first in chapter one

        > second in chapter one

        ## Chapter 3

        > late quote

        **Note:** mine

        """
        XCTAssertEqual(md, expected)
    }

    func testMarkdownKeepsQuotesOnOneLineAndOmitsEmptyAuthor() {
        let md = AnnotationExport.markdown(title: "T", authors: " ", annotations: [note(0, 0, "line one\nline two")],
                                           chapterTitle: { _ in "C" }, heading: "H", noteLabel: "N")
        XCTAssertTrue(md.contains("> line one line two"))
        XCTAssertFalse(md.contains("**N:**"))
        XCTAssertFalse(md.contains("* *"))
    }

    func testAnnotationRoundTripsThroughJSON() throws {
        let a = note(3, 7, "quote", note: "n", color: .blue)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var back = try dec.decode(Annotation.self, from: try enc.encode(a))
        back.created = a.created                                       // ISO dates drop fractions of a second
        XCTAssertEqual(back, a)
    }
}
