import SwiftUI

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
                        onPrev: { model.previous() })
                    footer(theme)
                }
                BannerBar()
            }
        }
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .task {
            await model.load(style: style)
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
