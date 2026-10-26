import Foundation

/// Small XML DOM built on XMLParser; namespaces are kept as plain prefixes.
final class XNode {
    var name: String
    var attrs: [(String, String)] = []
    var children: [XNode] = []
    var text: String = ""
    weak var parent: XNode?

    init(_ name: String) { self.name = name }

    static func textNode(_ s: String) -> XNode {
        let n = XNode("#text")
        n.text = s
        return n
    }

    var isText: Bool { name == "#text" }

    var local: String {
        if let r = name.lastIndex(of: ":") { return String(name[name.index(after: r)...]) }
        return name
    }

    var elements: [XNode] { children.filter { !$0.isText } }

    func attr(_ key: String) -> String? {
        if let a = attrs.first(where: { $0.0 == key }) { return a.1 }
        return attrs.first(where: { $0.0.hasSuffix(":" + key) })?.1
    }

    func setAttr(_ key: String, _ value: String) {
        if let i = attrs.firstIndex(where: { $0.0 == key }) { attrs[i].1 = value } else { attrs.append((key, value)) }
    }

    func removeAttr(_ key: String) { attrs.removeAll { $0.0 == key } }

    func first(_ local: String) -> XNode? { elements.first { $0.local == local } }

    func all(_ local: String) -> [XNode] { elements.filter { $0.local == local } }

    func descendants(_ local: String) -> [XNode] {
        var result: [XNode] = []
        for c in elements {
            if c.local == local { result.append(c) }
            result.append(contentsOf: c.descendants(local))
        }
        return result
    }

    var content: String {
        if isText { return text }
        return children.map { $0.content }.joined()
    }

    func append(_ node: XNode) {
        node.parent = self
        children.append(node)
    }

    func remove(_ node: XNode) { children.removeAll { $0 === node } }

    func serialize(declaration: Bool = true) -> String {
        var s = declaration ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" : ""
        write(into: &s)
        return s + "\n"
    }

    private func write(into s: inout String) {
        if isText { s += Xhtml.escape(text); return }
        s += "<" + name
        for (k, v) in attrs { s += " \(k)=\"\(Xhtml.escape(v, attribute: true))\"" }
        if children.isEmpty { s += "/>"; return }
        s += ">"
        for c in children { c.write(into: &s) }
        s += "</" + name + ">"
    }
}

final class XMLTree: NSObject, XMLParserDelegate {
    private var root: XNode?
    private var stack: [XNode] = []

    static func parse(_ data: Data) -> XNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let tree = XMLTree()
        parser.delegate = tree
        guard parser.parse() else { return nil }
        return tree.root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let node = XNode(elementName)
        node.attrs = attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if let parent = stack.last { parent.append(node) } else { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { addText(string) }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        addText(String(decoding: CDATABlock, as: UTF8.self))
    }

    private func addText(_ s: String) {
        guard let parent = stack.last else { return }
        if let last = parent.children.last, last.isText { last.text += s } else { parent.append(XNode.textNode(s)) }
    }
}

enum Xhtml {
    static func escape(_ s: String, attribute: Bool = false) -> String {
        var r = s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute { r = r.replacingOccurrences(of: "\"", with: "&quot;") }
        return r
    }

    /// Removes characters that are illegal in XML 1.0.
    static func clean(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if v == 9 || v == 10 || v == 13 || (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000 {
                scalars.append(u)
            }
        }
        return String(scalars)
    }

    static func page(title: String, language: String, rtl: Bool, body: String, css: String?) -> String {
        var s = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>\n"
        s += "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" lang=\"\(language)\" xml:lang=\"\(language)\"\(rtl ? " dir=\"rtl\"" : "")>\n"
        s += "<head><meta charset=\"utf-8\"/><title>\(escape(clean(title)))</title>"
        if let css { s += "<link rel=\"stylesheet\" type=\"text/css\" href=\"\(css)\"/>" }
        s += "</head>\n<body>\n\(body)\n</body>\n</html>\n"
        return s
    }
}
