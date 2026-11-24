import Foundation

/// Line anchors for diff reviews: building one from a selection, and finding it again
/// after the files have changed.
///
/// Everything works on the rows the diff displays (``FileDiff/lines(on:)``), never on
/// file contents: a comment can only be shown on a line that is in a hunk, so a line
/// that has left every hunk is as lost to the reader as one that was deleted.
public enum DiffAnchors {
    /// Lines of neighbouring context stored on each side of the quote.
    static let contextLines = 3

    /// An anchor for lines `start...end` on `side` of `file`, clipped to the contiguous
    /// run of displayed lines beginning at `start`. Nil if `start` is not displayed.
    public static func anchor(in file: FileDiff, side: DiffSide, start: Int, end: Int) -> CommentAnchor? {
        guard let path = file.path(on: side) else { return nil }
        let lines = file.lines(on: side)
        guard let first = lines.firstIndex(where: { $0.number == start }) else { return nil }
        var last = first
        while last + 1 < lines.count, lines[last + 1].number == lines[last].number + 1,
              lines[last + 1].number <= end { last += 1 }
        return CommentAnchor(
            quote: lines[first...last].map(\.text).joined(separator: "\n"),
            prefix: context(lines, before: first).joined(separator: "\n"),
            suffix: context(lines, after: last).joined(separator: "\n"),
            location: CommentLocation(file: path, side: side, line: lines[first].number, endLine: lines[last].number))
    }

    /// Where an anchor's quote sits in the current diff: the index of its file and the
    /// line range, or nil if the anchor is outdated.
    public struct Resolution: Equatable {
        public let fileIndex: Int
        public let side: DiffSide
        public let line: Int
        public let endLine: Int
    }

    /// Finds `anchor` in `files`. Every place the quoted lines appear is scored by how
    /// much of the stored context surrounds it; the stored line number only breaks
    /// ties (nearest wins). It is deliberately not tried first: after an insertion
    /// above, a different `}` can sit on the old line number, and it would be accepted
    /// while the real one, context intact, sat a few lines down. A quote that appears
    /// in several places with no context to tell them apart is reported as outdated
    /// rather than re-attached to a guess.
    public static func resolve(_ anchor: CommentAnchor, in files: [FileDiff]) -> Resolution? {
        guard let location = anchor.location,
              let fileIndex = files.firstIndex(where: { $0.path(on: location.side) == location.file })
                ?? files.firstIndex(where: { $0.path(on: .old) == location.file && location.side == .new })
        else { return nil }
        let side = location.side
        let lines = files[fileIndex].lines(on: side)
        let quote = anchor.quote.components(separatedBy: "\n").map(normalize)
        guard !quote.isEmpty, !lines.isEmpty else { return nil }
        let texts = lines.map { normalize($0.text) }

        func matches(at index: Int) -> Bool {
            guard index + quote.count <= lines.count else { return false }
            for offset in 0..<quote.count {
                if texts[index + offset] != quote[offset] { return false }
                // The run must be consecutive lines, not lines from two hunks.
                if offset > 0, lines[index + offset].number != lines[index + offset - 1].number + 1 { return false }
            }
            return true
        }
        func resolution(at index: Int) -> Resolution {
            Resolution(fileIndex: fileIndex, side: side, line: lines[index].number,
                       endLine: lines[index + quote.count - 1].number)
        }

        let before = anchor.prefix.isEmpty ? [] : anchor.prefix.components(separatedBy: "\n").map(normalize)
        let after = anchor.suffix.isEmpty ? [] : anchor.suffix.components(separatedBy: "\n").map(normalize)
        var best: (index: Int, score: Int, distance: Int)?
        var candidates = 0
        for index in lines.indices where matches(at: index) {
            candidates += 1
            var score = 0
            for (offset, text) in before.reversed().enumerated() {
                let at = index - 1 - offset
                guard at >= 0, texts[at] == text else { break }
                score += 1
            }
            for (offset, text) in after.enumerated() {
                let at = index + quote.count + offset
                guard at < texts.count, texts[at] == text else { break }
                score += 1
            }
            let distance = abs(lines[index].number - location.line)
            if best == nil || score > best!.score || (score == best!.score && distance < best!.distance) {
                best = (index, score, distance)
            }
        }
        guard let best, candidates == 1 || best.score > 0 else { return nil }
        return resolution(at: best.index)
    }

    private static func context(_ lines: [(number: Int, text: String)], before index: Int) -> [String] {
        var result: [String] = []
        var at = index - 1
        while at >= 0, result.count < contextLines, lines[at].number == lines[at + 1].number - 1 {
            result.insert(lines[at].text, at: 0)
            at -= 1
        }
        return result
    }

    private static func context(_ lines: [(number: Int, text: String)], after index: Int) -> [String] {
        var result: [String] = []
        var at = index + 1
        while at < lines.count, result.count < contextLines, lines[at].number == lines[at - 1].number + 1 {
            result.append(lines[at].text)
            at += 1
        }
        return result
    }

    /// Trailing whitespace is not worth losing an anchor over (editors strip it, and a
    /// hand-edited review file may not preserve it).
    private static func normalize(_ line: String) -> String {
        var scalars = Substring(line)
        while let last = scalars.last, last == " " || last == "\t" || last == "\r" { scalars.removeLast() }
        return String(scalars)
    }
}
