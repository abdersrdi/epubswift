import UIKit
import XCTest

@MainActor
final class BookStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bookstore-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func picture(_ w: Int, _ h: Int, alpha: Bool = false) -> Data {
        let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = !alpha
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { ctx in
            if !alpha { UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
            else { UIColor.green.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h)) }   // right half stays transparent
        }
        return alpha ? image.pngData()! : image.jpegData(compressionQuality: 0.9)!
    }

    func testCreateSaveReloadAndDelete() {
        let store = BookStore(root: dir)
        var book = store.create(language: "ar")
        XCTAssertEqual(store.books.count, 1)
        XCTAssertEqual(book.language, "ar")
        XCTAssertEqual(book.chapters.count, 1, "a new book has somewhere to start typing")

        book.title = "Saved"
        book.chapters[0].blocks = [.text("hello")]
        store.save(book)

        let reopened = BookStore(root: dir)                              // a new launch
        XCTAssertEqual(reopened.books.map(\.title), ["Saved"])
        XCTAssertEqual(reopened.book(book.id)?.chapters.first?.blocks, [.text("hello")])

        reopened.delete(book.id)
        XCTAssertTrue(reopened.books.isEmpty)
        XCTAssertTrue(BookStore(root: dir).books.isEmpty)
    }

    func testMostRecentlySavedBookComesFirst() throws {
        let store = BookStore(root: dir)
        var a = store.create(); a.title = "A"; store.save(a)
        Thread.sleep(forTimeInterval: 1.1)                               // dates are stored to the second
        var b = store.create(); b.title = "B"; store.save(b)
        XCTAssertEqual(BookStore(root: dir).books.map(\.title), ["B", "A"])
    }

    func testPicturesAreScaledDownStoredAndReadBack() throws {
        let store = BookStore(root: dir)
        let book = store.create()
        let id = try XCTUnwrap(store.addImage(picture(3000, 1500), to: book.id))
        let data = try XCTUnwrap(store.imageData(id, book: book.id))
        let size = try XCTUnwrap(BookExporter.jpegSize(data))
        XCTAssertEqual(max(size.width, size.height), ImagePrep.maxSide)
        XCTAssertEqual(Double(size.width) / Double(size.height), 2.0, accuracy: 0.02)
        XCTAssertNotNil(store.thumbnail(id, book: book.id))
    }

    func testSmallPicturesAreNotEnlargedAndNonPicturesAreRefused() throws {
        let store = BookStore(root: dir)
        let book = store.create()
        let id = try XCTUnwrap(store.addImage(picture(200, 100), to: book.id))
        let size = try XCTUnwrap(BookExporter.jpegSize(try XCTUnwrap(store.imageData(id, book: book.id))))
        XCTAssertEqual(size.width, 200)
        XCTAssertNil(store.addImage(Data("not a picture".utf8), to: book.id))
    }

    func testTransparentPicturesBecomeWhiteNotBlack() throws {
        let jpeg = try XCTUnwrap(ImagePrep.jpeg(from: picture(40, 40, alpha: true)))
        let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage)
        let px = try XCTUnwrap(image.dataProvider?.data)
        let bytes = CFDataGetBytePtr(px)!
        let bytesPerPixel = image.bitsPerPixel / 8
        let row = image.bytesPerRow
        let offset = 20 * row + 35 * bytesPerPixel                       // inside the transparent right half
        XCTAssertGreaterThan(Int(bytes[offset]), 230, "background should be white")
    }

    func testPicturesNoLongerUsedAreRemovedFromDisk() throws {
        let store = BookStore(root: dir)
        var book = store.create()
        let keep = try XCTUnwrap(store.addImage(picture(50, 50), to: book.id))
        let drop = try XCTUnwrap(store.addImage(picture(50, 50), to: book.id))
        book.chapters[0].blocks = [.image(id: keep, caption: ""), .image(id: drop, caption: "")]
        store.save(book)
        XCTAssertNotNil(store.imageData(drop, book: book.id))

        book.chapters[0].blocks = [.image(id: keep, caption: "")]
        store.save(book)
        XCTAssertNotNil(store.imageData(keep, book: book.id))
        XCTAssertNil(store.imageData(drop, book: book.id))
        XCTAssertEqual(Set(store.images(for: book).keys), [keep])
    }

    func testDamagedBookFileIsSkippedNotFatal() throws {
        let store = BookStore(root: dir)
        let good = store.create()
        let bad = dir.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ nope".utf8).write(to: bad.appendingPathComponent("book.json"))
        XCTAssertEqual(BookStore(root: dir).books.map(\.id), [good.id])
    }
}
