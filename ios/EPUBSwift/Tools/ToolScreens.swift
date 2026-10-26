import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

private func epubName(_ file: PickedFile, suffix: String, ext: String = "epub") -> String {
    OutFiles.safe(file.baseName + suffix) + "." + ext
}

// MARK: - Metadata

struct MetadataToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []
    @State private var fields: MetadataFields?
    @State private var loadError: String?

    var body: some View {
        ToolScaffold(tool: .meta, runner: runner, runTitle: L("Save as new EPUB"), canRun: fields != nil,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: {
                         VStack(alignment: .leading, spacing: 10) {
                             if let loadError { Text(loadError).foregroundStyle(.red).font(.footnote) }
                             if fields != nil {
                                 field(L("Title"), \.title)
                                 field(L("Authors (comma separated)"), \.authors)
                                 field(L("Language code (e.g. en, ar)"), \.language)
                                 field(L("Publisher"), \.publisher)
                                 field(L("Description"), \.descriptionText, multiline: true)
                                 field(L("Identifier"), \.identifier)
                             }
                         }
                         .card()
                         .opacity(fields == nil ? 0 : 1)
                         .frame(height: fields == nil ? 0 : nil)
                     })
            .onChange(of: files) { _, newFiles in load(newFiles.first) }
    }

    private func field(_ title: String, _ path: WritableKeyPath<MetadataFields, String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(get: { fields?[keyPath: path] ?? "" }, set: { fields?[keyPath: path] = $0 }),
                      axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 3...6 : 1...2)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func load(_ file: PickedFile?) {
        fields = nil
        loadError = nil
        runner.reset()
        guard let file else { return }
        let url = file.url
        Task {
            do {
                let f = try await Task.detached { MetadataFields(try EpubPackage(url: url)) }.value
                fields = f
            } catch { loadError = error.localizedDescription }
        }
    }

    private func run() {
        guard let file = files.first, let f = fields else { return }
        let url = file.url
        let name = epubName(file, suffix: "-edited")
        runner.run { _ in
            let pkg = try EpubPackage(url: url)
            let data = try EpubEdits.applyMetadata(pkg, f)
            return ToolOutput(fileURL: try OutFiles.write(data, name: name), summary: [L("Saved.")], isEpub: true)
        }
    }
}

// MARK: - Cover

struct CoverToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []
    @State private var currentCover: UIImage?
    @State private var item: PhotosPickerItem?
    @State private var newImage: UIImage?

    var body: some View {
        ToolScaffold(tool: .cover, runner: runner, runTitle: L("Save as new EPUB"), canRun: !files.isEmpty && newImage != nil,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: {
                         VStack(alignment: .leading, spacing: 12) {
                             HStack(alignment: .top, spacing: 16) {
                                 preview(L("Current cover"), currentCover)
                                 preview(L("New cover"), newImage)
                             }
                             PhotosPicker(selection: $item, matching: .images) {
                                 Label(L("Choose cover image"), systemImage: "photo")
                             }
                             .buttonStyle(.bordered)
                         }
                         .card()
                     })
            .onChange(of: files) { _, newFiles in
                currentCover = nil
                runner.reset()
                guard let url = newFiles.first?.url else { return }
                Task {
                    let data = await Task.detached { (try? EpubPackage(url: url))?.coverData() }.value
                    currentCover = data.flatMap { UIImage(data: $0) }
                }
            }
            .onChange(of: item) { _, newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        newImage = image
                    }
                }
            }
    }

    private func preview(_ title: String, _ image: UIImage?) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 110, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func run() {
        guard let file = files.first, let image = newImage else { return }
        let url = file.url
        let name = epubName(file, suffix: "-cover")
        runner.run { _ in
            let pkg = try EpubPackage(url: url)
            let data = try EpubEdits.replaceCover(pkg, image: image)
            return ToolOutput(fileURL: try OutFiles.write(data, name: name), summary: [L("Saved.")], isEpub: true)
        }
    }
}

// MARK: - Validate

struct ValidateToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []

    var body: some View {
        ToolScaffold(tool: .validate, runner: runner, runTitle: L("Check the book"), canRun: !files.isEmpty,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: { EmptyView() })
            .onChange(of: files) { _, _ in runner.reset() }
    }

    private func run() {
        guard let url = files.first?.url else { return }
        runner.run { _ in
            ToolOutput(summary: [], issues: EpubValidator.run(url: url))
        }
    }
}

// MARK: - Repair

struct RepairToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []

    var body: some View {
        ToolScaffold(tool: .repair, runner: runner, runTitle: L("Repair and save"), canRun: !files.isEmpty,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: { EmptyView() })
            .onChange(of: files) { _, _ in runner.reset() }
    }

    private func run() {
        guard let file = files.first else { return }
        let url = file.url
        let name = epubName(file, suffix: "-repaired")
        runner.run { _ in
            let (data, fixes) = try EpubRepair.run(url: url)
            return ToolOutput(fileURL: try OutFiles.write(data, name: name), summary: fixes, isEpub: true)
        }
    }
}

// MARK: - Merge

struct MergeToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []
    @State private var title = ""
    @State private var author = ""

    var body: some View {
        ToolScaffold(tool: .merge, runner: runner, runTitle: L("Merge and save"), canRun: files.count >= 2,
                     onRun: run,
                     source: { SourcePicker(files: $files, multiple: true) },
                     options: {
                         VStack(alignment: .leading, spacing: 10) {
                             Text(L("Books are merged in the order shown. Use the arrows to reorder."))
                                 .font(.caption).foregroundStyle(.secondary)
                             TextField(L("Title of the merged book (optional)"), text: $title).textFieldStyle(.roundedBorder)
                             TextField(L("Author (optional, otherwise all authors)"), text: $author).textFieldStyle(.roundedBorder)
                             if files.count < 2 { Text(L("Select at least two EPUB files.")).font(.footnote).foregroundStyle(.orange) }
                         }
                         .card()
                     })
    }

    private func run() {
        let urls = files.map { $0.url }
        let t = title, a = author
        let name = OutFiles.safe(t.isEmpty ? L("Merged book") : t) + ".epub"
        runner.run { progress in
            let data = try EpubMerger.merge(urls: urls, title: t, author: a, progress: progress)
            return ToolOutput(fileURL: try OutFiles.write(data, name: name), summary: [String(format: L("%d books merged."), urls.count)], isEpub: true)
        }
    }
}

// MARK: - TXT

struct TxtToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []

    var body: some View {
        ToolScaffold(tool: .epubTxt, runner: runner, runTitle: L("Export text"), canRun: !files.isEmpty,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: { EmptyView() })
            .onChange(of: files) { _, _ in runner.reset() }
    }

    private func run() {
        guard let file = files.first else { return }
        let url = file.url
        let name = epubName(file, suffix: "", ext: "txt")
        runner.run { progress in
            let pkg = try EpubPackage(url: url)
            let chapters = EpubText.chapters(pkg, progress: progress)
            let text = EpubText.plainText(chapters)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EpubError.noText }
            return ToolOutput(fileURL: try OutFiles.write(Data(text.utf8), name: name),
                              summary: [String(format: L("%d chapters exported."), chapters.count)])
        }
    }
}

// MARK: - Markdown

struct MarkdownToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []
    @State private var includeImages = false

    var body: some View {
        ToolScaffold(tool: .epubMd, runner: runner, runTitle: L("Export Markdown"), canRun: !files.isEmpty,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: {
                         VStack(alignment: .leading, spacing: 4) {
                             Toggle(L("Export images"), isOn: $includeImages)
                             Text(L("Saves a ZIP with the Markdown file and an images folder."))
                                 .font(.caption).foregroundStyle(.secondary)
                         }
                         .card()
                     })
            .onChange(of: files) { _, _ in runner.reset() }
    }

    private func run() {
        guard let file = files.first else { return }
        let url = file.url
        let withImages = includeImages
        let md = epubName(file, suffix: "", ext: "md")
        let zip = epubName(file, suffix: "-markdown", ext: "zip")
        runner.run { progress in
            let pkg = try EpubPackage(url: url)
            let (text, images) = EpubMarkdown.make(pkg, includeImages: withImages, progress: progress)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EpubError.noText }
            if withImages && !images.isEmpty {
                let data = EpubMarkdown.zip(markdown: text, images: images)
                return ToolOutput(fileURL: try OutFiles.write(data, name: zip), summary: [String(format: L("%d images exported."), images.count)])
            }
            return ToolOutput(fileURL: try OutFiles.write(Data(text.utf8), name: md), summary: [L("Saved.")])
        }
    }
}

// MARK: - Extract

struct ExtractToolView: View {
    @State private var files: [PickedFile] = []
    @State private var chapters: [TextChapter] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var selected: TextChapter?
    @State private var exportURL: URL?
    @State private var bookTitle = ""

    private var filtered: [TextChapter] {
        let q = EpubText.fold(query.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return chapters }
        return chapters.filter { EpubText.fold($0.text).contains(q) || EpubText.fold($0.title).contains(q) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Tool.extract.detail).font(.subheadline).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Source")).font(.headline)
                    SourcePicker(files: $files)
                }
                .card()
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                if !chapters.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(L("Search the text"), text: $query).textFieldStyle(.roundedBorder)
                        HStack {
                            Text(L("Chapters")).font(.headline)
                            Spacer()
                            if let exportURL {
                                ShareLink(item: exportURL) { Label(L("Export the whole book"), systemImage: "square.and.arrow.up") }
                                    .font(.footnote)
                            }
                        }
                        ForEach(filtered) { ch in
                            Button { selected = ch } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(ch.title).foregroundStyle(.primary).lineLimit(1)
                                        Text(String(format: L("%d characters"), ch.text.count)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            Divider()
                        }
                    }
                    .card()
                }
            }
            .padding(16)
        }
        .navigationTitle(Tool.extract.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { BannerBar() }
        .onChange(of: files) { _, newFiles in load(newFiles.first) }
        .sheet(item: $selected) { ch in ChapterTextSheet(chapter: ch, bookTitle: bookTitle) }
    }

    private func load(_ file: PickedFile?) {
        chapters = []
        error = nil
        exportURL = nil
        guard let file else { return }
        loading = true
        let url = file.url
        let name = epubName(file, suffix: "", ext: "txt")
        Task {
            do {
                let result = try await Task.detached { () -> (String, [TextChapter], URL?) in
                    let pkg = try EpubPackage(url: url)
                    let list = EpubText.chapters(pkg)
                    guard !list.isEmpty else { throw EpubError.noText }
                    let out = try OutFiles.write(Data(EpubText.plainText(list).utf8), name: name)
                    return (pkg.displayTitle, list, out)
                }.value
                bookTitle = result.0
                chapters = result.1
                exportURL = result.2
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

struct ChapterTextSheet: View {
    let chapter: TextChapter
    let bookTitle: String
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(chapter.text).font(.body).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .navigationTitle(chapter.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("Done")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if let fileURL { ShareLink(item: fileURL) { Label(L("Save this chapter"), systemImage: "square.and.arrow.up") } }
                }
            }
            .task {
                let name = OutFiles.safe(bookTitle + " - " + chapter.title) + ".txt"
                fileURL = try? OutFiles.write(Data((chapter.title + "\n\n" + chapter.text).utf8), name: name)
            }
        }
    }
}

// MARK: - EPUB to PDF

struct PdfToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []
    @State private var letter = false
    @State private var margin = 54.0
    @State private var fontSize = 12.0
    @State private var chapterBreaks = true
    @State private var includeCover = true

    var body: some View {
        ToolScaffold(tool: .epubPdf, runner: runner, runTitle: L("Create PDF"), canRun: !files.isEmpty,
                     onRun: run,
                     source: { SourcePicker(files: $files) },
                     options: {
                         VStack(alignment: .leading, spacing: 12) {
                             Picker(L("Page size"), selection: $letter) {
                                 Text("A4").tag(false)
                                 Text("Letter").tag(true)
                             }
                             .pickerStyle(.segmented)
                             Picker(L("Margins"), selection: $margin) {
                                 Text(L("Narrow")).tag(36.0)
                                 Text(L("Normal")).tag(54.0)
                                 Text(L("Wide")).tag(72.0)
                             }
                             .pickerStyle(.segmented)
                             Stepper(String(format: L("Font size: %d pt"), Int(fontSize)), value: $fontSize, in: 9...20, step: 1)
                             Toggle(L("Start each chapter on a new page"), isOn: $chapterBreaks)
                             Toggle(L("Include the cover page"), isOn: $includeCover)
                             Text(L("Limits: links are not clickable, and fixed-layout books, complex CSS and SVG images are simplified."))
                                 .font(.caption).foregroundStyle(.secondary)
                         }
                         .card()
                     })
            .onChange(of: files) { _, _ in runner.reset() }
    }

    private func run() {
        guard let file = files.first else { return }
        let url = file.url
        let options = PdfOptions(letter: letter, margin: CGFloat(margin), fontSize: CGFloat(fontSize),
                                 chapterBreaks: chapterBreaks, includeCover: includeCover)
        let name = epubName(file, suffix: "", ext: "pdf")
        runner.run { progress in
            let pkg = try EpubPackage(url: url)
            let data = try EpubToPdf.make(pkg, options: options, progress: progress)
            return ToolOutput(fileURL: try OutFiles.write(data, name: name), summary: [L("Saved.")])
        }
    }
}

// MARK: - PDF to EPUB

struct PdfToEpubToolView: View {
    @StateObject private var runner = ToolRunner()
    @State private var files: [PickedFile] = []
    @State private var title = ""
    @State private var author = ""
    @State private var language = ""
    @State private var includeCover = true

    var body: some View {
        ToolScaffold(tool: .pdfEpub, runner: runner, runTitle: L("Create EPUB"), canRun: !files.isEmpty,
                     onRun: run,
                     source: { SourcePicker(files: $files, types: [.pdf], allowLibrary: false) },
                     options: {
                         VStack(alignment: .leading, spacing: 10) {
                             TextField(L("Title"), text: $title).textFieldStyle(.roundedBorder)
                             TextField(L("Authors (comma separated)"), text: $author).textFieldStyle(.roundedBorder)
                             TextField(L("Language code (e.g. en, ar)"), text: $language)
                                 .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never)
                             Toggle(L("Use the first page as the cover"), isOn: $includeCover)
                             Text(L("Limits: scanned PDFs need OCR (not included). Multi-column pages are read column by column; tables and sidebars are flattened."))
                                 .font(.caption).foregroundStyle(.secondary)
                         }
                         .card()
                     })
            .onChange(of: files) { _, _ in runner.reset() }
    }

    private func run() {
        guard let file = files.first else { return }
        let url = file.url
        let options = PdfImportOptions(title: title, author: author, language: language.trimmingCharacters(in: .whitespaces),
                                       includeCover: includeCover)
        let name = epubName(file, suffix: "", ext: "epub")
        runner.run { progress in
            let (data, notes) = try PdfToEpub.make(url: url, options: options, progress: progress)
            return ToolOutput(fileURL: try OutFiles.write(data, name: name), summary: notes, isEpub: true)
        }
    }
}

// MARK: - Destination

struct ToolDestination: View {
    let tool: Tool

    var body: some View {
        switch tool {
        case .epubPdf: PdfToolView()
        case .pdfEpub: PdfToEpubToolView()
        case .epubTxt: TxtToolView()
        case .epubMd: MarkdownToolView()
        case .extract: ExtractToolView()
        case .meta: MetadataToolView()
        case .cover: CoverToolView()
        case .validate: ValidateToolView()
        case .repair: RepairToolView()
        case .merge: MergeToolView()
        }
    }
}
