import Foundation

struct NavItem {
    var title: String
    var href: String
    var children: [NavItem] = []
}

enum NavBuilder {
    static func navXhtml(title: String, language: String, rtl: Bool, items: [NavItem]) -> String {
        func list(_ items: [NavItem]) -> String {
            var s = "<ol>\n"
            for it in items {
                s += "<li><a href=\"\(Xhtml.escape(it.href, attribute: true))\">\(Xhtml.escape(Xhtml.clean(it.title)))</a>"
                if !it.children.isEmpty { s += "\n" + list(it.children) }
                s += "</li>\n"
            }
            return s + "</ol>\n"
        }
        let body = "<nav epub:type=\"toc\" id=\"toc\">\n<h1>\(Xhtml.escape(Xhtml.clean(title)))</h1>\n\(list(items))</nav>"
        return Xhtml.page(title: title, language: language, rtl: rtl, body: body, css: nil)
    }

    static func ncx(id: String, title: String, items: [NavItem]) -> String {
        var counter = 0
        func points(_ items: [NavItem]) -> String {
            var s = ""
            for it in items {
                counter += 1
                s += "<navPoint id=\"np\(counter)\" playOrder=\"\(counter)\"><navLabel><text>\(Xhtml.escape(Xhtml.clean(it.title)))</text></navLabel><content src=\"\(Xhtml.escape(it.href, attribute: true))\"/>"
                s += points(it.children)
                s += "</navPoint>\n"
            }
            return s
        }
        let body = points(items)
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n<head><meta name=\"dtb:uid\" content=\"\(Xhtml.escape(id, attribute: true))\"/></head>\n<docTitle><text>\(Xhtml.escape(Xhtml.clean(title)))</text></docTitle>\n<navMap>\n\(body)</navMap>\n</ncx>\n"
    }
}

/// Builds a fresh EPUB 3 (with an NCX for older readers) from chapters, used by PDF to EPUB.
struct EpubBuilder {
    struct Chapter { var title: String; var body: String }

    var title: String
    var author: String
    var language: String
    var rtl: Bool
    var chapters: [Chapter]
    var images: [(name: String, data: Data)] = []
    var coverJPEG: Data?
    var notice: String?

    func build() -> Data {
        let w = ZipWriter()
        w.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        w.addText("META-INF/container.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n</container>\n")
        var css = "body{font-family:serif;line-height:1.55;margin:5%;"
        if rtl { css += "direction:rtl;text-align:right;" }
        css += "}\nh1,h2,h3{font-family:sans-serif;line-height:1.25;margin:1.4em 0 0.6em;}\np{margin:0 0 0.9em 0;}\nimg{max-width:100%;height:auto;display:block;margin:1em auto;}\n.notice{margin-top:3em;font-size:0.85em;color:#666;text-align:center;}\n"
        w.addText("OEBPS/style.css", css)

        var manifest = "<item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>\n"
        var spine = ""
        var nav: [NavItem] = []
        var coverId: String?

        if let cover = coverJPEG {
            w.add("OEBPS/images/cover.jpg", cover)
            manifest += "<item id=\"cover-image\" href=\"images/cover.jpg\" media-type=\"image/jpeg\" properties=\"cover-image\"/>\n"
            coverId = "cover-image"
        }
        for img in images {
            w.add("OEBPS/images/\(img.name)", img.data)
            manifest += "<item id=\"\(img.name.replacingOccurrences(of: ".", with: "-"))\" href=\"images/\(img.name)\" media-type=\"image/jpeg\"/>\n"
        }
        for (i, ch) in chapters.enumerated() {
            let file = String(format: "text/chapter-%03d.xhtml", i + 1)
            let id = String(format: "c%03d", i + 1)
            w.addText("OEBPS/\(file)", Xhtml.page(title: ch.title, language: language, rtl: rtl, body: ch.body, css: "../style.css"))
            manifest += "<item id=\"\(id)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"\(id)\"/>\n"
            nav.append(NavItem(title: ch.title, href: file))
        }
        if let notice {
            let body = "<div class=\"notice\"><p>\(Xhtml.escape(notice))</p></div>"
            w.addText("OEBPS/notice.xhtml", Xhtml.page(title: "Notice", language: language, rtl: rtl, body: body, css: "style.css"))
            manifest += "<item id=\"notice\" href=\"notice.xhtml\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"notice\"/>\n"
        }
        let bookId = "urn:uuid:\(UUID().uuidString.lowercased())"
        w.addText("OEBPS/nav.xhtml", NavBuilder.navXhtml(title: title, language: language, rtl: rtl, items: nav))
        w.addText("OEBPS/toc.ncx", NavBuilder.ncx(id: bookId, title: title, items: nav))

        let stamp = ISO8601DateFormatter().string(from: Date())
        var opf = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" xml:lang=\"\(language)\">\n"
        opf += "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n<dc:identifier id=\"bookid\">\(bookId)</dc:identifier>\n"
        opf += "<dc:title>\(Xhtml.escape(Xhtml.clean(title)))</dc:title>\n"
        if !author.isEmpty { opf += "<dc:creator>\(Xhtml.escape(Xhtml.clean(author)))</dc:creator>\n" }
        opf += "<dc:language>\(language)</dc:language>\n<meta property=\"dcterms:modified\">\(stamp)</meta>\n"
        if let coverId { opf += "<meta name=\"cover\" content=\"\(coverId)\"/>\n" }
        opf += "</metadata>\n<manifest>\n"
        opf += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n"
        opf += "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
        opf += manifest + "</manifest>\n<spine toc=\"ncx\"\(rtl ? " page-progression-direction=\"rtl\"" : "")>\n" + spine + "</spine>\n</package>\n"
        w.addText("OEBPS/content.opf", opf)
        return w.finish()
    }
}
