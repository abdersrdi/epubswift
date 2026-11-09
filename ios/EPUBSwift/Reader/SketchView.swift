import PencilKit
import SwiftUI
import UIKit

/// A sketch being made or edited: the picture of the page and the drawing on top of it.
struct SketchDraft: Identifiable {
    var note: SketchNote
    var backdrop: UIImage
    var drawing: PKDrawing
    var isNew: Bool
    var id: UUID { note.id }
}

enum SketchRender {
    /// The page picture with the drawing over it, as one image (for the list and for sharing).
    static func composite(backdrop: UIImage, drawing: PKDrawing) -> UIImage {
        let size = backdrop.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = backdrop.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            backdrop.draw(in: CGRect(origin: .zero, size: size))
            let ink = drawing.image(from: CGRect(origin: .zero, size: size), scale: backdrop.scale)
            ink.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Draw on a page with Apple Pencil (or a finger). The drawing is kept in the page picture's own point coordinates, so it looks
/// the same however large the editor is shown.
struct SketchEditor: View {
    @State var draft: SketchDraft
    let onSave: (SketchDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color(white: 0.92).ignoresSafeArea()
                    ZStack {
                        Image(uiImage: draft.backdrop).resizable().scaledToFit()
                        SketchCanvas(drawing: $draft.drawing, baseSize: draft.backdrop.size)
                    }
                    .aspectRatio(draft.backdrop.size, contentMode: .fit)
                    .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                    .shadow(radius: 3)
                }
            }
            .navigationTitle(L("Sketch"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("Save")) { onSave(draft); dismiss() }.bold().disabled(draft.drawing.strokes.isEmpty && draft.isNew)
                }
            }
        }
    }
}

/// A canvas that reports its size whenever it is laid out, so the drawing can be scaled to match.
private final class SizedCanvas: PKCanvasView {
    var onLayout: ((CGSize) -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

struct SketchCanvas: UIViewRepresentable {
    /// In the page picture's coordinates.
    @Binding var drawing: PKDrawing
    let baseSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = SizedCanvas()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput                                 // Apple Pencil, or a finger
        canvas.overrideUserInterfaceStyle = .light                       // ink keeps the colour that was picked
        canvas.delegate = context.coordinator
        canvas.onLayout = { [weak coordinator = context.coordinator, weak canvas] size in
            guard let coordinator, let canvas else { return }
            coordinator.laidOut(canvas, size: size)
        }
        context.coordinator.attachToolPicker(to: canvas)
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) { context.coordinator.parent = self }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SketchCanvas
        private let picker = PKToolPicker()
        private var shownWidth: CGFloat = 0
        private var loading = false

        init(_ parent: SketchCanvas) { self.parent = parent }

        func attachToolPicker(to canvas: PKCanvasView) {
            DispatchQueue.main.async { [picker] in
                picker.setVisible(true, forFirstResponder: canvas)
                picker.addObserver(canvas)
                canvas.becomeFirstResponder()
            }
        }

        private var scale: CGFloat { parent.baseSize.width > 0 ? shownWidth / parent.baseSize.width : 1 }

        /// Shows the drawing at the size the canvas has now.
        func laidOut(_ canvas: PKCanvasView, size: CGSize) {
            guard size.width > 0, abs(size.width - shownWidth) > 0.5 else { return }
            shownWidth = size.width
            loading = true
            canvas.drawing = parent.drawing.transformed(using: CGAffineTransform(scaleX: scale, y: scale))
            loading = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !loading, scale > 0 else { return }
            parent.drawing = canvasView.drawing.transformed(using: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        }
    }
}
