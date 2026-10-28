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

    /// Tab to show first: 0 Library, 1 Tools, 2 Settings.
    static var tab: Int {
        switch name {
        case "tools", "pdf", "meta", "validate": return 1
        default: return 0
        }
    }

    /// Open the first sample book in the reader.
    static var opensReader: Bool { name == "reader" || name == "readerNight" }

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
    static var premium: Bool { name != "paywall" }

    /// Reader look for the screenshots.
    static func prepareDefaults() {
        guard isActive else { return }
        let d = UserDefaults.standard
        d.set(name == "readerNight" ? "night" : "paper", forKey: "reader_theme")
        d.set(21.0, forKey: "reader_font_size")
        d.set("light", forKey: "appearance")
    }

    /// The first sample book as a tool input.
    @MainActor
    static var sampleFiles: [PickedFile] {
        guard isActive, let book = LibraryStore.shared.books.first(where: { $0.title.hasPrefix("Alice") }) ?? LibraryStore.shared.books.first
        else { return [] }
        return [PickedFile(url: LibraryStore.shared.fileURL(book))]
    }
}
