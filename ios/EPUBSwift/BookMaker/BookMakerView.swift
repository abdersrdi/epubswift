import PhotosUI
import SwiftUI

private let bookLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("ar", "العربية"), ("fr", "Français"), ("es", "Español"), ("de", "Deutsch"), ("tr", "Türkçe"),
]

/// The Create tab: the books you are writing. Writing is free; exports have a monthly allowance on the free plan.
struct BookMakerView: View {
    @ObservedObject private var store = BookStore.shared
    @State private var path: [UUID] = []

    private var defaultLanguage: String {
        Locale.preferredLanguages.first?.hasPrefix("ar") == true ? "ar" : "en"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.books.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "square.and.pencil").font(.largeTitle).foregroundStyle(Palette.indigo)
                        Text(L("Write your own book")).font(.title3.weight(.semibold))
                        Text(L("Add chapters, pictures and a cover, then export it as an EPUB, PDF, TXT or Word file. It works on your phone and your book never leaves your device."))
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button { newBook() } label: { Label(L("Start a new book"), systemImage: "plus") }
                            .buttonStyle(.borderedProminent).padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(store.books) { book in
                    NavigationLink(value: book.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(book.displayTitle).font(.headline).lineLimit(1)
                            Text(String(format: L("%d chapters, %d words"), book.chapters.count, book.wordCount))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.books[$0].id }
                    ids.forEach { store.delete($0) }
                }
            }
            .navigationTitle(L("Create"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newBook() } label: { Label(L("New book"), systemImage: "plus") }
                }
            }
            .navigationDestination(for: UUID.self) { id in BookEditorView(bookID: id) }
            .safeAreaInset(edge: .bottom) { BannerBar() }
        }
    }

    private func newBook() {
        let book = store.create(language: defaultLanguage)
        path.append(book.id)
    }
}

struct BookEditorView: View {
    let bookID: UUID
    @ObservedObject private var store = BookStore.shared
    @State private var book: BookProject
    @State private var showExport = false
    @State private var coverItem: PhotosPickerItem?
    @State private var problem: String?

    init(bookID: UUID) {
        self.bookID = bookID
        _book = State(initialValue: BookStore.shared.book(bookID) ?? .blank())
    }

    var body: some View {
        Form {
            Section(L("Book")) {
                TextField(L("Title"), text: $book.title)
                TextField(L("Author"), text: $book.author)
                Picker(L("Language"), selection: $book.language) {
                    ForEach(bookLanguages, id: \.code) { Text($0.name).tag($0.code) }
                }
            }

            Section(L("Cover")) {
                HStack(spacing: 14) {
                    if let id = book.coverImageID, let image = store.thumbnail(id, book: bookID) {
                        Image(uiImage: image).resizable().scaledToFit().frame(height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.15)).frame(width: 60, height: 90)
                            .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                    }
                    PhotosPicker(selection: $coverItem, matching: .images) {
                        Label(book.coverImageID == nil ? L("Choose a cover") : L("Change the cover"), systemImage: "photo.badge.plus")
                    }
                }
                if book.coverImageID != nil {
                    Button(L("Remove the cover"), role: .destructive) { book.coverImageID = nil }
                }
            }

            Section(L("Chapters")) {
                ForEach($book.chapters) { $chapter in
                    NavigationLink {
                        ChapterEditorView(book: $book, chapterID: chapter.id, bookID: bookID)
                    } label: {
                        let index = book.chapters.firstIndex { $0.id == chapter.id } ?? 0
                        Text(book.chapterTitle(index))
                    }
                }
                .onDelete { book.chapters.remove(atOffsets: $0) }
                .onMove { book.chapters.move(fromOffsets: $0, toOffset: $1) }
                Button { book.chapters.append(BookChapter(title: "", blocks: [.text("")])) } label: {
                    Label(L("Add a chapter"), systemImage: "plus")
                }
            }

            Section {
                Text(String(format: L("%d words"), book.wordCount)).font(.footnote).foregroundStyle(.secondary)
                if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(book.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showExport = true } label: { Label(L("Export"), systemImage: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .onChange(of: book) { _, new in store.save(new) }
        .onChange(of: coverItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let id = store.addImage(data, to: bookID) {
                    book.coverImageID = id
                    problem = nil
                } else {
                    problem = L("This picture could not be opened.")
                }
                coverItem = nil
            }
        }
        .sheet(isPresented: $showExport) { BookExportSheet(book: book) }
    }
}

struct ChapterEditorView: View {
    @Binding var book: BookProject
    let chapterID: UUID
    let bookID: UUID
    @ObservedObject private var store = BookStore.shared
    @State private var pickerItem: PhotosPickerItem?
    @State private var problem: String?

    private var index: Int? { book.chapters.firstIndex { $0.id == chapterID } }

    var body: some View {
        if let i = index {
            List {
                Section(L("Chapter title")) {
                    TextField(String(format: L("Chapter %d"), i + 1), text: $book.chapters[i].title)
                }
                Section(L("Content")) {
                    ForEach(Array(book.chapters[i].blocks.enumerated()), id: \.offset) { offset, _ in
                        BlockRow(block: $book.chapters[i].blocks[offset], bookID: bookID, rtl: book.rtl)
                    }
                    .onDelete { book.chapters[i].blocks.remove(atOffsets: $0) }
                    .onMove { book.chapters[i].blocks.move(fromOffsets: $0, toOffset: $1) }
                }
                Section {
                    HStack(spacing: 16) {
                        Button { book.chapters[i].blocks.append(.text("")) } label: { Label(L("Text"), systemImage: "text.alignleft") }
                        Button { book.chapters[i].blocks.append(.heading("")) } label: { Label(L("Heading"), systemImage: "textformat.size") }
                        PhotosPicker(selection: $pickerItem, matching: .images) { Label(L("Picture"), systemImage: "photo") }
                    }
                    .buttonStyle(.bordered)
                    if let problem { Text(problem).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(book.chapterTitle(i))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let id = store.addImage(data, to: bookID),
                       let j = index {
                        book.chapters[j].blocks.append(.image(id: id, caption: ""))
                        problem = nil
                    } else {
                        problem = L("This picture could not be opened.")
                    }
                    pickerItem = nil
                }
            }
        } else {
            Text(L("This chapter was removed.")).foregroundStyle(.secondary)
        }
    }
}

private struct BlockRow: View {
    @Binding var block: BookBlock
    let bookID: UUID
    let rtl: Bool
    @ObservedObject private var store = BookStore.shared

    var body: some View {
        switch block {
        case .text(let text):
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(L("Start writing. Each new line is a new paragraph."))
                        .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                }
                TextEditor(text: Binding(get: { text }, set: { block = .text($0) }))
                    .frame(minHeight: 110)
                    .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            }
        case .heading(let text):
            TextField(L("Heading"), text: Binding(get: { text }, set: { block = .heading($0) }))
                .font(.headline)
        case .image(let id, let caption):
            VStack(alignment: .leading, spacing: 8) {
                if let image = store.thumbnail(id, book: bookID) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                TextField(L("Caption (optional)"), text: Binding(get: { caption }, set: { block = .image(id: id, caption: $0) }))
                    .font(.subheadline)
            }
        }
    }
}

/// Choose a format and export. The free plan has a monthly allowance; videos and Premium change it.
struct BookExportSheet: View {
    let book: BookProject
    @ObservedObject private var quota = BookQuotaStore.shared
    @ObservedObject private var ads = RewardedAds.shared
    @ObservedObject private var premium = Premium.shared
    @Environment(\.dismiss) private var dismiss

    @State private var format = BookFormat.epub
    @State private var working = false
    @State private var resultURL: URL?
    @State private var message: String?
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L("File type")) {
                    Picker(L("File type"), selection: $format) {
                        ForEach(BookFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(formatHelp).font(.footnote).foregroundStyle(.secondary)
                }

                Section(L("Your exports")) {
                    if premium.isPremium {
                        Label(L("Premium: unlimited exports, with no note at the end."), systemImage: "checkmark.seal").foregroundStyle(.green)
                    } else {
                        Text(String(format: L("%d of %d free exports left this month"), quota.exportsLeft, BookExportQuota.freePerMonth))
                        if quota.shouldWatermark {
                            Text(L("Free exports end with a small “Made with EPUBSwift” note."))
                                .font(.footnote).foregroundStyle(.secondary)
                            videoButton(L("Watch a video to remove the note")) { quota.earnCleanExport() }
                        } else {
                            Label(L("Your next export has no note."), systemImage: "checkmark.circle").foregroundStyle(.green)
                        }
                        videoButton(String(format: L("Watch videos for 1 more export (%d of %d)"), quota.videosTowardExtra, BookExportQuota.videosPerExtraExport)) {
                            if quota.watchVideoForExtraExport() { message = L("You earned one more export.") }
                        }
                        Button { showPaywall = true } label: { Label(L("Go Premium for unlimited exports"), systemImage: "star") }
                    }
                }

                Section {
                    Button { Task { await run() } } label: {
                        if working { ProgressView() } else { Label(String(format: L("Export as %@"), format.title), systemImage: "square.and.arrow.up.on.square") }
                    }
                    .disabled(working || !quota.canExport)
                    if !quota.canExport && !premium.isPremium {
                        Text(L("You have used this month's free exports. Watch videos for more, or go Premium.")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let url = resultURL {
                        ShareLink(item: url) { Label(String(format: L("Share %@"), url.lastPathComponent), systemImage: "square.and.arrow.up") }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(L("Export"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { dismiss() } } }
            .onAppear { ads.preload() }
            .sheet(isPresented: $showPaywall) { PaywallView() }
        }
    }

    private var formatHelp: String {
        switch format {
        case .epub: return L("A book file for e-readers and reading apps, including this one.")
        case .pdf: return L("A fixed-page document that looks the same everywhere.")
        case .txt: return L("Plain text with no pictures.")
        case .docx: return L("A Word document you can keep editing.")
        }
    }

    /// A button that plays one video and runs `reward` only if it was watched to the end.
    private func videoButton(_ title: String, reward: @escaping () -> Void) -> some View {
        Button {
            ads.show { earned in if earned { reward() } }
        } label: {
            Label(ads.isReady ? title : L("Video loading…"), systemImage: "play.rectangle")
        }
        .disabled(!ads.isReady)
    }

    private func run() async {
        let hasContent = book.wordCount > 0 || !book.imageIDs.isEmpty
        guard hasContent else { message = L("Write something first."); return }
        working = true
        message = nil
        resultURL = nil
        let watermark = quota.shouldWatermark
        let images = BookStore.shared.images(for: book)
        do {
            resultURL = try await BookExportService.export(book, images: images, format: format, watermark: watermark)
            quota.recordExport()
        } catch {
            message = error.localizedDescription
        }
        working = false
    }
}
