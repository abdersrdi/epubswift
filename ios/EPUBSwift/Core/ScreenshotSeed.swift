#if DEBUG
import PencilKit
import UIKit

/// Sample content for the screenshot and screen-recording workflow (debug builds only; never in the App Store build).
/// A short book to show in the Create tab, and a Pencil drawing for the sketch screen.
enum ScreenshotSeed {
    static let sampleBookID = UUID(uuidString: "5C1A0B9E-7D3E-4F10-9A55-0E6B3C2D1A01")!

    /// A cover drawn in code, so no artwork is needed.
    static func coverImage() -> UIImage {
        let size = CGSize(width: 800, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [UIColor(red: 0.30, green: 0.27, blue: 0.90, alpha: 1).cgColor, UIColor(red: 0.55, green: 0.25, blue: 0.92, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor(white: 1, alpha: 0.18).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 420, y: 80, width: 520, height: 520))
            let title = "The Lantern\nKeeper" as NSString
            let style = NSMutableParagraphStyle(); style.alignment = .center
            title.draw(in: CGRect(x: 40, y: 470, width: 720, height: 300), withAttributes: [
                .font: UIFont(name: "Georgia-Bold", size: 96) ?? UIFont.boldSystemFont(ofSize: 96),
                .foregroundColor: UIColor.white, .paragraphStyle: style])
            ("A short story" as NSString).draw(in: CGRect(x: 40, y: 800, width: 720, height: 60), withAttributes: [
                .font: UIFont.italicSystemFont(ofSize: 40), .foregroundColor: UIColor(white: 1, alpha: 0.85), .paragraphStyle: style])
        }
    }

    /// A picture for inside the book.
    static func illustration() -> UIImage {
        let size = CGSize(width: 1000, height: 640)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.98, green: 0.80, blue: 0.40, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.16, green: 0.14, blue: 0.40, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 420, width: size.width, height: 220))
            UIColor(red: 1, green: 0.96, blue: 0.80, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 690, y: 90, width: 150, height: 150))
        }
    }

    @MainActor
    static func seedBook() {
        let store = BookStore.shared
        store.delete(sampleBookID)
        guard let cover = coverImage().jpegData(compressionQuality: 0.9), let pic = illustration().jpegData(compressionQuality: 0.9),
              let coverID = store.addImage(cover, to: sampleBookID), let picID = store.addImage(pic, to: sampleBookID) else { return }
        let book = BookProject(
            id: sampleBookID, title: "The Lantern Keeper", author: "Sam Writer", language: "en",
            chapters: [
                BookChapter(title: "The Last Light", blocks: [
                    .text("The lighthouse had been dark for nine years when Mara climbed its stairs for the first time.\nShe carried a lantern, a loaf of bread and a letter from her grandfather."),
                    .image(id: picID, caption: "The cliffs at dusk"),
                    .text("At the top, the great lamp waited under a sheet of dust, as patient as a sleeping animal."),
                ]),
                BookChapter(title: "What the Sea Kept", blocks: [
                    .heading("Low tide"),
                    .text("By morning the water had pulled back far enough to show the wreck."),
                ]),
                BookChapter(title: "A Light for Others", blocks: [.text("She lit the lamp at sunset.")]),
            ],
            coverImageID: coverID)
        store.save(book)
    }

    /// A few pen strokes in red over a page: a loop round some text, an underline and an arrow. Coordinates are in the page picture's points.
    static func sampleDrawing(for size: CGSize) -> PKDrawing {
        func stroke(_ points: [CGPoint], width: CGFloat = 5) -> PKStroke {
            var t: TimeInterval = 0
            let controls = points.map { p -> PKStrokePoint in
                defer { t += 0.012 }
                return PKStrokePoint(location: p, timeOffset: t, size: CGSize(width: width, height: width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: UIColor(red: 0.90, green: 0.12, blue: 0.20, alpha: 1)),
                            path: PKStrokePath(controlPoints: controls, creationDate: Date()))
        }
        let w = size.width, h = size.height
        // A loop around a passage in the upper middle of the page.
        let centre = CGPoint(x: w * 0.5, y: h * 0.33), rx = w * 0.40, ry = h * 0.075
        let loop = (0...48).map { i -> CGPoint in
            let a = Double(i) / 48 * 2 * .pi * 1.04 - .pi / 2
            return CGPoint(x: centre.x + rx * CGFloat(cos(a)), y: centre.y + ry * CGFloat(sin(a)))
        }
        // A wavy underline lower down.
        let underline = (0...30).map { i -> CGPoint in
            let x = w * 0.15 + w * 0.55 * CGFloat(i) / 30
            return CGPoint(x: x, y: h * 0.52 + CGFloat(sin(Double(i) / 3)) * 5)
        }
        // An arrow from the margin to the loop.
        let shaft = (0...12).map { i in CGPoint(x: w * 0.06 + (w * 0.12) * CGFloat(i) / 12, y: h * 0.45 - (h * 0.08) * CGFloat(i) / 12) }
        let tip = shaft.last!
        let head1 = [tip, CGPoint(x: tip.x - 22, y: tip.y + 4), CGPoint(x: tip.x - 8, y: tip.y + 22)]
        return PKDrawing(strokes: [stroke(loop), stroke(underline), stroke(shaft), stroke(head1)])
    }
}
#endif
