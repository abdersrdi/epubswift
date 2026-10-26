import SwiftUI
import UniformTypeIdentifiers

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, added
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: return L("Recently read")
        case .title: return L("Title")
        case .author: return L("Author")
        case .added: return L("Recently added")
        }
    }
}

struct BookCoverView: View {
    let book: BookRecord

    var body: some View {
        ZStack {
            if let image = CoverCache.image(for: book) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Palette.gradient
                VStack(spacing: 6) {
                    Image(systemName: "book.closed.fill").font(.title2)
                    Text(book.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(4)
                }
                .foregroundStyle(.white)
                .padding(8)
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

struct LibraryView: View {
    @StateObject private var store = LibraryStore.shared
    @ObservedObject private var premium = Premium.shared
    @AppStorage("library_sort") private var sortRaw = LibrarySort.recent.rawValue
    @State private var search = ""
    @State private var picking = false
    @State private var openBook: BookRecord?
    @State private var deleting: BookRecord?

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .recent }

    private var filtered: [BookRecord] {
        let q = EpubText.fold(search.trimmingCharacters(in: .whitespaces))
        var list = store.books
        if !q.isEmpty {
            list = list.filter { EpubText.fold($0.title).contains(q) || EpubText.fold($0.authors).contains(q) }
        }
        switch sort {
        case .recent: return list.sorted { ($0.lastOpened ?? $0.addedAt) > ($1.lastOpened ?? $1.addedAt) }
        case .title: return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author: return list.sorted { $0.authors.localizedCaseInsensitiveCompare($1.authors) == .orderedAscending }
        case .added: return list.sorted { $0.addedAt > $1.addedAt }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 14, alignment: .top)]

    var body: some View {
        NavigationStack {
            ZStack {
                if store.books.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 14) {
                            NativeAdBar()
                            LazyVGrid(columns: columns, spacing: 18) {
                                ForEach(filtered) { book in
                                    Button { openBook = book } label: { cell(book) }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            Button(role: .destructive) { deleting = book } label: {
                                                Label(L("Remove from library"), systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                        .padding(16)
                    }
                    .searchable(text: $search, prompt: L("Search your books"))
                }
                if store.importing {
                    ProgressView(L("Importing…"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle(L("Library"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker(L("Sort by"), selection: $sortRaw) {
                            ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { picking = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L("Add books"))
                }
            }
            .safeAreaInset(edge: .bottom) { BannerBar() }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.epub, UTType(filenameExtension: "epub") ?? .data],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { Task { await store.importFiles(urls) } }
            }
            .fullScreenCover(item: $openBook) { book in
                ReaderView(book: book)
            }
            .alert(L("Remove this book?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button(L("Remove"), role: .destructive) { if let b = deleting { store.delete(b) }; deleting = nil }
                Button(L("Cancel"), role: .cancel) { deleting = nil }
            } message: {
                Text(deleting?.title ?? "")
            }
            .alert(L("Import problem"), isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) { store.message = nil }
            } message: {
                Text(store.message ?? "")
            }
        }
    }

    private func cell(_ book: BookRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCoverView(book: book)
            Text(book.title).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
            if !book.authors.isEmpty {
                Text(book.authors).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if book.progress > 0.005 {
                ProgressView(value: min(1, book.progress)).tint(Palette.indigo)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 56))
                .foregroundStyle(Palette.gradient)
            Text(L("Your library is empty")).font(.title3.weight(.semibold))
            Text(L("Add EPUB books from the Files app. Reading is always free and works offline."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { picking = true } label: {
                Label(L("Add books"), systemImage: "plus")
                    .font(.headline).padding(.horizontal, 22).padding(.vertical, 12)
                    .background(Palette.gradient, in: Capsule()).foregroundStyle(.white)
            }
        }
        .padding(32)
    }
}
