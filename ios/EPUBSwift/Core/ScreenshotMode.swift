import Foundation

/// Debug-only hook used by the Codemagic "ios-screenshots" workflow: launching the app in the simulator
/// with `-shot <name>` opens that screen with sample books and no ads, so the App Store screenshots come
/// from the real app. Release builds (App Store / TestFlight) compile this out.
enum ScreenshotMode {
    #if DEBUG
    static let name: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-shot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    #else
    static let name: String? = nil
    #endif

    static var isActive: Bool { name != nil }

    /// The sample book the Create-tab screenshots open (made by `ScreenshotSeed`, debug builds only).
    static let sampleBookID = UUID(uuidString: "5C1A0B9E-7D3E-4F10-9A55-0E6B3C2D1A01")!

    /// Tab to show first: 0 Library, 1 Tools, 2 Settings.
    static var tab: Int {
        switch name {
        case "tools", "pdf", "meta", "validate": return 1
        case "create", "bookeditor", "export": return 3
        default: return 0
        }
    }

    /// Open the first sample book in the reader.
    static var opensReader: Bool { ["reader", "readerNight", "highlight", "notes", "sketch"].contains(name ?? "") }

    /// The new screens: the notes list, the sketch canvas, the Book Maker's editor and export sheet.
    static var opensNotes: Bool { name == "notes" }
    static var opensSketch: Bool { name == "sketch" }
    static var opensBookEditor: Bool { name == "bookeditor" || name == "export" }
    static var opensExport: Bool { name == "export" }
    /// Reader screens that show highlights.
    static var showsHighlights: Bool { ["highlight", "notes", "sketch"].contains(name ?? "") }

    static var showsPaywall: Bool { name == "paywall" }

    static var tool: Tool? {
        switch name {
        case "pdf": return .epubPdf
        case "meta": return .meta
        case "validate": return .validate
        default: return nil
        }
    }

    /// Everything except the Premium screen is shown as a Premium user (tools unlocked, no ads).
    static var premium: Bool { name != "paywall" && name != "export" }

    /// Reader look for the screenshots.
    static func prepareDefaults() {
        guard isActive else { return }
        let d = UserDefaults.standard
        d.set(name == "readerNight" ? "night" : "paper", forKey: "reader_theme")
        d.set(21.0, forKey: "reader_font_size")
        d.set("light", forKey: "appearance")
        #if DEBUG
        MainActor.assumeIsolated { ScreenshotSeed.seedBook() }
        #endif
    }

    /// The first sample book as a tool input.
    @MainActor
    static var sampleFiles: [PickedFile] {
        guard isActive, let book = LibraryStore.shared.books.first(where: { $0.title.hasPrefix("Alice") }) ?? LibraryStore.shared.books.first
        else { return [] }
        return [PickedFile(url: LibraryStore.shared.fileURL(book), displayName: OutFiles.safe(book.title) + ".epub")]
    }
}
