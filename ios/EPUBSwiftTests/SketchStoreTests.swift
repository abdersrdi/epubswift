import XCTest

@MainActor
final class SketchStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sketches-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func note(_ chapter: Int, _ fraction: Double) -> SketchNote {
        SketchNote(chapterIndex: chapter, chapterPath: "ch\(chapter).xhtml", fraction: fraction)
    }

    func testAddReadBackAndPersistAcrossLaunches() {
        let store = SketchStore(root: dir)
        let n = note(1, 0.4)
        XCTAssertTrue(store.add(n, drawing: Data([1, 2, 3]), backdrop: Data([9, 9]), to: "book"))
        XCTAssertEqual(store.drawingData(n.id, book: "book"), Data([1, 2, 3]))
        XCTAssertEqual(store.backdropData(n.id, book: "book"), Data([9, 9]))

        let reopened = SketchStore(root: dir)
        XCTAssertEqual(reopened.sketches(for: "book").map(\.id), [n.id])
        XCTAssertEqual(reopened.drawingData(n.id, book: "book"), Data([1, 2, 3]))
        XCTAssertEqual(reopened.sketches(for: "other").count, 0, "books are kept apart")
    }

    func testSketchesComeInReadingOrder() {
        let store = SketchStore(root: dir)
        let late = note(3, 0.1), early = note(0, 0.9), mid = note(3, 0.0)
        for n in [late, early, mid] { store.add(n, drawing: Data([1]), backdrop: Data([1]), to: "b") }
        XCTAssertEqual(SketchStore(root: dir).sketches(for: "b").map(\.id), [early.id, mid.id, late.id])
    }

    func testUpdateReplacesOnlyTheDrawing() {
        let store = SketchStore(root: dir)
        let n = note(0, 0.5)
        store.add(n, drawing: Data([1]), backdrop: Data([7]), to: "b")
        XCTAssertTrue(store.update(n, drawing: Data([2, 2]), in: "b"))
        XCTAssertEqual(store.drawingData(n.id, book: "b"), Data([2, 2]))
        XCTAssertEqual(store.backdropData(n.id, book: "b"), Data([7]))
        XCTAssertFalse(store.update(note(5, 0), drawing: Data([1]), in: "b"), "an unknown sketch is not created by an update")
    }

    func testDeleteRemovesFilesAndEntry() {
        let store = SketchStore(root: dir)
        let a = note(0, 0.1), b = note(1, 0.2)
        store.add(a, drawing: Data([1]), backdrop: Data([1]), to: "b")
        store.add(b, drawing: Data([1]), backdrop: Data([1]), to: "b")
        store.delete(id: a.id, from: "b")
        XCTAssertNil(store.drawingData(a.id, book: "b"))
        XCTAssertNil(store.backdropData(a.id, book: "b"))
        XCTAssertEqual(SketchStore(root: dir).sketches(for: "b").map(\.id), [b.id])
        store.deleteAll(for: "b")
        XCTAssertEqual(SketchStore(root: dir).sketches(for: "b").count, 0)
    }

    func testUnsafeBookIDsStayInsideTheFolder() {
        let store = SketchStore(root: dir)
        XCTAssertTrue(store.add(note(0, 0), drawing: Data([1]), backdrop: Data([1]), to: "../../escape"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape").path))
        XCTAssertEqual(store.sketches(for: "../../escape").count, 1)
    }

    func testDamagedIndexMeansNoSketchesNotACrash() throws {
        let store = SketchStore(root: dir)
        store.add(note(0, 0), drawing: Data([1]), backdrop: Data([1]), to: "b")
        for sub in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try Data("nope".utf8).write(to: dir.appendingPathComponent(sub).appendingPathComponent("index.json"))
        }
        XCTAssertEqual(SketchStore(root: dir).sketches(for: "b").count, 0)
    }
}
