import Foundation
import Compression

enum EpubError: LocalizedError {
    case notEpub, drm, tooLarge, noText, scanned, failed(String)

    var errorDescription: String? {
        switch self {
        case .notEpub: return L("This file is not a valid EPUB.")
        case .drm: return L("This book is protected by DRM and cannot be opened.")
        case .tooLarge: return L("This file is too large to process.")
        case .noText: return L("No text could be extracted.")
        case .scanned: return L("This PDF looks scanned (no text layer). OCR is not included.")
        case .failed(let message): return message
        }
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

struct ZipEntry {
    let name: String
    let method: Int
    let compressedSize: Int
    let size: Int
    let localOffset: Int
    let flags: Int
}

/// Minimal read-only ZIP reader (stored and deflate) with zip-bomb limits.
final class ZipArchive {
    private let data: Data
    private(set) var entries: [ZipEntry] = []
    private var lookup: [String: ZipEntry] = [:]

    static let maxEntrySize = 150 * 1024 * 1024
    static let maxEntries = 20_000
    static let maxTotal = 600 * 1024 * 1024

    convenience init(url: URL) throws {
        let d = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: d)
    }

    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw EpubError.notEpub }
        try parse()
    }

    private func u16(_ o: Int) -> Int {
        Int(data[data.startIndex + o]) | (Int(data[data.startIndex + o + 1]) << 8)
    }

    private func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }

    private func parse() throws {
        let n = data.count
        var eocd = -1
        var i = n - 22
        let stop = max(0, n - 22 - 65535)
        while i >= stop {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw EpubError.notEpub }
        let count = u16(eocd + 10)
        let cdOffset = u32(eocd + 16)
        guard count != 0xFFFF, cdOffset < n else { throw EpubError.notEpub }
        guard count <= Self.maxEntries else { throw EpubError.tooLarge }
        var p = cdOffset
        var total = 0
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x02014b50 else { throw EpubError.notEpub }
            let flags = u16(p + 8)
            let method = u16(p + 10)
            let comp = u32(p + 20)
            let size = u32(p + 24)
            let nl = u16(p + 28)
            let el = u16(p + 30)
            let cl = u16(p + 32)
            let off = u32(p + 42)
            guard p + 46 + nl <= n else { throw EpubError.notEpub }
            let s = data.startIndex + p + 46
            let name = String(decoding: data[s..<(s + nl)], as: UTF8.self)
            total += size
            guard total <= Self.maxTotal else { throw EpubError.tooLarge }
            let e = ZipEntry(name: name, method: method, compressedSize: comp, size: size, localOffset: off, flags: flags)
            entries.append(e)
            lookup[name] = e
            p += 46 + nl + el + cl
        }
    }

    func has(_ name: String) -> Bool { lookup[name] != nil }

    func entry(_ name: String) -> ZipEntry? { lookup[name] }

    func read(_ name: String) throws -> Data {
        guard let e = lookup[name] else { throw EpubError.failed("Missing \(name)") }
        return try read(e)
    }

    func read(_ e: ZipEntry) throws -> Data {
        if e.flags & 1 != 0 { throw EpubError.drm }
        guard e.size <= Self.maxEntrySize else { throw EpubError.tooLarge }
        let o = e.localOffset
        guard o + 30 <= data.count, u32(o) == 0x04034b50 else { throw EpubError.notEpub }
        let start = o + 30 + u16(o + 26) + u16(o + 28)
        guard start + e.compressedSize <= data.count else { throw EpubError.notEpub }
        let s = data.startIndex + start
        let raw = data.subdata(in: s..<(s + e.compressedSize))
        if e.method == 0 { return raw }
        guard e.method == 8 else { throw EpubError.notEpub }
        if e.size == 0 { return Data() }
        guard e.size <= e.compressedSize * 1032 + 4096 else { throw EpubError.tooLarge }
        return try Self.inflate(raw, expected: e.size)
    }

    static func inflate(_ raw: Data, expected: Int) throws -> Data {
        var out = Data(count: expected)
        let written: Int = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expected, s, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw EpubError.notEpub }
        if written < expected { out.removeSubrange(written..<expected) }
        return out
    }

    static func deflate(_ raw: Data) -> Data? {
        guard raw.count > 64 else { return nil }
        let cap = raw.count
        var out = Data(count: cap)
        let n: Int = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(d, cap, s, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < cap else { return nil }
        out.removeSubrange(n..<cap)
        return out
    }
}

private let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
    return c
}

func crc32(_ data: Data) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

private extension Data {
    mutating func le16(_ v: Int) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }

    mutating func le32(_ v: Int) {
        le16(v & 0xFFFF)
        le16((v >> 16) & 0xFFFF)
    }
}

/// Minimal ZIP writer. The `mimetype` entry must be added first and stored.
final class ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0
    private var names = Set<String>()

    func add(_ name: String, _ bytes: Data, compress: Bool = true) {
        guard !names.contains(name) else { return }
        names.insert(name)
        let nameData = Data(name.utf8)
        let crc = Int(crc32(bytes))
        var method = 0
        var body = bytes
        if compress, let d = ZipArchive.deflate(bytes) { method = 8; body = d }
        let offset = out.count
        out.le32(0x04034b50); out.le16(20); out.le16(0x0800); out.le16(method)
        out.le16(0); out.le16(33)
        out.le32(crc); out.le32(body.count); out.le32(bytes.count)
        out.le16(nameData.count); out.le16(0)
        out.append(nameData); out.append(body)

        central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(method)
        central.le16(0); central.le16(33)
        central.le32(crc); central.le32(body.count); central.le32(bytes.count)
        central.le16(nameData.count); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(0); central.le32(offset)
        central.append(nameData)
        count += 1
    }

    func addText(_ name: String, _ text: String, compress: Bool = true) {
        add(name, Data(text.utf8), compress: compress)
    }

    func finish() -> Data {
        let cdOffset = out.count
        var result = out
        result.append(central)
        result.le32(0x06054b50); result.le16(0); result.le16(0)
        result.le16(count); result.le16(count)
        result.le32(central.count); result.le32(cdOffset); result.le16(0)
        return result
    }
}
