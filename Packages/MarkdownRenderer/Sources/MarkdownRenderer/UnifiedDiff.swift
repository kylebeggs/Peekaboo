import CryptoKit
import Foundation

public enum DiffSide: String, Equatable {
    case old
    case new
}

public struct DiffLine: Equatable {
    public enum Kind: Equatable {
        case context
        case added
        case removed
    }

    public var kind: Kind
    public var oldNumber: Int?
    public var newNumber: Int?
    public var text: String
    /// The line is the last in its file and has no trailing newline.
    public var noNewline = false

    public func number(on side: DiffSide) -> Int? {
        side == .old ? oldNumber : newNumber
    }
}

public struct DiffHunk: Equatable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// The text git prints after the closing `@@` (usually the enclosing function).
    public var section: String
    public var lines: [DiffLine]
}

/// One file's changes, as parsed from `git diff` output.
public struct FileDiff: Equatable {
    public enum Status: String, Equatable {
        case added
        case deleted
        case modified
        case renamed
    }

    public var oldPath: String?
    public var newPath: String?
    public var status: Status = .modified
    public var isBinary = false
    public var oldMode: String?
    public var newMode: String?
    public var hunks: [DiffHunk] = []
    /// Hash of the file's whole patch block (blob ids included): changes whenever
    /// anything about the rendered diff could.
    public var digest = ""
    public var patchBytes = 0

    /// The path to show and to key the file by: the new one, or the old one if deleted.
    public var path: String { newPath ?? oldPath ?? "" }

    public func path(on side: DiffSide) -> String? {
        side == .old ? oldPath : newPath
    }

    public var isSubmodule: Bool { oldMode == "160000" || newMode == "160000" }

    public var additions: Int { count(.added) }
    public var deletions: Int { count(.removed) }

    private func count(_ kind: DiffLine.Kind) -> Int {
        hunks.reduce(0) { $0 + $1.lines.lazy.filter { $0.kind == kind }.count }
    }

    /// Hash of the changed lines only. Unlike ``digest`` it ignores hunk positions and
    /// context, so it survives the base moving underneath an unchanged change — the
    /// "have I already looked at this?" identity behind the Viewed checkbox.
    public var changeDigest: String {
        guard !hunks.isEmpty else { return digest }
        var hasher = SHA256()
        hasher.update(data: Data(((oldPath ?? "") + "\n" + (newPath ?? "") + "\n").utf8))
        for hunk in hunks {
            for line in hunk.lines where line.kind != .context {
                hasher.update(data: Data(((line.kind == .added ? "+" : "-") + line.text + "\n").utf8))
            }
        }
        return UnifiedDiff.hex(hasher.finalize())
    }

    /// The numbered lines visible on one side of the diff, in order: context plus
    /// removed lines for `.old`, context plus added lines for `.new`.
    public func lines(on side: DiffSide) -> [(number: Int, text: String)] {
        var result: [(number: Int, text: String)] = []
        for hunk in hunks {
            for line in hunk.lines {
                if let number = line.number(on: side) { result.append((number, line.text)) }
            }
        }
        return result
    }
}

/// Parser for `git diff` output. Expects git's default `a/` and `b/` path prefixes.
public enum UnifiedDiff {
    public static func parse(_ text: String) -> [FileDiff] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var files: [FileDiff] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else {
                index += 1
                continue
            }
            let start = index
            files.append(parseFile(lines, &index))
            let block = lines[start..<index].joined(separator: "\n")
            files[files.count - 1].digest = hex(SHA256.hash(data: Data(block.utf8)))
            files[files.count - 1].patchBytes = block.utf8.count
        }
        return files
    }

    /// A file git does not track yet, shown as wholly added. `contents` is nil when the
    /// file could not be read; binary data is detected the way git does (a NUL early on).
    public static func untracked(path: String, contents: Data?) -> FileDiff {
        var file = FileDiff(oldPath: nil, newPath: path, status: .added)
        var hasher = SHA256()
        hasher.update(data: Data(("untracked\n" + path + "\n").utf8))
        if let contents { hasher.update(data: contents) }
        file.digest = hex(hasher.finalize())
        file.patchBytes = contents?.count ?? 0
        guard let contents, !contents.prefix(8000).contains(0),
              let text = String(data: contents, encoding: .utf8) else {
            file.isBinary = true
            return file
        }
        guard !text.isEmpty else { return file }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false)
        let endsWithNewline = parts.last?.isEmpty == true
        if endsWithNewline { parts.removeLast() }
        var lines = parts.enumerated().map { offset, part in
            DiffLine(kind: .added, oldNumber: nil, newNumber: offset + 1, text: String(part))
        }
        if !endsWithNewline, !lines.isEmpty { lines[lines.count - 1].noNewline = true }
        file.hunks = [DiffHunk(oldStart: 0, oldCount: 0, newStart: 1, newCount: lines.count,
                               section: "", lines: lines)]
        return file
    }

    // MARK: - One file

    private static func parseFile(_ lines: [Substring], _ index: inout Int) -> FileDiff {
        var file = FileDiff()
        let gitLine = lines[index].dropFirst("diff --git ".count)
        index += 1

        var renameFrom: String?
        var renameTo: String?
        // Outer optional: was the `---`/`+++` line present; inner: nil for /dev/null.
        var minus: String??
        var plus: String??

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@ ") { break }
            if let rest = line.dropping(prefix: "old mode ") {
                file.oldMode = String(rest)
            } else if let rest = line.dropping(prefix: "new mode ") {
                file.newMode = String(rest)
            } else if let rest = line.dropping(prefix: "deleted file mode ") {
                file.status = .deleted
                file.oldMode = String(rest)
            } else if let rest = line.dropping(prefix: "new file mode ") {
                file.status = .added
                file.newMode = String(rest)
            } else if let rest = line.dropping(prefix: "rename from ") {
                file.status = .renamed
                renameFrom = unquote(rest)
            } else if let rest = line.dropping(prefix: "rename to ") {
                renameTo = unquote(rest)
            } else if let rest = line.dropping(prefix: "index ") {
                // `index <old>..<new> <mode>`: the mode is only there when it did not change.
                if let mode = rest.split(separator: " ").dropFirst().first {
                    file.oldMode = file.oldMode ?? String(mode)
                    file.newMode = file.newMode ?? String(mode)
                }
            } else if let rest = line.dropping(prefix: "--- ") {
                minus = .some(markerPath(rest))
            } else if let rest = line.dropping(prefix: "+++ ") {
                plus = .some(markerPath(rest))
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                file.isBinary = true
            }
            index += 1
        }

        while index < lines.count, let header = HunkHeader(lines[index]) {
            index += 1
            file.hunks.append(parseHunk(header, lines, &index))
        }

        // Most specific source first: the rename lines carry bare paths; `---`/`+++`
        // exist only when there is a text hunk; the `diff --git` line is last because it
        // can only be split unambiguously when both halves name the same path.
        let fallback = sharedPath(gitLine)
        switch minus {
        case .some(let path): file.oldPath = path
        case .none: file.oldPath = file.status == .added ? nil : (renameFrom ?? fallback)
        }
        switch plus {
        case .some(let path): file.newPath = path
        case .none: file.newPath = file.status == .deleted ? nil : (renameTo ?? fallback)
        }
        if let renameFrom { file.oldPath = renameFrom }
        if let renameTo { file.newPath = renameTo }
        return file
    }

    /// Consumes exactly the line counts the header promises rather than scanning for the
    /// next header: a removed line whose text is `-- a/x` reads `--- a/x` in the patch,
    /// and an added `diff --git …` line is perfectly legal content.
    private static func parseHunk(_ header: HunkHeader, _ lines: [Substring], _ index: inout Int) -> DiffHunk {
        var hunk = DiffHunk(oldStart: header.oldStart, oldCount: header.oldCount,
                            newStart: header.newStart, newCount: header.newCount,
                            section: header.section, lines: [])
        var oldLeft = header.oldCount, newLeft = header.newCount
        var oldNumber = header.oldStart, newNumber = header.newStart
        while oldLeft > 0 || newLeft > 0, index < lines.count {
            let line = lines[index]
            index += 1
            switch line.first {
            case "\\":
                if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].noNewline = true }
            case "+":
                hunk.lines.append(DiffLine(kind: .added, oldNumber: nil, newNumber: newNumber,
                                           text: String(line.dropFirst())))
                newNumber += 1
                newLeft -= 1
            case "-":
                hunk.lines.append(DiffLine(kind: .removed, oldNumber: oldNumber, newNumber: nil,
                                           text: String(line.dropFirst())))
                oldNumber += 1
                oldLeft -= 1
            default:
                // A context line; tolerate one whose leading space was stripped.
                hunk.lines.append(DiffLine(kind: .context, oldNumber: oldNumber, newNumber: newNumber,
                                           text: String(line.dropFirst())))
                oldNumber += 1
                newNumber += 1
                oldLeft -= 1
                newLeft -= 1
            }
        }
        if index < lines.count, lines[index].first == "\\" {
            if !hunk.lines.isEmpty { hunk.lines[hunk.lines.count - 1].noNewline = true }
            index += 1
        }
        return hunk
    }

    private struct HunkHeader {
        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1
        var section = ""

        /// `@@ -12,7 +12,9 @@ func foo()`; a missing count means 1.
        init?(_ line: Substring) {
            guard line.hasPrefix("@@ -"), let close = line.dropFirst(2).range(of: " @@") else { return nil }
            let ranges = line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2, ranges[1].first == "+" else { return nil }
            func parse(_ range: Substring) -> (Int, Int)? {
                let parts = range.dropFirst().split(separator: ",")
                guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
                return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
            }
            guard let old = parse(ranges[0]), let new = parse(ranges[1]) else { return nil }
            (oldStart, oldCount) = old
            (newStart, newCount) = new
            section = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Paths

    /// The path on a `---`/`+++` line: nil for `/dev/null`, else the path without its
    /// `a/` or `b/` prefix. Git appends a tab when the path contains a space.
    private static func markerPath(_ raw: Substring) -> String? {
        var text = raw
        if text.last == "\t" { text = text.dropLast() }
        let path = unquote(text)
        if path == "/dev/null" { return nil }
        return String(path.dropFirst(2))
    }

    /// The path from `a/<path> b/<path>` when both halves are the same path, which is
    /// the only case where the line can be split without guessing.
    private static func sharedPath(_ gitLine: Substring) -> String? {
        if gitLine.first == "\"" {
            // "a/<quoted>" "b/<quoted>": take the first quoted token.
            var escaped = false
            var end = gitLine.index(after: gitLine.startIndex)
            while end < gitLine.endIndex {
                let character = gitLine[end]
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { break }
                end = gitLine.index(after: end)
            }
            guard end < gitLine.endIndex else { return nil }
            return String(unquote(gitLine[gitLine.startIndex...end]).dropFirst(2))
        }
        let bytes = Array(gitLine.utf8)
        guard bytes.count >= 5, (bytes.count - 5) % 2 == 0 else { return nil }
        let length = (bytes.count - 5) / 2
        let first = bytes[2..<(2 + length)]
        let second = bytes[(5 + length)...]
        guard first.elementsEqual(second), bytes.starts(with: Array("a/".utf8)) else { return nil }
        return String(decoding: first, as: UTF8.self)
    }

    /// Undoes git's C-style quoting (`"a/tab\there"`); unquoted input is returned as is.
    static func unquote(_ raw: Substring) -> String {
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else { return String(raw) }
        let bytes = Array(raw.dropFirst().dropLast().utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                out.append(byte)
                index += 1
                continue
            }
            let next = bytes[index + 1]
            index += 2
            switch next {
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "a"): out.append(0x07)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < bytes.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index]) {
                    value = value * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                out.append(UInt8(truncatingIfNeeded: value))
            default: out.append(next)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Substring {
    func dropping(prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
