import Foundation
import ImageIO
import UIKit

/// Turns any picture the person picks into a JPEG that is small enough to edit comfortably and large enough to print.
enum ImagePrep {
    /// The longest side kept, in pixels. A 2000 px picture fills a 6 inch wide page at about 330 DPI.
    static let maxSide = 2000

    static func jpeg(from data: Data, maxSide: Int = ImagePrep.maxSide, quality: CGFloat = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Draw on white so transparent pictures (PNG) do not turn black in a JPEG.
        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: quality)
    }
}

/// The books the person is writing. Each book is a folder with `book.json` and an `images` folder, kept in the app's own storage.
@MainActor
final class BookStore: ObservableObject {
    static let shared = BookStore()

    @Published private(set) var books: [BookProject] = []
    private let root: URL
    private let thumbnails = NSCache<NSString, UIImage>()

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BookMaker", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        load()
    }

    private func folder(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func imagesFolder(_ id: UUID) -> URL { folder(id).appendingPathComponent("images", isDirectory: true) }
    private func imageFile(_ imageID: String, _ book: UUID) -> URL {
        let safe = imageID.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return imagesFolder(book).appendingPathComponent(safe + ".jpg")
    }

    private static func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }

    func load() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        var found: [BookProject] = []
        for name in names {
            let file = root.appendingPathComponent(name).appendingPathComponent("book.json")
            guard let data = try? Data(contentsOf: file), let book = try? Self.decoder().decode(BookProject.self, from: data) else { continue }
            found.append(book)
        }
        books = found.sorted { $0.modified > $1.modified }
    }

    func book(_ id: UUID) -> BookProject? { books.first { $0.id == id } }

    @discardableResult
    func create(language: String = "en") -> BookProject {
        let book = BookProject.blank(language: language)
        save(book)
        return book
    }

    /// Writes the book (the write is atomic, so a crash never leaves half a book) and moves it to the top of the list.
    func save(_ book: BookProject) {
        var b = book
        b.modified = Date()
        try? FileManager.default.createDirectory(at: imagesFolder(b.id), withIntermediateDirectories: true)
        if let data = try? Self.encoder().encode(b) {
            try? data.write(to: folder(b.id).appendingPathComponent("book.json"), options: .atomic)
        }
        books.removeAll { $0.id == b.id }
        books.insert(b, at: 0)
        removeUnusedImages(of: b)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        books.removeAll { $0.id == id }
    }

    // MARK: Pictures

    /// Stores a picture for a book (scaled down, as JPEG) and returns its id.
    func addImage(_ data: Data, to bookID: UUID) -> String? {
        guard let jpeg = ImagePrep.jpeg(from: data) else { return nil }
        let id = UUID().uuidString
        try? FileManager.default.createDirectory(at: imagesFolder(bookID), withIntermediateDirectories: true)
        do { try jpeg.write(to: imageFile(id, bookID), options: .atomic) } catch { return nil }
        return id
    }

    func imageData(_ id: String, book: UUID) -> Data? { try? Data(contentsOf: imageFile(id, book)) }

    /// Every picture the book uses, for exporting.
    func images(for book: BookProject) -> [String: Data] {
        var out: [String: Data] = [:]
        for id in book.imageIDs { if let d = imageData(id, book: book.id) { out[id] = d } }
        return out
    }

    func thumbnail(_ id: String, book: UUID) -> UIImage? {
        let key = "\(book.uuidString)/\(id)" as NSString
        if let hit = thumbnails.object(forKey: key) { return hit }
        guard let data = imageData(id, book: book), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// Pictures that are no longer in the book (deleted blocks, a replaced cover) are removed so storage does not grow.
    private func removeUnusedImages(of book: BookProject) {
        let used = Set(book.imageIDs.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" } + ".jpg" })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imagesFolder(book.id).path)) ?? []
        for f in files where !used.contains(f) { try? FileManager.default.removeItem(at: imagesFolder(book.id).appendingPathComponent(f)) }
    }
}
