import CryptoKit
import Foundation

/// Syntax-highlights whole files for the diff view and hands them back line by line.
///
/// A diff shows fragments of a file, but a fragment cannot be highlighted on its own:
/// a hunk that starts halfway through a block comment or a multi-line string would be
/// coloured as code. So the complete file is highlighted once and the lines the diff
/// needs are picked out by number.
///
/// Results are kept per instance (one per review window) rather than in the shared
/// `JSEngine` memo; see `JSEngine.highlight(code:language:useCache:)`.
final class DiffHighlighter {
    private struct Key: Hashable {
        let digest: String
        let language: String
    }

    private let lock = NSLock()
    private let cache = LRUCache<Key, [String]>(entryLimit: 256, byteLimit: 24 * 1024 * 1024)

    /// Highlighted HTML for each line of `code`, or nil if the language is unknown or
    /// highlighting `code` would exceed `budget` (bytes of not-yet-cached input, which
    /// the call draws down). `exhausted` is set in the latter case.
    func lines(of code: String, language: String, budget: inout Int, exhausted: inout Bool) -> [String]? {
        let key = Key(digest: UnifiedDiff.hex(SHA256.hash(data: Data(code.utf8))), language: language)
        lock.lock()
        let cached = cache.value(forKey: key)
        lock.unlock()
        if let cached { return cached }

        let bytes = code.utf8.count
        guard bytes <= budget else {
            exhausted = true
            return nil
        }
        budget -= bytes
        guard let html = JSEngine.shared.highlight(code: code, language: language, useCache: false) else {
            return nil
        }
        let lines = Self.splitLines(html)
        lock.lock()
        cache.insert(lines, forKey: key, cost: html.utf8.count + lines.count * 16)
        lock.unlock()
        return lines
    }

    /// Splits highlight.js output at newlines, closing every `<span>` still open at the
    /// end of a line and reopening it on the next, so each line is balanced HTML that
    /// can sit in its own table cell.
    static func splitLines(_ html: String) -> [String] {
        let bytes = Array(html.utf8)
        var lines: [String] = []
        var current: [UInt8] = []
        var open: [ArraySlice<UInt8>] = []
        let close = Array("</span>".utf8)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\n") {
                for _ in open { current.append(contentsOf: close) }
                lines.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
                for tag in open { current.append(contentsOf: tag) }
                index += 1
            } else if byte == UInt8(ascii: "<"), let end = bytes[index...].firstIndex(of: UInt8(ascii: ">")) {
                let tag = bytes[index...end]
                if tag.dropFirst().first == UInt8(ascii: "/") {
                    if !open.isEmpty { open.removeLast() }
                } else {
                    open.append(tag)
                }
                current.append(contentsOf: tag)
                index = end + 1
            } else {
                current.append(byte)
                index += 1
            }
        }
        lines.append(String(decoding: current, as: UTF8.self))
        return lines
    }

    /// Wraps the text characters `range` (counted in Unicode scalars of the *visible*
    /// text, so a tag is zero wide and an entity is one) of an HTML line in
    /// `<span class="x">`. The mark is closed and reopened around any tag inside the
    /// range, which keeps it properly nested with the syntax spans.
    static func mark(_ html: String, range: Range<Int>) -> String {
        guard !range.isEmpty else { return html }
        let scalars = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        let openMark = Array("<span class=\"x\">".unicodeScalars)
        let closeMark = Array("</span>".unicodeScalars)
        var position = 0
        var marking = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "<", let end = scalars[index...].firstIndex(of: ">") {
                if marking {
                    out.append(contentsOf: closeMark)
                    marking = false
                }
                out.append(contentsOf: scalars[index...end])
                index = end + 1
                continue
            }
            // One visible character: a bare scalar or a whole `&…;` entity.
            var end = index
            if scalar == "&", let semicolon = scalars[index...].prefix(12).firstIndex(of: ";") {
                end = semicolon
            }
            let inside = range.contains(position)
            if inside != marking {
                out.append(contentsOf: inside ? openMark : closeMark)
                marking = inside
            }
            out.append(contentsOf: scalars[index...end])
            position += 1
            index = end + 1
        }
        if marking { out.append(contentsOf: closeMark) }
        return String(out)
    }
}
