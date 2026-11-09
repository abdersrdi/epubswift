import PencilKit
import SwiftUI
import WebKit

@MainActor
final class ReaderModel: ObservableObject {
    let book: BookRecord
    @Published var package: EpubPackage?
    @Published var errorText: String?
    @Published var index = 0
    @Published var fraction = 0.0
    @Published var pendingFragment: String?
    @Published var reloadToken = 0
    @Published var searchChapters: [TextChapter]?
    @Published var annotations: [Annotation] = []
    /// Changes whenever this chapter's highlights do, so the page redraws them.
    @Published var annotationVersion = 0
    @Published var selection: TextSelection?
    @Published var focusAnnotation: UUID?
    @Published var editing: Annotation?
    @Published var draft: Annotation?
    /// Changes when the page should drop its text selection.
    @Published var clearToken = 0
    @Published var sketches: [SketchNote] = []
    @Published var sketchDraft: SketchDraft?
    weak var web: WKWebView?
    let handler = BookSchemeHandler()
    var restoreFraction = 0.0

    init(book: BookRecord) { self.book = book }

    var paths: [String] { package?.spinePaths ?? [] }
    var currentPath: String { paths.indices.contains(index) ? paths[index] : "" }
    var rtl: Bool { package?.rtl ?? book.rtl }

    var overall: Double {
        guard !paths.isEmpty else { return 0 }
        return min(1, (Double(index) + fraction) / Double(paths.count))
    }

    var chapterTitle: String {
        if let t = package?.toc.last(where: { $0.path == currentPath })?.title { return t }
        return String(format: L("Chapter %d of %d"), index + 1, max(1, paths.count))
    }

    func load(style: ReaderStyle) async {
        let url = LibraryStore.shared.fileURL(book)
        do {
            let pkg = try await Task.detached(priority: .userInitiated) { try EpubPackage(url: url) }.value
            handler.package = pkg
            handler.css = style.css(rtl: pkg.rtl)
            package = pkg
            index = min(max(0, book.chapterIndex), max(0, pkg.spinePaths.count - 1))
            fraction = book.chapterFraction
            restoreFraction = book.chapterFraction
        } catch {
            errorText = error.localizedDescription
        }
    }

    func apply(_ style: ReaderStyle) {
        handler.css = style.css(rtl: rtl)
        restoreFraction = fraction
        reloadToken += 1
    }

    func go(to i: Int, fragment: String? = nil, atEnd: Bool = false) {
        guard paths.indices.contains(i) else { return }
        index = i
        fraction = atEnd ? 1 : 0
        restoreFraction = atEnd ? 0.999 : 0
        pendingFragment = fragment
        save()
    }

    func next() { go(to: index + 1) }
    func previous() { go(to: index - 1, atEnd: true) }

    func open(path: String, fragment: String?) {
        if let i = paths.firstIndex(of: path) { go(to: i, fragment: fragment) }
    }

    func save() {
        guard package != nil else { return }
        LibraryStore.shared.updateProgress(id: book.id, chapter: index, fraction: fraction, overall: overall)
    }

    #if DEBUG
    /// Screenshot workflow only: finds a chapter with real paragraphs, highlights a few of them (unless that was already done on an
    /// earlier launch), and opens the sketch screen when asked.
    func prepareScreenshot() async {
        guard ScreenshotMode.showsHighlights else { return }
        if annotations.isEmpty { await seedScreenshotHighlights() }
        if ScreenshotMode.opensSketch {
            try? await Task.sleep(nanoseconds: 2_500_000_000)             // let the page and its highlights finish drawing
            beginSketch()
        }
    }

    private func seedScreenshotHighlights() async {
        let finder = """
        (function(){
          var ps = [].slice.call(document.querySelectorAll('p')).filter(function(p){ return p.textContent.length > 120; }).slice(0, 3);
          var out = [];
          ps.forEach(function(p){
            var n = p.firstChild; while (n && n.nodeType !== 3) n = n.firstChild;
            if (!n) return;
            var t = n.data, len = Math.min(t.length, 80);
            var cut = t.substring(0, len).search(/[,;:.!?][^,;:.!?]*$/);        // end at the last punctuation inside the first 80 characters
            if (cut > 30) len = cut + 1;
            var r = document.createRange(); r.setStart(document.body, 0); r.setEnd(n, 0);
            var s = r.toString().length;
            out.push({start: s, end: s + len, text: t.substring(0, len)});
          });
          return JSON.stringify(out);
        })()
        """
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard let web else { continue }
            let result = try? await web.evaluateJavaScript(finder, in: nil, contentWorld: BookWebView.world)
            if let text = result as? String, let data = text.data(using: .utf8),
               let found = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], !found.isEmpty {
                let colors: [HighlightColor] = [.yellow, .green, .pink]
                for (i, item) in found.enumerated() {
                    guard let s = item["start"] as? Int, let e = item["end"] as? Int, let q = item["text"] as? String else { continue }
                    var a = Annotation(chapterIndex: index, chapterPath: currentPath, start: s, end: e, quote: q, color: colors[i % 3])
                    if i == 0 { a.note = "Compare this with the opening of chapter one." }
                    AnnotationStore.shared.add(a, to: book.id)
                }
                loadAnnotations()
                return
            }
            next()                                                       // this chapter has no running text; try the next one
        }
    }
    #endif

    // MARK: Sketches (Apple Pencil)

    func loadSketches() { sketches = SketchStore.shared.sketches(for: book.id) }

    /// Takes a picture of the page as it looks now and opens a canvas over it.
    func beginSketch() {
        guard let web, !currentPath.isEmpty else { return }
        let note = SketchNote(chapterIndex: index, chapterPath: currentPath, fraction: fraction)
        web.takeSnapshot(with: nil) { [weak self] image, _ in
            guard let image else { return }
            var drawing = PKDrawing()
            #if DEBUG
            if ScreenshotMode.opensSketch { drawing = ScreenshotSeed.sampleDrawing(for: image.size) }
            #endif
            DispatchQueue.main.async { self?.sketchDraft = SketchDraft(note: note, backdrop: image, drawing: drawing, isNew: true) }
        }
    }

    func openSketch(_ note: SketchNote) {
        let store = SketchStore.shared
        guard let backdropData = store.backdropData(note.id, book: book.id), let backdrop = UIImage(data: backdropData) else { return }
        let drawing = store.drawingData(note.id, book: book.id).flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
        sketchDraft = SketchDraft(note: note, backdrop: backdrop, drawing: drawing, isNew: false)
    }

    func saveSketch(_ draft: SketchDraft) {
        let store = SketchStore.shared
        let data = draft.drawing.dataRepresentation()
        if draft.isNew {
            guard let jpeg = draft.backdrop.jpegData(compressionQuality: 0.85) else { return }
            store.add(draft.note, drawing: data, backdrop: jpeg, to: book.id)
        } else {
            store.update(draft.note, drawing: data, in: book.id)
        }
        loadSketches()
    }

    func deleteSketch(_ id: UUID) {
        SketchStore.shared.delete(id: id, from: book.id)
        loadSketches()
    }

    /// Opens the chapter of a sketch at the place it was made.
    func goTo(_ note: SketchNote) {
        go(to: note.chapterIndex)
        fraction = note.fraction
        restoreFraction = note.fraction
        reloadToken += 1
    }

    // MARK: Highlights and notes

    func loadAnnotations() {
        annotations = AnnotationStore.shared.annotations(for: book.id)
        annotationVersion += 1
    }

    var chapterAnnotations: [Annotation] { annotations.filter { $0.chapterPath == currentPath } }

    /// A highlight for the current selection. With `withNote` the note editor opens first and nothing is saved until Save.
    func highlightSelection(color: HighlightColor, withNote: Bool = false) {
        guard let sel = selection, !currentPath.isEmpty else { return }
        let a = Annotation(chapterIndex: index, chapterPath: currentPath, start: sel.start, end: sel.end,
                           quote: sel.text.trimmingCharacters(in: .whitespacesAndNewlines), color: color)
        selection = nil
        if withNote {
            draft = a
        } else {
            AnnotationStore.shared.add(a, to: book.id)
            loadAnnotations()
        }
        clearToken += 1
    }

    func save(_ a: Annotation) {
        if annotations.contains(where: { $0.id == a.id }) { AnnotationStore.shared.update(a, in: book.id) }
        else { AnnotationStore.shared.add(a, to: book.id) }
        loadAnnotations()
    }

    func deleteAnnotation(_ id: UUID) {
        AnnotationStore.shared.delete(id: id, from: book.id)
        loadAnnotations()
    }

    /// Opens the page of a highlight and scrolls to it.
    func show(_ a: Annotation) {
        focusAnnotation = a.id
        if index != a.chapterIndex { go(to: a.chapterIndex) } else { annotationVersion += 1 }
    }

    func chapterTitle(at i: Int) -> String {
        guard paths.indices.contains(i) else { return String(format: L("Chapter %d"), i + 1) }
        if let t = package?.toc.first(where: { $0.path == paths[i] })?.title { return t }
        return String(format: L("Chapter %d"), i + 1)
    }

    func prepareSearch() async {
        guard searchChapters == nil, let pkg = package else { return }
        let chapters = await Task.detached(priority: .utility) { EpubText.chapters(pkg) }.value
        searchChapters = chapters
    }
}

struct SearchHit: Identifiable {
    let id = UUID()
    let chapter: Int
    let title: String
    let snippet: String
}

struct ReaderView: View {
    @StateObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var premium = Premium.shared

    @AppStorage("reader_font_size") private var fontSize = 20.0
    @AppStorage("reader_theme") private var themeRaw = ReaderTheme.paper.rawValue
    @AppStorage("reader_serif") private var serif = true
    @AppStorage("reader_line_height") private var lineHeight = 1.6
    @AppStorage("reader_margin") private var margin = 18.0

    @State private var showToc = false
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var showNotes = ScreenshotMode.opensNotes

    init(book: BookRecord) {
        _model = StateObject(wrappedValue: ReaderModel(book: book))
    }

    private var style: ReaderStyle {
        ReaderStyle(fontSize: fontSize, theme: ReaderTheme(rawValue: themeRaw) ?? .paper, serif: serif,
                    lineHeight: lineHeight, margin: margin)
    }

    var body: some View {
        let theme = style.theme
        ZStack {
            Color(hex: theme.background).ignoresSafeArea()
            VStack(spacing: 0) {
                header(theme)
                if let error = model.errorText {
                    Spacer()
                    Text(error).multilineTextAlignment(.center).padding(24)
                        .foregroundStyle(Color(hex: theme.text))
                    Spacer()
                } else if model.package == nil {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    BookWebView(
                        handler: model.handler,
                        path: model.currentPath,
                        fragment: model.pendingFragment,
                        reloadToken: model.reloadToken,
                        restore: model.restoreFraction,
                        background: theme.backgroundUIColor,
                        onProgress: { model.fraction = $0 },
                        onLink: { path, fragment in model.open(path: path, fragment: fragment) },
                        onNext: { model.next() },
                        onPrev: { model.previous() },
                        annotations: model.chapterAnnotations,
                        annotationVersion: model.annotationVersion,
                        clearToken: model.clearToken,
                        focusAnnotation: model.focusAnnotation,
                        onFocused: { model.focusAnnotation = nil },
                        onSelection: { model.selection = $0 },
                        onTapAnnotation: { id in model.editing = model.annotations.first { $0.id == id } },
                        onWebReady: { model.web = $0 })
                    if model.selection != nil { selectionBar(theme) }
                    footer(theme)
                }
                BannerBar()
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task {
            await model.load(style: style)
            model.loadAnnotations()
            model.loadSketches()
            #if DEBUG
            if ScreenshotMode.isActive { await model.prepareScreenshot() }
            #endif
            LibraryStore.shared.markOpened(id: model.book.id)
        }
        .onChange(of: style) { _, newStyle in
            guard model.package != nil else { return }
            _ = newStyle
            model.apply(style)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.save() }
        }
        .onDisappear {
            model.save()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { AdManager.shared.afterReader() }
        }
        .sheet(isPresented: $showToc) { TocSheet(model: model, isPresented: $showToc) }
        .sheet(isPresented: $showSearch) { SearchSheet(model: model, isPresented: $showSearch) }
        .sheet(isPresented: $showNotes) { NotesSheet(model: model, isPresented: $showNotes) }
        .fullScreenCover(item: $model.sketchDraft) { draft in SketchEditor(draft: draft, onSave: { model.saveSketch($0) }) }
        .sheet(item: $model.draft) { draft in
            NoteEditor(annotation: draft, isNew: true, onSave: { model.save($0) }, onDelete: nil)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $model.editing) { existing in
            NoteEditor(annotation: existing, isNew: false, onSave: { model.save($0) }, onDelete: { model.deleteAnnotation(existing.id) })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(fontSize: $fontSize, themeRaw: $themeRaw, serif: $serif,
                                lineHeight: $lineHeight, margin: $margin)
                .presentationDetents([.medium])
        }
    }

    private func header(_ theme: ReaderTheme) -> some View {
        HStack(spacing: 18) {
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(L("Close"))
            Text(model.package?.displayTitle ?? model.book.title)
                .font(.subheadline.weight(.semibold)).lineLimit(1)
                .frame(maxWidth: .infinity)
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                .accessibilityLabel(L("Search"))
            Button { model.beginSketch() } label: { Image(systemName: "pencil.tip.crop.circle") }
                .accessibilityLabel(L("Sketch"))
            Button { showNotes = true } label: { Image(systemName: "highlighter") }
                .accessibilityLabel(L("Notes"))
            Button { showToc = true } label: { Image(systemName: "list.bullet") }
                .accessibilityLabel(L("Contents"))
            Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel(L("Appearance"))
        }
        .font(.body)
        .foregroundStyle(Color(hex: theme.text))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Shown while text is selected: pick a colour to highlight it, or add a note.
    private func selectionBar(_ theme: ReaderTheme) -> some View {
        HStack(spacing: 16) {
            ForEach(HighlightColor.allCases) { color in
                Button { model.highlightSelection(color: color) } label: {
                    Circle().fill(color.swatch).frame(width: 30, height: 30)
                        .overlay(Circle().stroke(Color(hex: theme.text).opacity(0.25), lineWidth: 1))
                }
                .accessibilityLabel(String(format: L("Highlight %@"), color.title))
            }
            Spacer(minLength: 8)
            Button { model.highlightSelection(color: .yellow, withNote: true) } label: {
                Label(L("Note"), systemImage: "square.and.pencil").font(.subheadline.weight(.semibold))
            }
        }
        .foregroundStyle(Color(hex: theme.text))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color(hex: theme.background).opacity(0.98))
        .overlay(alignment: .top) { Divider() }
    }

    private func footer(_ theme: ReaderTheme) -> some View {
        HStack {
            Button { model.previous() } label: { Image(systemName: "chevron.backward") }
                .disabled(model.index == 0)
            VStack(spacing: 2) {
                Text(model.chapterTitle).font(.caption).lineLimit(1)
                Text("\(Int(model.overall * 100))%").font(.caption2).opacity(0.7)
            }
            .frame(maxWidth: .infinity)
            Button { model.next() } label: { Image(systemName: "chevron.forward") }
                .disabled(model.index >= model.paths.count - 1)
        }
        .foregroundStyle(Color(hex: theme.text))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

struct TocSheet: View {
    @ObservedObject var model: ReaderModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                if let pkg = model.package, !pkg.toc.isEmpty {
                    ForEach(pkg.toc) { entry in
                        Button {
                            model.open(path: entry.path, fragment: entry.fragment)
                            isPresented = false
                        } label: {
                            Text(entry.title)
                                .padding(.leading, CGFloat(min(entry.level, 4)) * 16)
                                .foregroundStyle(entry.path == model.currentPath ? Palette.indigo : Color.primary)
                        }
                    }
                } else {
                    ForEach(Array(model.paths.enumerated()), id: \.offset) { i, _ in
                        Button(String(format: L("Chapter %d"), i + 1)) {
                            model.go(to: i)
                            isPresented = false
                        }
                    }
                }
            }
            .navigationTitle(L("Contents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { isPresented = false } } }
        }
    }
}

struct SearchSheet: View {
    @ObservedObject var model: ReaderModel
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                if busy { ProgressView() }
                ForEach(hits) { hit in
                    Button {
                        model.go(to: hit.chapter)
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.title).font(.caption).foregroundStyle(.secondary)
                            Text(hit.snippet).font(.subheadline).foregroundStyle(.primary).lineLimit(3)
                        }
                    }
                }
                if !busy && hits.isEmpty && query.count >= 2 {
                    Text(L("No results")).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L("Search in this book"))
            .onSubmit(of: .search) { Task { await run() } }
            .navigationTitle(L("Search"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { isPresented = false } } }
            .task { await model.prepareSearch() }
        }
    }

    private func run() async {
        let q = EpubText.fold(query.trimmingCharacters(in: .whitespaces))
        guard q.count >= 2 else { hits = []; return }
        busy = true
        await model.prepareSearch()
        let chapters = model.searchChapters ?? []
        let found = await Task.detached(priority: .userInitiated) { () -> [SearchHit] in
            var result: [SearchHit] = []
            for ch in chapters {
                for block in ch.blocks {
                    if case .image = block.kind { continue }
                    let folded = EpubText.fold(block.text)
                    guard let range = folded.range(of: q) else { continue }
                    let offset = folded.distance(from: folded.startIndex, to: range.lowerBound)
                    let text = block.text
                    let start = text.index(text.startIndex, offsetBy: max(0, min(offset - 40, text.count)), limitedBy: text.endIndex) ?? text.startIndex
                    let snippet = String(text[start...].prefix(160))
                    result.append(SearchHit(chapter: ch.index, title: ch.title, snippet: snippet))
                    if result.count >= 200 { return result }
                }
            }
            return result
        }.value
        hits = found
        busy = false
    }
}

struct ReaderSettingsSheet: View {
    @Binding var fontSize: Double
    @Binding var themeRaw: String
    @Binding var serif: Bool
    @Binding var lineHeight: Double
    @Binding var margin: Double

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Text size")) {
                    HStack {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $fontSize, in: 14...34, step: 1)
                        Image(systemName: "textformat.size.larger")
                    }
                }
                Section(L("Theme")) {
                    Picker(L("Theme"), selection: $themeRaw) {
                        ForEach(ReaderTheme.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section(L("Font")) {
                    Picker(L("Font"), selection: $serif) {
                        Text(L("Serif")).tag(true)
                        Text(L("Sans-serif")).tag(false)
                    }
                    .pickerStyle(.segmented)
                }
                Section(L("Spacing")) {
                    HStack {
                        Text(L("Lines"))
                        Slider(value: $lineHeight, in: 1.3...2.1, step: 0.1)
                    }
                    HStack {
                        Text(L("Margins"))
                        Slider(value: $margin, in: 6...48, step: 2)
                    }
                }
            }
            .navigationTitle(L("Appearance"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
