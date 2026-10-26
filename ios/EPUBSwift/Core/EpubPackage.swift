import Foundation

struct ManifestItem {
    var id: String
    var href: String
    var path: String
    var mediaType: String
    var properties: String
}

struct TocEntry: Identifiable {
    let id = UUID()
    var title: String
    var path: String
    var fragment: String?
    var level: Int
}

enum EpubPath {
    static func dir(_ p: String) -> String {
        guard let r = p.lastIndex(of: "/") else { return "" }
        return String(p[..<r])
    }

    static func fragment(_ href: String) -> String? {
        guard let q = href.firstIndex(of: "#") else { return nil }
        let f = String(href[href.index(after: q)...])
        return f.isEmpty ? nil : f
    }

    static func resolve(base: String, href: String) -> String {
        var h = href
        if let q = h.firstIndex(of: "#") { h = String(h[..<q]) }
        h = h.removingPercentEncoding ?? h
        var parts: [String] = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        if h.hasPrefix("/") { parts = [] }
        for seg in h.split(separator: "/") {
            if seg == "." { continue }
            if seg == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(String(seg)) }
        }
        return parts.joined(separator: "/")
    }

    /// Relative reference from a directory to a target path.
    static func relative(from baseDir: String, to path: String) -> String {
        let a = baseDir.isEmpty ? [] : baseDir.split(separator: "/").map(String.init)
        let b = path.split(separator: "/").map(String.init)
        var i = 0
        while i < a.count, i < b.count - 1, a[i] == b[i] { i += 1 }
        let ups = Array(repeating: "..", count: a.count - i)
        return (ups + b[i...]).joined(separator: "/")
    }
}

/// A parsed EPUB: container -> OPF -> metadata, manifest, spine, navigation and cover.
final class EpubPackage {
    let archive: ZipArchive
    let opfPath: String
    let opfDir: String
    let opfRoot: XNode

    var title = ""
    var authors: [String] = []
    var language = ""
    var publisher = ""
    var descriptionText = ""
    var identifier = ""
    var manifest: [ManifestItem] = []
    var spineIDs: [String] = []
    var rtl = false
    var coverPath: String?
    var toc: [TocEntry] = []
    var isEpub3 = false

    var spinePaths: [String] {
        spineIDs.compactMap { id in manifest.first { $0.id == id }?.path }
    }

    static func isEncrypted(_ archive: ZipArchive) -> Bool {
        guard archive.has("META-INF/encryption.xml"),
              let data = try? archive.read("META-INF/encryption.xml"),
              let root = XMLTree.parse(data) else { return archive.has("META-INF/rights.xml") }
        let allowed = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
        for method in root.descendants("EncryptionMethod") {
            if let alg = method.attr("Algorithm"), !allowed.contains(alg) { return true }
        }
        return false
    }

    convenience init(url: URL) throws {
        try self.init(archive: try ZipArchive(url: url))
    }

    init(archive: ZipArchive) throws {
        self.archive = archive
        if Self.isEncrypted(archive) { throw EpubError.drm }

        var opf: String?
        if let data = try? archive.read("META-INF/container.xml"), let root = XMLTree.parse(data) {
            opf = root.descendants("rootfile").first?.attr("full-path")
        }
        if opf == nil || !archive.has(opf ?? "") {
            opf = archive.entries.first { $0.name.lowercased().hasSuffix(".opf") }?.name
        }
        guard let opfPath = opf, let opfData = try? archive.read(opfPath), let root = XMLTree.parse(opfData) else {
            throw EpubError.notEpub
        }
        self.opfPath = opfPath
        self.opfDir = EpubPath.dir(opfPath)
        self.opfRoot = root
        isEpub3 = (root.attr("version") ?? "").hasPrefix("3")
        readMetadata()
        readManifest()
        readSpine()
        guard !spineIDs.isEmpty else { throw EpubError.notEpub }
        findCover()
        readToc()
    }

    private func readMetadata() {
        guard let meta = opfRoot.first("metadata") else { return }
        func value(_ name: String) -> String {
            Html.collapse(meta.first(name)?.content ?? "")
        }
        title = value("title")
        authors = meta.all("creator").map { Html.collapse($0.content) }.filter { !$0.isEmpty }
        language = value("language")
        publisher = value("publisher")
        descriptionText = Html.collapse(meta.first("description")?.content ?? "")
        identifier = value("identifier")
    }

    private func readManifest() {
        guard let node = opfRoot.first("manifest") else { return }
        for item in node.all("item") {
            guard let id = item.attr("id"), let href = item.attr("href") else { continue }
            manifest.append(ManifestItem(
                id: id, href: href,
                path: EpubPath.resolve(base: opfDir, href: href),
                mediaType: item.attr("media-type") ?? "",
                properties: item.attr("properties") ?? ""))
        }
    }

    private func readSpine() {
        guard let spine = opfRoot.first("spine") else { return }
        spineIDs = spine.all("itemref").compactMap { $0.attr("idref") }.filter { id in manifest.contains { $0.id == id } }
        let dir = (spine.attr("page-progression-direction") ?? "").lowercased()
        let lang = language.lowercased()
        rtl = dir == "rtl" || ["ar", "he", "fa", "ur"].contains { lang.hasPrefix($0) }
    }

    private func findCover() {
        if let item = manifest.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) {
            coverPath = item.path
            return
        }
        if let meta = opfRoot.first("metadata")?.all("meta").first(where: { $0.attr("name") == "cover" }),
           let id = meta.attr("content"), let item = manifest.first(where: { $0.id == id }),
           item.mediaType.hasPrefix("image/") {
            coverPath = item.path
            return
        }
        coverPath = manifest.first {
            $0.mediaType.hasPrefix("image/") && ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover"))
        }?.path
    }

    func coverData() -> Data? {
        guard let p = coverPath else { return nil }
        return try? archive.read(p)
    }

    private func readToc() {
        if let navItem = manifest.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let data = try? archive.read(navItem.path) {
            toc = Self.parseNav(Html.string(from: data), baseDir: EpubPath.dir(navItem.path))
        }
        if toc.isEmpty {
            let ncxID = opfRoot.first("spine")?.attr("toc")
            let byID = manifest.first(where: { $0.id == ncxID })
            let byType = manifest.first(where: { $0.mediaType == "application/x-dtbncx+xml" })
            let ncx = byID ?? byType
            if let ncx, let data = try? archive.read(ncx.path), let root = XMLTree.parse(data),
               let map = root.first("navMap") {
                Self.parseNavPoints(map, level: 0, baseDir: EpubPath.dir(ncx.path), into: &toc)
            }
        }
        toc = toc.filter { archive.has($0.path) }
    }

    static func parseNav(_ html: String, baseDir: String) -> [TocEntry] {
        var entries: [TocEntry] = []
        var inNav = false
        var level = 0
        var href: String?
        var text = ""
        var firstNavSeen = false
        for token in Html.tokenize(html) {
            switch token {
            case .open(let name, let attrs, _):
                if name == "nav", !inNav {
                    let type = attrs["epub:type"] ?? attrs["type"] ?? ""
                    if type.contains("toc") || !firstNavSeen { inNav = true }
                    firstNavSeen = true
                } else if inNav {
                    if name == "ol" { level += 1 }
                    if name == "a" { href = attrs["href"]; text = "" }
                }
            case .close(let name):
                if inNav {
                    if name == "nav" { return entries }
                    if name == "ol" { level -= 1 }
                    if name == "a", let h = href {
                        let title = Html.collapse(text)
                        if !title.isEmpty {
                            entries.append(TocEntry(title: title, path: EpubPath.resolve(base: baseDir, href: h),
                                                    fragment: EpubPath.fragment(h), level: max(0, level - 1)))
                        }
                        href = nil
                    }
                }
            case .text(let t):
                if inNav, href != nil { text += Html.decode(t) }
            }
        }
        return entries
    }

    private static func parseNavPoints(_ node: XNode, level: Int, baseDir: String, into out: inout [TocEntry]) {
        for point in node.all("navPoint") {
            let label = Html.collapse(point.first("navLabel")?.first("text")?.content ?? "")
            if let src = point.first("content")?.attr("src"), !label.isEmpty {
                out.append(TocEntry(title: label, path: EpubPath.resolve(base: baseDir, href: src),
                                    fragment: EpubPath.fragment(src), level: level))
            }
            parseNavPoints(point, level: level + 1, baseDir: baseDir, into: &out)
        }
    }

    func spineIndex(ofPath path: String) -> Int? {
        spinePaths.firstIndex(of: path)
    }

    var displayTitle: String { title.isEmpty ? L("Untitled") : title }
}

/// Rewrites a ZIP with the EPUB-required layout (mimetype first and stored).
enum EpubFiles {
    static func rewrite(_ archive: ZipArchive, replace: [String: Data] = [:], remove: Set<String> = [],
                        add: [(String, Data)] = []) throws -> Data {
        let w = ZipWriter()
        w.add("mimetype", Data("application/epub+zip".utf8), compress: false)
        for e in archive.entries where !e.name.hasSuffix("/") {
            if e.name == "mimetype" || remove.contains(e.name) { continue }
            let data: Data
            if let r = replace[e.name] { data = r } else { data = try archive.read(e) }
            w.add(e.name, data)
        }
        for (name, data) in add { w.add(name, data) }
        return w.finish()
    }
}

enum Mime {
    static func of(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "html", "htm": return "text/html"
        case "css": return "text/css"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "js": return "text/javascript"
        case "xml", "opf", "ncx": return "application/xml"
        default: return "application/octet-stream"
        }
    }
}
