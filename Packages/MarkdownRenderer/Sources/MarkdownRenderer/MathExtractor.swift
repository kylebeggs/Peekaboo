import Foundation

public final class MathRegistry {
    struct Segment {
        let tex: String
        let display: Bool
    }

    private(set) var segments: [(token: String, segment: Segment)] = []
    private let salt: String
    private var counter = 0

    init() {
        salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
    }

    func register(tex: String, display: Bool) -> String {
        counter += 1
        // Purely alphanumeric so cmark passes it through as plain text.
        let token = "pkbmath\(salt)n\(counter)x"
        segments.append((token, Segment(tex: tex, display: display)))
        return token
    }

    var isEmpty: Bool { segments.isEmpty }
}

/// Extracts `$...$`, `$$...$$` math from markdown source *before* cmark parsing
/// (cmark would mangle TeX via emphasis/escape rules). Tracks fenced and indented
/// code so `$` inside code is never touched; every ambiguity is resolved as
/// "not math" — a literal dollar sign is harmless, corrupted code is not.
enum MathExtractor {
    static func extract(from source: String, into registry: MathRegistry) -> String {
        let lines = source.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count + 8)
        var fence: (char: Character, length: Int)? = nil
        var previousLineBlankOrIndented = true
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let openFence = fence {
                out.append(line)
                if isClosingFence(line, fence: openFence) { fence = nil }
                index += 1
                continue
            }
            if let opened = openingFence(line) {
                fence = opened
                out.append(line)
                previousLineBlankOrIndented = false
                index += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(line)
                previousLineBlankOrIndented = true
                index += 1
                continue
            }
            if leadingSpaces(line) >= 4 && previousLineBlankOrIndented {
                // Indented code block (approximation of CommonMark; bias: not math).
                out.append(line)
                index += 1
                continue
            }
            previousLineBlankOrIndented = false

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Multi-line $$ block: opener line has no closing $$.
            if trimmed.hasPrefix("$$"), !String(trimmed.dropFirst(2)).contains("$$") {
                if let closing = findBlockClose(lines: lines, startingAfter: index) {
                    var texLines: [String] = []
                    let opener = String(trimmed.dropFirst(2))
                    if !opener.isEmpty { texLines.append(opener) }
                    for inner in (index + 1)..<closing { texLines.append(lines[inner]) }
                    let closingTrimmed = lines[closing].trimmingCharacters(in: .whitespaces)
                    let closingRemainder = String(closingTrimmed.dropLast(2))
                    if !closingRemainder.isEmpty { texLines.append(closingRemainder) }
                    let tex = texLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tex.isEmpty {
                        let token = registry.register(tex: tex, display: true)
                        out.append(contentsOf: ["", token, ""])
                        index = closing + 1
                        continue
                    }
                }
                out.append(line)
                index += 1
                continue
            }

            // Whole line is a single-line display block: $$...$$
            if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
                let inner = String(trimmed.dropFirst(2).dropLast(2))
                if !inner.contains("$$"), !inner.trimmingCharacters(in: .whitespaces).isEmpty {
                    let token = registry.register(tex: inner.trimmingCharacters(in: .whitespaces), display: true)
                    out.append(contentsOf: ["", token, ""])
                    index += 1
                    continue
                }
            }

            out.append(scanLine(line, registry: registry))
            index += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Fences

    private static func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for char in line {
            if char == " " { count += 1 } else if char == "\t" { count += 4 } else { break }
        }
        return count
    }

    private static func openingFence(_ line: String) -> (char: Character, length: Int)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        // Info strings of backtick fences may not contain backticks.
        if first == "`", trimmed.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    private static func isClosingFence(_ line: String, fence: (char: Character, length: Int)) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= fence.length else { return false }
        return trimmed.allSatisfy { $0 == fence.char }
    }

    private static func findBlockClose(lines: [String], startingAfter index: Int) -> Int? {
        let limit = min(lines.count, index + 200)
        for candidate in (index + 1)..<limit {
            let trimmed = lines[candidate].trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("$$") { return candidate }
            if openingFence(lines[candidate]) != nil { return nil }
        }
        return nil
    }

    // MARK: - Inline scanning

    private static func scanLine(_ line: String, registry: MathRegistry) -> String {
        guard line.contains("$") else { return line }
        let chars = Array(line)
        var result = ""
        result.reserveCapacity(chars.count)
        var k = 0

        while k < chars.count {
            let char = chars[k]

            if char == "\\", k + 1 < chars.count, chars[k + 1] == "$" {
                result += "\\$"
                k += 2
                continue
            }
            if char == "`" {
                k = copyCodeSpan(chars, from: k, into: &result)
                continue
            }
            if char == "$" {
                if k + 1 < chars.count, chars[k + 1] == "$" {
                    if let close = findDoubleDollar(chars, from: k + 2) {
                        let tex = String(chars[(k + 2)..<close]).trimmingCharacters(in: .whitespaces)
                        if !tex.isEmpty {
                            result += registry.register(tex: tex, display: true)
                            k = close + 2
                            continue
                        }
                    }
                    result += "$$"
                    k += 2
                    continue
                }
                if let close = findInlineClose(chars, open: k) {
                    let tex = String(chars[(k + 1)..<close])
                    result += registry.register(tex: tex, display: false)
                    k = close + 1
                    continue
                }
                result += "$"
                k += 1
                continue
            }
            result.append(char)
            k += 1
        }
        return result
    }

    /// Copies a backtick code span (or a bare backtick run with no closer) verbatim.
    private static func copyCodeSpan(_ chars: [Character], from start: Int, into result: inout String) -> Int {
        var runEnd = start
        while runEnd < chars.count, chars[runEnd] == "`" { runEnd += 1 }
        let runLength = runEnd - start

        var m = runEnd
        while m < chars.count {
            if chars[m] == "`" {
                var n = m
                while n < chars.count, chars[n] == "`" { n += 1 }
                if n - m == runLength {
                    result += String(chars[start..<n])
                    return n
                }
                m = n
            } else {
                m += 1
            }
        }
        result += String(chars[start..<runEnd])
        return runEnd
    }

    private static func findDoubleDollar(_ chars: [Character], from start: Int) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "$", chars[j + 1] == "$", j > 0, chars[j - 1] != "\\" { return j }
            j += 1
        }
        return nil
    }

    /// GitHub-style guards: opener not followed by whitespace or `$`; closer not
    /// preceded by whitespace or backslash, and not immediately followed by a digit.
    private static func findInlineClose(_ chars: [Character], open: Int) -> Int? {
        guard open + 1 < chars.count else { return nil }
        let next = chars[open + 1]
        guard !next.isWhitespace, next != "$" else { return nil }

        var j = open + 1
        while j < chars.count {
            if chars[j] == "$" {
                let before = chars[j - 1]
                let afterIsDigit = j + 1 < chars.count && chars[j + 1].isNumber
                if !before.isWhitespace, before != "\\", !afterIsDigit, j > open + 1 {
                    return j
                }
            }
            j += 1
        }
        return nil
    }
}
