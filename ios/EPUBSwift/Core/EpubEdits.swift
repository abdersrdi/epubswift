import Foundation
import UIKit

struct MetadataFields {
    var title = ""
    var authors = ""
    var language = ""
    var publisher = ""
    var descriptionText = ""
    var identifier = ""

    init(_ pkg: EpubPackage) {
        title = pkg.title
        authors = pkg.authors.joined(separator: ", ")
        language = pkg.language
        publisher = pkg.publisher
        descriptionText = pkg.descriptionText
        identifier = pkg.identifier
    }
}

enum EpubEdits {
    // MARK: Metadata

    static func applyMetadata(_ pkg: EpubPackage, _ f: MetadataFields) throws -> Data {
        let root = pkg.opfRoot
        guard let meta = root.first("metadata") else { throw EpubError.notEpub }
        if !meta.attrs.contains(where: { $0.0 == "xmlns:dc" }) && !root.attrs.contains(where: { $0.0 == "xmlns:dc" }) {
            meta.setAttr("xmlns:dc", "http://purl.org/dc/elements/1.1/")
        }
        func replace(_ local: String, with values: [String]) {
            let clean = values.map { Xhtml.clean($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let existing = meta.all(local)
            if clean.isEmpty {
                existing.forEach { meta.remove($0) }
                return
            }
            let anchor = existing.first
            let index = anchor.flatMap { a in meta.children.firstIndex { $0 === a } }
            existing.forEach { meta.remove($0) }
            var insertAt = index ?? meta.children.count
            for v in clean {
                let node = XNode("dc:" + local)
                node.append(XNode.textNode(v))
                node.parent = meta
                meta.children.insert(node, at: min(insertAt, meta.children.count))
                insertAt += 1
            }
        }
        replace("title", with: [f.title.isEmpty ? pkg.title : f.title])
        replace("creator", with: f.authors.split(whereSeparator: { $0 == "," || $0 == "،" }).map(String.init))
        replace("language", with: [f.language.isEmpty ? pkg.language : f.language])
        replace("publisher", with: [f.publisher])
        replace("description", with: [f.descriptionText])
        if !f.identifier.trimmingCharacters(in: .whitespaces).isEmpty {
            let uid = root.attr("unique-identifier")
            if let node = meta.all("identifier").first(where: { $0.attr("id") == uid }) ?? meta.all("identifier").first {
                node.children = [XNode.textNode(f.identifier.trimmingCharacters(in: .whitespaces))]
            }
        }
        touchModified(meta)
        return try EpubFiles.rewrite(pkg.archive, replace: [pkg.opfPath: Data(root.serialize().utf8)])
    }

    private static func touchModified(_ meta: XNode) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let m = meta.all("meta").first(where: { $0.attr("property") == "dcterms:modified" }) {
            m.children = [XNode.textNode(stamp)]
        }
    }

    // MARK: Cover

    static func replaceCover(_ pkg: EpubPackage, image: UIImage) throws -> Data {
        let root = pkg.opfRoot
        guard let manifest = root.first("manifest") else { throw EpubError.notEpub }
        let scaled = downscale(image, maxSide: 2400)
        if let oldPath = pkg.coverPath, let item = pkg.manifest.first(where: { $0.path == oldPath }) {
            let data: Data?
            if item.mediaType == "image/png" { data = scaled.pngData() } else { data = scaled.jpegData(compressionQuality: 0.9) }
            guard let bytes = data else { throw EpubError.failed(L("That image could not be read.")) }
            return try EpubFiles.rewrite(pkg.archive, replace: [oldPath: bytes])
        }
        guard let jpeg = scaled.jpegData(compressionQuality: 0.9) else { throw EpubError.failed(L("That image could not be read.")) }
        var name = "images/epubswift-cover.jpg"
        var n = 1
        let basePath = pkg.opfDir.isEmpty ? "" : pkg.opfDir + "/"
        while pkg.archive.has(basePath + name) { n += 1; name = "images/epubswift-cover-\(n).jpg" }
        let item = XNode("item")
        item.setAttr("id", "epubswift-cover")
        item.setAttr("href", name)
        item.setAttr("media-type", "image/jpeg")
        item.setAttr("properties", "cover-image")
        manifest.append(item)
        if let meta = root.first("metadata") {
            meta.all("meta").filter { $0.attr("name") == "cover" }.forEach { meta.remove($0) }
            let m = XNode("meta")
            m.setAttr("name", "cover")
            m.setAttr("content", "epubswift-cover")
            meta.append(m)
        }
        return try EpubFiles.rewrite(pkg.archive,
                                     replace: [pkg.opfPath: Data(root.serialize().utf8)],
                                     add: [(basePath + name, jpeg)])
    }

    static func downscale(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let f = maxSide / longest
        let size = CGSize(width: (image.size.width * f).rounded(), height: (image.size.height * f).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

// MARK: - Validator

struct ValidationIssue: Identifiable {
    enum Severity: String { case error, warning, info }
    let id = UUID()
    var severity: Severity
    var message: String
}

enum EpubValidator {
    static func run(url: URL) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func add(_ s: ValidationIssue.Severity, _ m: String) { issues.append(ValidationIssue(severity: s, message: m)) }

        guard let archive = try? ZipArchive(url: url) else {
            return [ValidationIssue(severity: .error, message: L("This file is not a valid ZIP archive."))]
        }
        if let first = archive.entries.first {
            if first.name != "mimetype" { add(.error, L("The first file in the archive must be \"mimetype\".")) }
            else if first.method != 0 { add(.error, L("The \"mimetype\" file must be stored without compression.")) }
        }
        if let m = try? archive.read("mimetype") {
            if String(decoding: m, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) != "application/epub+zip" {
                add(.error, L("The \"mimetype\" file has the wrong content."))
            }
        } else { add(.error, L("The \"mimetype\" file is missing.")) }
        if EpubPackage.isEncrypted(archive) { add(.error, L("The book is protected by DRM.")); return issues }
        guard let containerData = try? archive.read("META-INF/container.xml"), let container = XMLTree.parse(containerData) else {
            add(.error, L("META-INF/container.xml is missing or not well-formed."))
            return issues
        }
        guard let opfPath = container.descendants("rootfile").first?.attr("full-path") else {
            add(.error, L("container.xml does not name a package document."))
            return issues
        }
        guard let opfData = try? archive.read(opfPath), let root = XMLTree.parse(opfData) else {
            add(.error, String(format: L("The package document %@ is missing or not well-formed."), opfPath))
            return issues
        }
        let opfDir = EpubPath.dir(opfPath)
        let version = root.attr("version") ?? ""
        if version.isEmpty { add(.warning, L("The package has no version attribute.")) }
        if let meta = root.first("metadata") {
            if (meta.first("title")?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.error, L("The book has no title.")) }
            if (meta.first("language")?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.error, L("The book has no language.")) }
            if (meta.first("identifier")?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add(.error, L("The book has no identifier.")) }
            if meta.all("creator").isEmpty { add(.info, L("The book has no author.")) }
        } else { add(.error, L("The package has no metadata.")) }

        var ids = Set<String>()
        var paths: [String: String] = [:]
        var hasNav = false
        let manifestItems = root.first("manifest")?.all("item") ?? []
        if manifestItems.isEmpty { add(.error, L("The manifest is empty.")) }
        for item in manifestItems {
            guard let id = item.attr("id"), let href = item.attr("href") else {
                add(.error, L("A manifest item has no id or href.")); continue
            }
            if !ids.insert(id).inserted { add(.error, String(format: L("Duplicate manifest id: %@"), id)) }
            let path = EpubPath.resolve(base: opfDir, href: href)
            paths[id] = path
            if !archive.has(path) && !href.hasPrefix("http") { add(.error, String(format: L("Manifest file is missing: %@"), href)) }
            if (item.attr("properties") ?? "").contains("nav") { hasNav = true }
        }
        let spineItems = root.first("spine")?.all("itemref") ?? []
        if spineItems.isEmpty { add(.error, L("The spine is empty.")) }
        var spinePaths: [String] = []
        for ref in spineItems {
            guard let id = ref.attr("idref"), let path = paths[id] else {
                add(.error, String(format: L("The spine refers to an unknown item: %@"), ref.attr("idref") ?? "?")); continue
            }
            spinePaths.append(path)
        }
        if version.hasPrefix("3") && !hasNav { add(.error, L("EPUB 3 books need a navigation document (properties=\"nav\").")) }
        if !version.hasPrefix("3") && root.first("spine")?.attr("toc") == nil { add(.warning, L("The spine has no NCX reference.")) }

        let known = Set(paths.values)
        for path in spinePaths {
            guard let data = try? archive.read(path) else { continue }
            if XMLTree.parse(data) == nil { add(.warning, String(format: L("Not well-formed XML: %@"), path)); continue }
            for token in Html.tokenize(Html.string(from: data)) {
                if case .open(let name, let attrs, _) = token {
                    var target: String?
                    if name == "img" { target = attrs["src"] } else if name == "link" { target = attrs["href"] }
                    guard let t = target, !t.hasPrefix("http"), !t.hasPrefix("data:") else { continue }
                    let resolved = EpubPath.resolve(base: EpubPath.dir(path), href: t)
                    if !archive.has(resolved) { add(.warning, String(format: L("%@ refers to a missing file: %@"), path, t)) }
                    else if !known.contains(resolved) { add(.info, String(format: L("File is not listed in the manifest: %@"), resolved)) }
                }
            }
        }
        if issues.isEmpty { add(.info, L("No problems were found.")) }
        return issues
    }
}

// MARK: - Repair

enum EpubRepair {
    static func run(url: URL) throws -> (Data, [String]) {
        let archive = try ZipArchive(url: url)
        if EpubPackage.isEncrypted(archive) { throw EpubError.drm }
        var fixes: [String] = []
        var replace: [String: Data] = [:]
        var add: [(String, Data)] = []

        if archive.entries.first?.name != "mimetype" || archive.entries.first?.method != 0 {
            fixes.append(L("Rewrote the archive with a stored \"mimetype\" file first."))
        }

        var opfPath = ""
        if let data = try? archive.read("META-INF/container.xml"), let c = XMLTree.parse(data),
           let p = c.descendants("rootfile").first?.attr("full-path"), archive.has(p) {
            opfPath = p
        } else if let found = archive.entries.first(where: { $0.name.lowercased().hasSuffix(".opf") })?.name {
            opfPath = found
            let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">\n<rootfiles><rootfile full-path=\"\(Xhtml.escape(found, attribute: true))\" media-type=\"application/oebps-package+xml\"/></rootfiles>\n</container>\n"
            if archive.has("META-INF/container.xml") { replace["META-INF/container.xml"] = Data(xml.utf8) } else { add.append(("META-INF/container.xml", Data(xml.utf8))) }
            fixes.append(L("Rebuilt META-INF/container.xml."))
        } else {
            throw EpubError.failed(L("No package document (.opf) was found, so this book cannot be repaired."))
        }
        guard let opfData = try? archive.read(opfPath), let root = XMLTree.parse(opfData) else {
            throw EpubError.failed(L("The package document is damaged and cannot be repaired."))
        }
        let opfDir = EpubPath.dir(opfPath)
        var removeSet = Set<String>()
        var opfChanged = false

        if let manifest = root.first("manifest") {
            var removedIDs = Set<String>()
            for item in manifest.all("item") {
                guard let href = item.attr("href") else { continue }
                if href.hasPrefix("http") { continue }
                if !archive.has(EpubPath.resolve(base: opfDir, href: href)) {
                    manifest.remove(item)
                    if let id = item.attr("id") { removedIDs.insert(id) }
                    fixes.append(String(format: L("Removed manifest entry for a missing file: %@"), href))
                    opfChanged = true
                }
            }
            if let spine = root.first("spine") {
                let ids = Set(manifest.all("item").compactMap { $0.attr("id") })
                for ref in spine.all("itemref") where !ids.contains(ref.attr("idref") ?? "") {
                    spine.remove(ref)
                    fixes.append(L("Removed a spine entry that pointed to nothing."))
                    opfChanged = true
                }
            }
        }
        if let meta = root.first("metadata") {
            if !meta.attrs.contains(where: { $0.0 == "xmlns:dc" }) && !root.attrs.contains(where: { $0.0 == "xmlns:dc" }) {
                meta.setAttr("xmlns:dc", "http://purl.org/dc/elements/1.1/")
            }
            func ensure(_ local: String, _ value: String, _ message: String) {
                let present = meta.first(local).map { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
                if present { return }
                meta.all(local).forEach { meta.remove($0) }
                let node = XNode("dc:" + local)
                node.append(XNode.textNode(value))
                meta.append(node)
                fixes.append(message)
                opfChanged = true
            }
            ensure("title", (url.deletingPathExtension().lastPathComponent), L("Added a missing title."))
            ensure("language", "en", L("Added a missing language (en)."))
            if meta.first("identifier") == nil || (meta.first("identifier")?.content ?? "").isEmpty {
                let node = XNode("dc:identifier")
                node.setAttr("id", root.attr("unique-identifier") ?? "bookid")
                node.append(XNode.textNode("urn:uuid:\(UUID().uuidString.lowercased())"))
                meta.all("identifier").forEach { meta.remove($0) }
                meta.append(node)
                if root.attr("unique-identifier") == nil { root.setAttr("unique-identifier", "bookid") }
                fixes.append(L("Added a missing identifier."))
                opfChanged = true
            }
        }
        if opfChanged { replace[opfPath] = Data(root.serialize().utf8) }

        // XHTML pages that use HTML entities are not well-formed XML; replace them with numeric references.
        let entities = ["nbsp": "&#160;", "copy": "&#169;", "mdash": "&#8212;", "ndash": "&#8211;", "hellip": "&#8230;",
                        "lsquo": "&#8216;", "rsquo": "&#8217;", "ldquo": "&#8220;", "rdquo": "&#8221;", "laquo": "&#171;",
                        "raquo": "&#187;", "middot": "&#183;", "bull": "&#8226;", "times": "&#215;"]
        var entityFixes = 0
        for e in archive.entries where e.name.lowercased().hasSuffix(".xhtml") || e.name.lowercased().hasSuffix(".html") {
            guard replace[e.name] == nil, let data = try? archive.read(e) else { continue }
            if XMLTree.parse(data) != nil { continue }
            var text = Html.string(from: data)
            var changed = false
            for (k, v) in entities where text.contains("&\(k);") { text = text.replacingOccurrences(of: "&\(k);", with: v); changed = true }
            if changed, XMLTree.parse(Data(text.utf8)) != nil {
                replace[e.name] = Data(text.utf8)
                entityFixes += 1
            }
        }
        if entityFixes > 0 { fixes.append(String(format: L("Fixed HTML entities in %d page(s)."), entityFixes)) }

        if fixes.isEmpty { fixes.append(L("No structural problems that can be repaired automatically were found.")) }
        let data = try EpubFiles.rewrite(archive, replace: replace, remove: removeSet, add: add)
        return (data, fixes)
    }
}
