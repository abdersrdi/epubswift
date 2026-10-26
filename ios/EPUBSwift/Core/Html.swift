import Foundation

enum HtmlToken {
    case open(String, [String: String], Bool)
    case close(String)
    case text(String)
}

struct TextBlock {
    enum Kind { case heading(Int), paragraph, listItem, image }
    var kind: Kind
    var text: String
    var src: String?
}

/// Tolerant HTML/XHTML tokenizer used for text extraction, navigation and exports.
enum Html {
    static func string(from data: Data) -> String {
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                if let s = String(data: data, encoding: .utf16) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) }
    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }

    private static func find(_ b: [UInt8], _ pat: [UInt8], from: Int) -> Int? {
        guard !pat.isEmpty, b.count >= pat.count, from <= b.count - pat.count else { return nil }
        var i = from
        while i <= b.count - pat.count {
            if b[i] == pat[0] {
                var ok = true
                var j = 1
                while j < pat.count { if b[i + j] != pat[j] { ok = false; break }; j += 1 }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    private static func findCloseTag(_ b: [UInt8], name: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 0x3C && b[i + 1] == 0x2F {
                var j = 0
                var ok = true
                while j < name.count {
                    guard i + 2 + j < b.count else { ok = false; break }
                    var c = b[i + 2 + j]
                    if c >= 65 && c <= 90 { c += 32 }
                    if c != name[j] { ok = false; break }
                    j += 1
                }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    static func tokenize(_ html: String) -> [HtmlToken] {
        let b = Array(html.utf8)
        let n = b.count
        var tokens: [HtmlToken] = []
        var i = 0
        var textStart = 0

        func flushText(_ end: Int) {
            if end > textStart { tokens.append(.text(String(decoding: b[textStart..<end], as: UTF8.self))) }
        }

        while i < n {
            guard b[i] == 0x3C, i + 1 < n else { i += 1; continue }
            let c = b[i + 1]
            if c == 0x21 {
                flushText(i)
                if i + 3 < n, b[i + 2] == 0x2D, b[i + 3] == 0x2D {
                    i = (find(b, [0x2D, 0x2D, 0x3E], from: i + 4) ?? (n - 3)) + 3
                } else {
                    i = (find(b, [0x3E], from: i) ?? (n - 1)) + 1
                }
                textStart = i
                continue
            }
            if c == 0x3F {
                flushText(i)
                i = (find(b, [0x3E], from: i) ?? (n - 1)) + 1
                textStart = i
                continue
            }
            if isLetter(c) || c == 0x2F {
                flushText(i)
                var j = i + 1
                let closing = c == 0x2F
                if closing { j += 1 }
                var name: [UInt8] = []
                while j < n, isLetter(b[j]) || (b[j] >= 48 && b[j] <= 57) || b[j] == 0x3A || b[j] == 0x2D {
                    var ch = b[j]
                    if ch >= 65 && ch <= 90 { ch += 32 }
                    name.append(ch)
                    j += 1
                }
                var attrs: [String: String] = [:]
                var selfClosing = false
                while j < n {
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j >= n { break }
                    if b[j] == 0x3E { j += 1; break }
                    if b[j] == 0x2F { selfClosing = true; j += 1; continue }
                    var key: [UInt8] = []
                    while j < n, !isSpace(b[j]), b[j] != 0x3D, b[j] != 0x3E, b[j] != 0x2F {
                        var ch = b[j]
                        if ch >= 65 && ch <= 90 { ch += 32 }
                        key.append(ch)
                        j += 1
                    }
                    while j < n, isSpace(b[j]) { j += 1 }
                    var value: [UInt8] = []
                    if j < n, b[j] == 0x3D {
                        j += 1
                        while j < n, isSpace(b[j]) { j += 1 }
                        if j < n, b[j] == 0x22 || b[j] == 0x27 {
                            let q = b[j]
                            j += 1
                            while j < n, b[j] != q { value.append(b[j]); j += 1 }
                            j += 1
                        } else {
                            while j < n, !isSpace(b[j]), b[j] != 0x3E { value.append(b[j]); j += 1 }
                        }
                    }
                    if !key.isEmpty {
                        attrs[String(decoding: key, as: UTF8.self)] = decode(String(decoding: value, as: UTF8.self))
                    }
                }
                let tag = String(decoding: name, as: UTF8.self)
                if closing {
                    tokens.append(.close(tag))
                } else {
                    tokens.append(.open(tag, attrs, selfClosing))
                    if !selfClosing, tag == "script" || tag == "style" {
                        let end = findCloseTag(b, name: name, from: j) ?? n
                        j = end
                    }
                }
                i = j
                textStart = i
                continue
            }
            i += 1
        }
        flushText(n)
        return tokens
    }

    // MARK: Entities

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "laquo": "\u{00AB}", "raquo": "\u{00BB}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "bull": "\u{2022}", "middot": "\u{00B7}", "deg": "\u{00B0}",
        "times": "\u{00D7}", "euro": "\u{20AC}", "pound": "\u{00A3}", "sect": "\u{00A7}", "para": "\u{00B6}",
        "eacute": "\u{00E9}", "egrave": "\u{00E8}", "agrave": "\u{00E0}", "ccedil": "\u{00E7}"
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                var replacement: String?
                if body.hasPrefix("#x") || body.hasPrefix("#X") {
                    if let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                } else if body.hasPrefix("#") {
                    if let v = UInt32(body.dropFirst(1)), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
                } else {
                    replacement = named[body]
                }
                if let r = replacement {
                    out += r
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = s.index(after: i)
        }
        return out
    }

    static func collapse(_ s: String) -> String {
        var out = ""
        var lastSpace = true
        for ch in s {
            if ch.isWhitespace || ch == "\u{00A0}" {
                if !lastSpace { out.append(" "); lastSpace = true }
            } else {
                out.append(ch)
                lastSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    // MARK: Blocks

    private static let breakTags: Set<String> = [
        "p", "div", "tr", "blockquote", "section", "article", "aside", "header", "footer", "ul", "ol", "table",
        "pre", "figure", "figcaption", "dd", "dt", "dl", "hr", "nav", "main", "body", "br", "li"
    ]

    static func blocks(_ html: String) -> [TextBlock] {
        var result: [TextBlock] = []
        var buffer = ""
        var heading = 0
        var skip = 0
        var inItem = 0

        func flush() {
            let t = collapse(buffer)
            buffer = ""
            guard !t.isEmpty else { return }
            if heading > 0 {
                result.append(TextBlock(kind: .heading(heading), text: t, src: nil))
            } else if inItem > 0 {
                result.append(TextBlock(kind: .listItem, text: t, src: nil))
            } else {
                result.append(TextBlock(kind: .paragraph, text: t, src: nil))
            }
        }

        for token in tokenize(html) {
            switch token {
            case .open(let name, let attrs, let selfClosing):
                if name == "head" || name == "title" { skip += 1; if selfClosing { skip -= 1 }; continue }
                if skip > 0 { continue }
                if name.count == 2, name.first == "h", let level = Int(name.dropFirst()), (1...6).contains(level) {
                    flush()
                    heading = level
                } else if name == "img" || name == "image" {
                    flush()
                    if let src = attrs["src"] ?? attrs["xlink:href"] ?? attrs["href"] {
                        result.append(TextBlock(kind: .image, text: attrs["alt"] ?? "", src: src))
                    }
                } else if name == "li" {
                    flush()
                    inItem += 1
                } else if name == "br", heading > 0 {
                    buffer += " "
                } else if breakTags.contains(name) {
                    flush()
                }
            case .close(let name):
                if name == "head" || name == "title" { skip = max(0, skip - 1); continue }
                if skip > 0 { continue }
                if name.count == 2, name.first == "h", Int(name.dropFirst()) != nil {
                    flush()
                    heading = 0
                } else if name == "li" {
                    flush()
                    inItem = max(0, inItem - 1)
                } else if breakTags.contains(name) {
                    flush()
                }
            case .text(let raw):
                if skip > 0 { continue }
                buffer += decode(raw)
            }
        }
        flush()
        return result
    }
}
