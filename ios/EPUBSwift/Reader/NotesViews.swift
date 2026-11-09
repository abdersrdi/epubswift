import SwiftUI

extension HighlightColor {
    var swatch: Color {
        switch self {
        case .yellow: return Color(red: 1, green: 0.84, blue: 0.04)
        case .green: return Color(red: 0.2, green: 0.78, blue: 0.35)
        case .blue: return Color(red: 0.04, green: 0.52, blue: 1)
        case .pink: return Color(red: 1, green: 0.22, blue: 0.37)
        }
    }

    var title: String {
        switch self {
        case .yellow: return L("yellow")
        case .green: return L("green")
        case .blue: return L("blue")
        case .pink: return L("pink")
        }
    }
}

/// The highlights and notes of the open book, in reading order. Tapping one jumps to it.
struct NotesSheet: View {
    @ObservedObject var model: ReaderModel
    @Binding var isPresented: Bool

    private var ordered: [Annotation] { AnnotationExport.ordered(model.annotations) }

    private var markdown: String {
        AnnotationExport.markdown(title: model.package?.displayTitle ?? model.book.title, authors: model.book.authors,
                                  annotations: model.annotations, chapterTitle: { model.chapterTitle(at: $0) },
                                  heading: L("Notes and highlights"), noteLabel: L("Note"))
    }

    var body: some View {
        NavigationStack {
            List {
                if ordered.isEmpty {
                    Text(L("No highlights yet. Select text in the book to highlight it or to add a note."))
                        .foregroundStyle(.secondary)
                }
                ForEach(ordered) { a in
                    Button {
                        model.show(a)
                        isPresented = false
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            RoundedRectangle(cornerRadius: 2).fill(a.color.swatch).frame(width: 4)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.chapterTitle(at: a.chapterIndex)).font(.caption).foregroundStyle(.secondary)
                                Text(a.quote).font(.subheadline).foregroundStyle(.primary).lineLimit(4)
                                if a.hasNote {
                                    Text(a.note).font(.footnote.italic()).foregroundStyle(Palette.indigo).lineLimit(4)
                                }
                            }
                        }
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { ordered[$0].id }
                    ids.forEach { model.deleteAnnotation($0) }
                }
            }
            .navigationTitle(L("Notes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !ordered.isEmpty {
                        ShareLink(item: markdown, subject: Text(model.book.title)) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { isPresented = false } }
            }
        }
    }
}

/// Edit the note and colour of one highlight, or delete it.
struct NoteEditor: View {
    @State var annotation: Annotation
    let isNew: Bool
    let onSave: (Annotation) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(annotation.quote).font(.subheadline).lineLimit(6) }
                Section(L("Your note")) {
                    TextEditor(text: $annotation.note).frame(minHeight: 120)
                }
                Section(L("Colour")) {
                    HStack(spacing: 16) {
                        ForEach(HighlightColor.allCases) { c in
                            Button { annotation.color = c } label: {
                                Circle().fill(c.swatch).frame(width: 32, height: 32)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: annotation.color == c ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(c.title)
                        }
                    }
                }
                if let onDelete {
                    Section {
                        Button(L("Delete highlight"), role: .destructive) { onDelete(); dismiss() }
                    }
                }
            }
            .navigationTitle(isNew ? L("New note") : L("Note"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button(L("Save")) { onSave(annotation); dismiss() }.bold() }
            }
        }
    }
}
