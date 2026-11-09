import Foundation

/// The free plan's book export allowance, kept on the device. The rules are in `BookExportQuota`; this stores them and ties
/// them to Premium.
@MainActor
final class BookQuotaStore: ObservableObject {
    static let shared = BookQuotaStore()

    @Published private(set) var quota: BookExportQuota
    private let key = "epubswift_book_quota"

    private init() {
        let month = BookExportQuota.monthKey(for: Date())
        var q = BookExportQuota(month: month)
        if let data = UserDefaults.standard.data(forKey: key), let saved = try? JSONDecoder().decode(BookExportQuota.self, from: data) { q = saved }
        q.roll(to: month)
        quota = q
    }

    private var isPremium: Bool { Premium.shared.isPremium }

    var canExport: Bool { quota.roll(copy: BookExportQuota.monthKey(for: Date())).canExport(isPremium: isPremium) }
    var exportsLeft: Int { quota.roll(copy: BookExportQuota.monthKey(for: Date())).remaining }
    var shouldWatermark: Bool { quota.shouldWatermark(isPremium: isPremium) }
    var videosTowardExtra: Int { quota.videosTowardExtra }

    func earnCleanExport() { change { $0.earnCleanExport() } }

    /// Returns true when this video completed a set of three and earned an extra export.
    @discardableResult
    func watchVideoForExtraExport() -> Bool {
        var earned = false
        change { earned = $0.watchVideoForExtraExport() }
        return earned
    }

    /// Call after an export was made.
    func recordExport() {
        let premium = isPremium
        change { $0.roll(to: BookExportQuota.monthKey(for: Date())); $0.record(isPremium: premium) }
    }

    private func change(_ edit: (inout BookExportQuota) -> Void) {
        var q = quota
        edit(&q)
        quota = q
        if let data = try? JSONEncoder().encode(q) { UserDefaults.standard.set(data, forKey: key) }
    }
}

private extension BookExportQuota {
    /// A copy that has moved to the given month, to answer questions without changing the stored one.
    func roll(copy month: String) -> BookExportQuota { var c = self; c.roll(to: month); return c }
}

/// Makes the export file for a book in the chosen format, off the main thread.
enum BookExportService {
    static func export(_ book: BookProject, images: [String: Data], format: BookFormat, watermark: Bool) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let note: String? = watermark ? BookExporter.watermarkText : nil
            let data: Data
            switch format {
            case .epub:
                data = BookExporter.epub(book, images: images, watermark: note)
            case .txt:
                data = BookExporter.txt(book, watermark: note)
            case .docx:
                data = BookExporter.docx(book, images: images, watermark: note)
            case .pdf:
                // The PDF is made from the EPUB, so all four formats come from one description of the book.
                let epub = BookExporter.epub(book, images: images, watermark: note)
                let package = try EpubPackage(archive: try ZipArchive(data: epub))
                data = try EpubToPdf.make(package, options: PdfOptions(), progress: { _ in })
            }
            let name = OutFiles.safe(book.displayTitle) + "." + format.fileExtension
            return try OutFiles.write(data, name: name)
        }.value
    }
}
