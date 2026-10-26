import Foundation
import UIKit

enum EpubMerger {
    static func merge(urls: [URL], title: String, author: String, progress: (Double) -> Void) throws -> Data {
        guard urls.count >= 2 else { throw EpubError.failed(L("Select at least two EPUB files.")) }
        let w = ZipWriter()
        w.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        w.addText("META-INF/container.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n</container>\n")
        var manifest = ""
        var spine = ""
        var nav: [NavItem] = []
        var authors: [String] = []
        var language = "en"
        var rtl = false
        var coverID: String?

        for (i, url) in urls.enumerated() {
            progress(Double(i) / Double(urls.count))
            let pkg = try EpubPackage(url: url)
            let prefix = "book\(i + 1)/"
            let hasObfuscation = pkg.archive.has("META-INF/encryption.xml")
            if i == 0 {
                language = pkg.language.isEmpty ? "en" : pkg.language
                rtl = pkg.rtl
            }
            for a in pkg.authors where !authors.contains(a) { authors.append(a) }
            var kept = Set<String>()
            for item in pkg.manifest {
                if item.properties.split(separator: " ").contains("nav") || item.mediaType == "application/x-dtbncx+xml" { continue }
                if hasObfuscation && item.mediaType.contains("font") { continue }
                guard pkg.archive.has(item.path), let data = try? pkg.archive.read(item.path) else { continue }
                w.add("OEBPS/" + prefix + item.path, data)
                let id = "b\(i + 1)_\(item.id)"
                kept.insert(item.id)
                var props = item.properties.split(separator: " ").map(String.init).filter { $0 != "cover-image" }
                if i == 0, item.path == pkg.coverPath { props.append("cover-image"); coverID = id }
                manifest += "<item id=\"\(Xhtml.escape(id, attribute: true))\" href=\"\(Xhtml.escape(EpubPath.encode(prefix + item.path), attribute: true))\" media-type=\"\(Xhtml.escape(item.mediaType, attribute: true))\""
                if !props.isEmpty { manifest += " properties=\"\(props.joined(separator: " "))\"" }
                manifest += "/>\n"
            }
            for id in pkg.spineIDs where kept.contains(id) {
                spine += "<itemref idref=\"b\(i + 1)_\(Xhtml.escape(id, attribute: true))\"/>\n"
            }
            guard let firstPath = pkg.spinePaths.first else { continue }
            var children: [NavItem] = []
            for entry in pkg.toc where entry.level == 0 || entry.level == 1 {
                let href = EpubPath.encode(prefix + entry.path) + (entry.fragment.map { "#" + $0 } ?? "")
                children.append(NavItem(title: entry.title, href: href))
            }
            nav.append(NavItem(title: pkg.displayTitle, href: EpubPath.encode(prefix + firstPath), children: children))
        }
        let bookTitle = title.trimmingCharacters(in: .whitespaces).isEmpty ? L("Merged book") : title.trimmingCharacters(in: .whitespaces)
        let creator = author.trimmingCharacters(in: .whitespaces).isEmpty ? authors.joined(separator: ", ") : author
        let bookId = "urn:uuid:\(UUID().uuidString.lowercased())"
        w.addText("OEBPS/nav.xhtml", NavBuilder.navXhtml(title: bookTitle, language: language, rtl: rtl, items: nav))
        w.addText("OEBPS/toc.ncx", NavBuilder.ncx(id: bookId, title: bookTitle, items: nav))
        var opf = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"bookid\" xml:lang=\"\(language)\">\n"
        opf += "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n<dc:identifier id=\"bookid\">\(bookId)</dc:identifier>\n"
        opf += "<dc:title>\(Xhtml.escape(Xhtml.clean(bookTitle)))</dc:title>\n"
        if !creator.isEmpty { opf += "<dc:creator>\(Xhtml.escape(Xhtml.clean(creator)))</dc:creator>\n" }
        opf += "<dc:language>\(language)</dc:language>\n<meta property=\"dcterms:modified\">\(ISO8601DateFormatter().string(from: Date()))</meta>\n"
        if let coverID { opf += "<meta name=\"cover\" content=\"\(Xhtml.escape(coverID, attribute: true))\"/>\n" }
        opf += "</metadata>\n<manifest>\n<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n"
        opf += manifest + "</manifest>\n<spine toc=\"ncx\"\(rtl ? " page-progression-direction=\"rtl\"" : "")>\n" + spine + "</spine>\n</package>\n"
        w.addText("OEBPS/content.opf", opf)
        progress(1)
        return w.finish()
    }
}

extension EpubPath {
    /// Percent-encodes each path segment for use in an href.
    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
    }
}

enum EpubMarkdown {
    /// Returns the Markdown text and, when requested, the images it refers to (path in zip -> file name).
    static func make(_ pkg: EpubPackage, includeImages: Bool, progress: ((Double) -> Void)? = nil) -> (String, [(String, Data)]) {
        let chapters = EpubText.chapters(pkg, progress: progress)
        var md = ""
        if !pkg.title.isEmpty { md += "# \(pkg.title)\n\n" }
        if !pkg.authors.isEmpty { md += "*\(pkg.authors.joined(separator: ", "))*\n\n" }
        var images: [(String, Data)] = []
        var names: [String: String] = [:]
        for ch in chapters {
            for b in ch.blocks {
                switch b.kind {
                case .heading(let level):
                    md += String(repeating: "#", count: min(6, level + 1)) + " " + escape(b.text) + "\n\n"
                case .paragraph:
                    md += escape(b.text) + "\n\n"
                case .listItem:
                    md += "- " + escape(b.text) + "\n"
                case .image:
                    guard includeImages, let src = b.src, !src.hasPrefix("http"), !src.hasPrefix("data:") else { continue }
                    let path = EpubPath.resolve(base: EpubPath.dir(ch.path), href: src)
                    if names[path] == nil {
                        guard let data = try? pkg.archive.read(path) else { continue }
                        let name = String(format: "img-%03d.%@", images.count + 1, (path as NSString).pathExtension.lowercased())
                        names[path] = name
                        images.append((name, data))
                    }
                    md += "![\(b.text)](images/\(names[path] ?? ""))\n\n"
                }
            }
            if let last = md.last, last != "\n" { md += "\n" }
            if md.hasSuffix("\n") && !md.hasSuffix("\n\n") { md += "\n" }
        }
        return (md, images)
    }

    private static func escape(_ s: String) -> String {
        var t = s
        if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("- ") { t = "\\" + t }
        return t
    }

    static func zip(markdown: String, images: [(String, Data)]) -> Data {
        let w = ZipWriter()
        w.addText("book.md", markdown)
        for (name, data) in images { w.add("images/" + name, data) }
        return w.finish()
    }
}
