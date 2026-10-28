import Foundation
import UIKit
import SwiftUI

struct BookRecord: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var authors: String
    var addedAt: Date
    var lastOpened: Date?
    var chapterIndex: Int = 0
    var chapterFraction: Double = 0
    var progress: Double = 0
    var rtl: Bool = false

    var fileName: String { id + ".epub" }
}

private struct ImportedMeta {
    var title: String
    var authors: String
    var rtl: Bool
    var cover: Data?
}

enum LibraryError: LocalizedError {
    case duplicate(String)
    var errorDescription: String? {
        switch self {
        case .duplicate(let t): return String(format: L("\"%@\" is already in your library."), t)
        }
    }
}

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var books: [BookRecord] = []
    @Published var message: String?
    @Published var importing = false

    private let fm = FileManager.default
    private let root: URL

    private init() {
        root = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? fm.createDirectory(at: booksDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: coversDir, withIntermediateDirectories: true)
        load()
        if ScreenshotMode.isActive && books.isEmpty { installSamples() }
    }

    var booksDir: URL { root.appendingPathComponent("Books", isDirectory: true) }
    var coversDir: URL { Self.coversDirectory }

    /// Not tied to the main actor so the cover cache can use it from any context.
    nonisolated static var coversDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Covers", isDirectory: true)
    }
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    func fileURL(_ book: BookRecord) -> URL { booksDir.appendingPathComponent(book.fileName) }
    func coverURL(_ book: BookRecord) -> URL { coversDir.appendingPathComponent(book.id + ".jpg") }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([BookRecord].self, from: data) else { return }
        books = list.filter { fm.fileExists(atPath: booksDir.appendingPathComponent($0.fileName).path) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) { try? data.write(to: indexURL, options: .atomic) }
    }

    func book(id: String) -> BookRecord? { books.first { $0.id == id } }

    /// Screenshot mode only: copies the sample books bundled by the screenshots workflow into the library.
    private func installSamples() {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "epub", subdirectory: nil) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let progress: [Double] = [0.42, 0.0, 0.78, 0.0, 0.15, 0.0]
        for (i, url) in urls.enumerated() {
            let id = UUID().uuidString.lowercased()
            let dest = booksDir.appendingPathComponent(id + ".epub")
            guard (try? fm.copyItem(at: url, to: dest)) != nil, let pkg = try? EpubPackage(url: dest) else { continue }
            if let raw = pkg.coverData(), let image = UIImage(data: raw),
               let jpeg = EpubEdits.downscale(image, maxSide: 480).jpegData(compressionQuality: 0.85) {
                try? jpeg.write(to: coversDir.appendingPathComponent(id + ".jpg"))
            }
            var record = BookRecord(id: id, title: pkg.displayTitle, authors: pkg.authors.joined(separator: ", "),
                                    addedAt: Date().addingTimeInterval(-Double(i) * 60), rtl: pkg.rtl)
            record.progress = i < progress.count ? progress[i] : 0
            books.append(record)
        }
        save()
    }

    // MARK: Import

    func importFiles(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        var added = 0
        var errors: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                try await importOne(url)
                added += 1
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty { message = errors.joined(separator: "\n") }
        else if added > 0 { message = nil }
    }

    private func importOne(_ url: URL) async throws {
        let id = UUID().uuidString.lowercased()
        let dest = booksDir.appendingPathComponent(id + ".epub")
        try fm.copyItem(at: url, to: dest)
        do {
            let meta = try await Task.detached(priority: .userInitiated) { () -> ImportedMeta in
                let pkg = try EpubPackage(url: dest)
                var coverJPEG: Data?
                if let raw = pkg.coverData(), let image = UIImage(data: raw) {
                    let thumb = EpubEdits.downscale(image, maxSide: 480)
                    coverJPEG = thumb.jpegData(compressionQuality: 0.8)
                }
                return ImportedMeta(title: pkg.title.isEmpty ? url.deletingPathExtension().lastPathComponent : pkg.title,
                                    authors: pkg.authors.joined(separator: ", "), rtl: pkg.rtl, cover: coverJPEG)
            }.value
            if books.contains(where: { $0.title == meta.title && $0.authors == meta.authors && sameSize($0, dest) }) {
                try? fm.removeItem(at: dest)
                throw LibraryError.duplicate(meta.title)
            }
            if let cover = meta.cover { try? cover.write(to: coversDir.appendingPathComponent(id + ".jpg")) }
            books.insert(BookRecord(id: id, title: meta.title, authors: meta.authors, addedAt: Date(), rtl: meta.rtl), at: 0)
            save()
        } catch {
            try? fm.removeItem(at: dest)
            throw error
        }
    }

    private func sameSize(_ book: BookRecord, _ other: URL) -> Bool {
        let a = (try? fm.attributesOfItem(atPath: fileURL(book).path)[.size] as? Int) ?? -1
        let b = (try? fm.attributesOfItem(atPath: other.path)[.size] as? Int) ?? -2
        return a == b
    }

    /// Adds a finished file (for example a tool result) to the library.
    func addGenerated(_ url: URL) async {
        await importFiles([url])
    }

    // MARK: Updates

    func delete(_ book: BookRecord) {
        try? fm.removeItem(at: fileURL(book))
        try? fm.removeItem(at: coverURL(book))
        books.removeAll { $0.id == book.id }
        save()
    }

    func updateProgress(id: String, chapter: Int, fraction: Double, overall: Double) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].chapterIndex = chapter
        books[i].chapterFraction = fraction
        books[i].progress = overall
        books[i].lastOpened = Date()
        save()
    }

    func markOpened(id: String) {
        guard let i = books.firstIndex(where: { $0.id == id }) else { return }
        books[i].lastOpened = Date()
        save()
    }
}

enum CoverCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(for book: BookRecord) -> UIImage? {
        if let c = cache.object(forKey: book.id as NSString) { return c }
        let url = LibraryStore.coversDirectory.appendingPathComponent(book.id + ".jpg")
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: book.id as NSString)
        return image
    }
}
