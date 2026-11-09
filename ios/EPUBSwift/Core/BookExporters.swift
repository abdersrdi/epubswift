import Foundation

enum BookFormat: String, CaseIterable, Identifiable {
    case epub, pdf, txt, docx
    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .epub: return "EPUB"
        case .pdf: return "PDF"
        case .txt: return "TXT"
        case .docx: return "Word"
        }
    }
}

/// Writes a book as EPUB, TXT or Word. (PDF is made from the EPUB with the app's existing converter.)
/// `watermark` is the note added at the end of free exports; nil leaves the book clean.
enum BookExporter {
    static let watermarkText = "Made with EPUBSwift"

    // MARK: EPUB

    static func epub(_ book: BookProject, images: [String: Data], watermark: String?) -> Data {
        // File names for the pictures, in order of first use.
        var names: [String: String] = [:]
        var files: [(name: String, data: Data)] = []
        var inText = Set<String>()
        for c in book.chapters { for b in c.blocks { if case .image(let id, _) = b { inText.insert(id) } } }
        for id in book.imageIDs where inText.contains(id) {
            guard let data = images[id] else { continue }
            let name = String(format: "img-%03d.jpg", files.count + 1)
            names[id] = name
            files.append((name, data))
        }

        var chapters: [EpubBuilder.Chapter] = []
        // A title page first, so the book opens like a book.
        var titleBody = "<div class=\"titlepage\"><h1>\(Xhtml.escape(Xhtml.clean(book.displayTitle)))</h1>"
        if !book.author.trimmingCharacters(in: .whitespaces).isEmpty {
            titleBody += "<p class=\"author\">\(Xhtml.escape(Xhtml.clean(book.author)))</p>"
        }
        titleBody += "</div>"
        chapters.append(EpubBuilder.Chapter(title: book.displayTitle, body: titleBody))

        for (i, chapter) in book.chapters.enumerated() {
            let title = book.chapterTitle(i)
            var body = "<h1>\(Xhtml.escape(Xhtml.clean(title)))</h1>\n"
            for block in chapter.blocks {
                switch block {
                case .text(let t):
                    for p in BookProject.paragraphs(t) { body += "<p>\(Xhtml.escape(Xhtml.clean(p)))</p>\n" }
                case .heading(let t):
                    let h = t.trimmingCharacters(in: .whitespaces)
                    if !h.isEmpty { body += "<h2>\(Xhtml.escape(Xhtml.clean(h)))</h2>\n" }
                case .image(let id, let caption):
                    guard let name = names[id] else { continue }
                    body += "<figure><img src=\"../images/\(name)\" alt=\"\(Xhtml.escape(Xhtml.clean(caption), attribute: true))\"/>"
                    let c = caption.trimmingCharacters(in: .whitespaces)
                    if !c.isEmpty { body += "<figcaption>\(Xhtml.escape(Xhtml.clean(c)))</figcaption>" }
                    body += "</figure>\n"
                }
            }
            chapters.append(EpubBuilder.Chapter(title: title, body: body))
        }

        let cover = book.coverImageID.flatMap { images[$0] }
        let builder = EpubBuilder(title: book.displayTitle, author: book.author, language: book.language, rtl: book.rtl,
                                  chapters: chapters, images: files, coverJPEG: cover, notice: watermark)
        return builder.build()
    }

    // MARK: TXT

    static func txt(_ book: BookProject, watermark: String?) -> Data {
        var out = book.displayTitle + "\n"
        let author = book.author.trimmingCharacters(in: .whitespaces)
        if !author.isEmpty { out += "\(author)\n" }
        for (i, chapter) in book.chapters.enumerated() {
            out += "\n\n" + book.chapterTitle(i) + "\n"
            for block in chapter.blocks {
                switch block {
                case .text(let t):
                    for p in BookProject.paragraphs(t) { out += "\n" + p + "\n" }
                case .heading(let t):
                    let h = t.trimmingCharacters(in: .whitespaces)
                    if !h.isEmpty { out += "\n" + h + "\n" }
                case .image(_, let caption):
                    let c = caption.trimmingCharacters(in: .whitespaces)
                    out += "\n[Image" + (c.isEmpty ? "" : ": \(c)") + "]\n"
                }
            }
        }
        if let watermark { out += "\n\n— \(watermark) —\n" }
        return Data(out.utf8)
    }

    // MARK: Word (.docx)

    /// Pixel size of a JPEG, read from its header, so pictures can be placed at the right proportions without decoding them.
    static func jpegSize(_ data: Data) -> (width: Int, height: Int)? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        while i + 9 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let isFrame = (0xC0...0xCF).contains(marker) && ![0xC4, 0xC8, 0xCC].contains(marker)
            if isFrame {
                let h = Int(b[i + 5]) << 8 | Int(b[i + 6]), w = Int(b[i + 7]) << 8 | Int(b[i + 8])
                return w > 0 && h > 0 ? (w, h) : nil
            }
            guard length >= 2 else { return nil }
            i += 2 + length
        }
        return nil
    }

    static func docx(_ book: BookProject, images: [String: Data], watermark: String?) -> Data {
        let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\""
        let bidi = book.rtl ? "<w:bidi/>" : ""
        let rtl = book.rtl ? "<w:rtl/>" : ""
        func esc(_ s: String) -> String { Xhtml.escape(Xhtml.clean(s)) }
        func para(_ text: String, style: String? = nil, pageBreakBefore: Bool = false, center: Bool = false) -> String {
            var ppr = ""
            if let style { ppr += "<w:pStyle w:val=\"\(style)\"/>" }
            if pageBreakBefore { ppr += "<w:pageBreakBefore/>" }
            ppr += bidi
            if center { ppr += "<w:jc w:val=\"center\"/>" }
            return "<w:p><w:pPr>\(ppr)</w:pPr><w:r><w:rPr>\(rtl)</w:rPr><w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r></w:p>"
        }

        // Pictures: file names and relationship ids in order of first use (the cover is not repeated inside the text).
        var media: [(id: String, name: String, rel: String, data: Data)] = []
        var mediaIndex: [String: Int] = [:]
        func register(_ id: String) -> Int? {
            if let i = mediaIndex[id] { return i }
            guard let data = images[id] else { return nil }
            let n = media.count + 1
            media.append((id, "image\(n).jpg", "rIdImg\(n)", data))
            mediaIndex[id] = media.count - 1
            return media.count - 1
        }
        func picture(_ index: Int, number: Int) -> String {
            let item = media[index]
            let size = jpegSize(item.data) ?? (480, 360)
            let maxW = 5_486_400.0, maxH = 6_400_800.0                  // 6 x 7 inches in EMU
            var w = Double(size.width) * 9525, h = Double(size.height) * 9525
            let scale = min(1, maxW / w, maxH / h)
            w = (w * scale).rounded(); h = (h * scale).rounded()
            let cx = Int(w), cy = Int(h)
            return "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(number)\" name=\"Picture \(number)\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(number)\" name=\"\(item.name)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(item.rel)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
        }

        var body = ""
        var pictureNumber = 0
        if let cover = book.coverImageID, let i = register(cover) {
            pictureNumber += 1
            body += picture(i, number: pictureNumber)
        }
        body += para(book.displayTitle, style: "Title")
        let author = book.author.trimmingCharacters(in: .whitespaces)
        if !author.isEmpty { body += para(author, style: "Subtitle") }

        for (ci, chapter) in book.chapters.enumerated() {
            body += para(book.chapterTitle(ci), style: "Heading1", pageBreakBefore: true)
            for block in chapter.blocks {
                switch block {
                case .text(let t):
                    for p in BookProject.paragraphs(t) { body += para(p) }
                case .heading(let t):
                    let h = t.trimmingCharacters(in: .whitespaces)
                    if !h.isEmpty { body += para(h, style: "Heading2") }
                case .image(let id, let caption):
                    guard let i = register(id) else { continue }
                    pictureNumber += 1
                    body += picture(i, number: pictureNumber)
                    let c = caption.trimmingCharacters(in: .whitespaces)
                    if !c.isEmpty { body += para(c, style: "Caption", center: true) }
                }
            }
        }
        if let watermark { body += para("— \(watermark) —", style: "Caption", center: true) }

        let sect = "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/>\(book.rtl ? "<w:bidi/>" : "")</w:sectPr>"
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<w:document \(ns)><w:body>\(body)\(sect)</w:body></w:document>"

        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia" w:cs="Arial"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="300" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:before="2400" w:after="240"/><w:jc w:val="center"/></w:pPr><w:rPr><w:b/><w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:i/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="480" w:after="240"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="320" w:after="160"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:jc w:val="center"/></w:pPr><w:rPr><w:i/><w:sz w:val="20"/><w:szCs w:val="20"/></w:rPr></w:style></w:styles>
        """

        var docRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
        for m in media {
            docRels += "<Relationship Id=\"\(m.rel)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(m.name)\"/>"
        }
        docRels += "</Relationships>"

        let contentTypes = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/></Types>"

        let rootRels = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/></Relationships>"

        let stamp = ISO8601DateFormatter().string(from: Date())
        let core = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\"><dc:title>\(esc(book.displayTitle))</dc:title><dc:creator>\(esc(author))</dc:creator><dc:language>\(esc(book.language))</dc:language><dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created></cp:coreProperties>"

        let zip = ZipWriter()
        zip.addText("[Content_Types].xml", contentTypes)
        zip.addText("_rels/.rels", rootRels)
        zip.addText("word/document.xml", document)
        zip.addText("word/styles.xml", styles)
        zip.addText("word/_rels/document.xml.rels", docRels)
        zip.addText("docProps/core.xml", core)
        for m in media { zip.add("word/media/\(m.name)", m.data, compress: false) }
        return zip.finish()
    }
}
