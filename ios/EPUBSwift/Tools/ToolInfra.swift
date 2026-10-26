import SwiftUI
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable, Hashable {
    case epubPdf, pdfEpub, epubTxt, epubMd, extract, meta, cover, validate, repair, merge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .epubPdf: return L("EPUB to PDF")
        case .pdfEpub: return L("PDF to EPUB")
        case .epubTxt: return L("EPUB to TXT")
        case .epubMd: return L("EPUB to Markdown")
        case .extract: return L("Extract text")
        case .meta: return L("Metadata editor")
        case .cover: return L("Cover editor")
        case .validate: return L("Validator")
        case .repair: return L("Repair")
        case .merge: return L("Merge EPUBs")
        }
    }

    var subtitle: String {
        switch self {
        case .epubPdf: return L("Make a paginated PDF from a book")
        case .pdfEpub: return L("Turn a text PDF into a reflowable book")
        case .epubTxt: return L("Export the whole book as plain text")
        case .epubMd: return L("Headings, lists and links preserved")
        case .extract: return L("By chapter, with search")
        case .meta: return L("Title, author, language and more")
        case .cover: return L("Replace or add a cover image")
        case .validate: return L("Check the structure of a book")
        case .repair: return L("Fix common structural problems")
        case .merge: return L("Combine books into one")
        }
    }

    var detail: String {
        switch self {
        case .epubPdf: return L("Convert an EPUB into a paginated PDF on your device. Headings, paragraphs, lists and images are kept, and Arabic and right-to-left text is supported.")
        case .pdfEpub: return L("Extract text from a PDF and build an EPUB with chapters and navigation. Scanned PDFs need OCR, which is not included.")
        case .epubTxt: return L("Extract the readable text of an EPUB into a UTF-8 text file.")
        case .epubMd: return L("Convert chapters into Markdown, keeping headings, paragraphs and lists. Images can be exported alongside.")
        case .extract: return L("Extract the text chapter by chapter, search for passages, and export the full book or a single chapter.")
        case .meta: return L("Edit the title, authors, language, publisher, description and identifier. Everything else in the book is kept as it is.")
        case .cover: return L("Replace or add a cover. The manifest and cover references are updated correctly.")
        case .validate: return L("Check packaging, manifest, spine, navigation and links. These are the app's own checks, not the official EPUBCheck.")
        case .repair: return L("Automatically fix well-understood structural problems and save the result as a new file. Not every damaged book can be repaired.")
        case .merge: return L("Combine several EPUB files into a single book with a new table of contents.")
        }
    }

    var icon: String {
        switch self {
        case .epubPdf: return "doc.richtext"
        case .pdfEpub: return "book.pages"
        case .epubTxt: return "doc.text"
        case .epubMd: return "number.square"
        case .extract: return "text.magnifyingglass"
        case .meta: return "pencil.and.list.clipboard"
        case .cover: return "photo.on.rectangle.angled"
        case .validate: return "checkmark.shield"
        case .repair: return "wrench.and.screwdriver"
        case .merge: return "square.stack.3d.up"
        }
    }

    static let convert: [Tool] = [.epubPdf, .pdfEpub, .epubTxt, .epubMd, .extract]
    static let editing: [Tool] = [.meta, .cover, .validate, .repair, .merge]
}

struct PickedFile: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
}

enum OutFiles {
    static var dir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("EPUBSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func clear() {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("EPUBSwift", isDirectory: true))
    }

    static func safe(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r")
        let cleaned = name.components(separatedBy: bad).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "book" : String(cleaned.prefix(80))
    }

    static func write(_ data: Data, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        do { try data.write(to: url, options: .atomic) } catch {
            throw EpubError.failed(L("There is not enough free storage to finish, or the file could not be saved."))
        }
        return url
    }

    /// Copies a file picked from the Files app into the temp folder so it stays readable.
    static func importCopy(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let folder = dir.appendingPathComponent("In-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: dest)
        return dest
    }
}

struct ToolOutput {
    var fileURL: URL?
    var summary: [String] = []
    var text: String?
    var issues: [ValidationIssue] = []
    var isEpub = false
}

@MainActor
final class ToolRunner: ObservableObject {
    enum State { case idle, running, done, failed(String) }

    @Published var state: State = .idle
    @Published var progress = 0.0
    @Published var output: ToolOutput?

    var isRunning: Bool { if case .running = state { return true }; return false }

    func reset() { state = .idle; output = nil; progress = 0 }

    func run(_ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) throws -> ToolOutput) {
        guard !isRunning else { return }
        state = .running
        progress = 0
        output = nil
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try work { value in Task { @MainActor in self.progress = value } }
                }.value
                self.output = out
                self.state = .done
                AdManager.shared.preloadInterstitial()
            } catch {
                if error is CancellationError { return }
                let ns = error as NSError
                if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
                    self.state = .failed(L("There is not enough free storage to finish. Free some space and try again."))
                } else {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}

/// Picks one or more files, from the library or the Files app.
struct SourcePicker: View {
    @Binding var files: [PickedFile]
    var multiple = false
    var types: [UTType] = [.epub]
    var allowLibrary = true
    @StateObject private var library = LibraryStore.shared
    @State private var showLibrary = false
    @State private var showImporter = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(files.enumerated()), id: \.element.id) { i, file in
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").foregroundStyle(Palette.indigo)
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if multiple {
                        Button { move(i, -1) } label: { Image(systemName: "arrow.up") }.disabled(i == 0)
                        Button { move(i, 1) } label: { Image(systemName: "arrow.down") }.disabled(i == files.count - 1)
                    }
                    Button(role: .destructive) { files.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
            HStack {
                if allowLibrary {
                    Button { showLibrary = true } label: { Label(L("From library"), systemImage: "books.vertical") }
                        .buttonStyle(.bordered)
                }
                Button { showImporter = true } label: { Label(L("From Files"), systemImage: "folder") }
                    .buttonStyle(.bordered)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .sheet(isPresented: $showLibrary) {
            LibraryPickSheet(multiple: multiple) { books in
                for b in books where !files.contains(where: { $0.url == library.fileURL(b) }) {
                    files.append(PickedFile(url: library.fileURL(b)))
                }
                if !multiple, files.count > 1 { files = [files.last!] }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: types, allowsMultipleSelection: multiple) { result in
            switch result {
            case .success(let urls):
                var picked: [PickedFile] = []
                for u in urls {
                    do { picked.append(PickedFile(url: try OutFiles.importCopy(u))) } catch { self.error = error.localizedDescription }
                }
                if multiple { files.append(contentsOf: picked) } else if let p = picked.first { files = [p] }
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }

    private func move(_ i: Int, _ delta: Int) {
        let j = i + delta
        guard files.indices.contains(i), files.indices.contains(j) else { return }
        files.swapAt(i, j)
    }
}

struct LibraryPickSheet: View {
    var multiple: Bool
    var onDone: ([BookRecord]) -> Void
    @StateObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    Text(L("Your library is empty")).foregroundStyle(.secondary)
                } else {
                    List(library.books) { book in
                        Button {
                            if multiple {
                                if selected.contains(book.id) { selected.remove(book.id) } else { selected.insert(book.id) }
                            } else {
                                onDone([book]); dismiss()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(book.title).foregroundStyle(.primary)
                                    if !book.authors.isEmpty { Text(book.authors).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if selected.contains(book.id) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.indigo) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { dismiss() } }
                if multiple {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L("Done")) {
                            onDone(library.books.filter { selected.contains($0.id) })
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

/// Shared layout for every tool: description, source, options, run button, progress and result.
struct ToolScaffold<Options: View>: View {
    let tool: Tool
    @ObservedObject var runner: ToolRunner
    var runTitle: String = L("Run")
    var canRun: Bool
    var needsFileMessage: String = L("Choose a file first.")
    var onRun: () -> Void
    @ViewBuilder var source: () -> SourcePicker
    @ViewBuilder var options: () -> Options

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tool.detail).font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Source")).font(.headline)
                    source()
                }
                .card()
                options()
                Button {
                    onRun()
                } label: {
                    HStack {
                        if runner.isRunning { ProgressView().tint(.white) }
                        Text(runner.isRunning ? L("Working…") : runTitle).font(.headline)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(canRun && !runner.isRunning ? AnyShapeStyle(Palette.gradient) : AnyShapeStyle(Color.gray.opacity(0.4)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
                }
                .disabled(!canRun || runner.isRunning)
                if runner.isRunning { ProgressView(value: runner.progress).tint(Palette.indigo) }
                if case .failed(let message) = runner.state {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.red).card()
                }
                if case .done = runner.state, let out = runner.output { ResultCard(output: out) }
            }
            .padding(16)
        }
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BannerBar() }
    }
}

struct ResultCard: View {
    let output: ToolOutput
    @State private var added = false
    @State private var showText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Done"), systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            ForEach(output.summary, id: \.self) { Text("• " + $0).font(.footnote) }
            ForEach(output.issues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: icon(issue.severity)).foregroundStyle(color(issue.severity))
                    Text(issue.message).font(.footnote)
                }
            }
            if let url = output.fileURL {
                HStack {
                    ShareLink(item: url) { Label(L("Save or share"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    if output.isEpub {
                        Button {
                            Task { await LibraryStore.shared.addGenerated(url); added = true }
                        } label: { Label(added ? L("Added") : L("Add to library"), systemImage: added ? "checkmark" : "plus") }
                            .buttonStyle(.bordered)
                            .disabled(added)
                    }
                }
                Text(L("Your original file was not changed.")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func icon(_ s: ValidationIssue.Severity) -> String {
        switch s { case .error: return "xmark.octagon.fill"; case .warning: return "exclamationmark.triangle.fill"; case .info: return "info.circle.fill" }
    }

    private func color(_ s: ValidationIssue.Severity) -> Color {
        switch s { case .error: return .red; case .warning: return .orange; case .info: return .blue }
    }
}
