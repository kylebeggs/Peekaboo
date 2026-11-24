import Foundation
import Yams

/// The model behind Peekaboo's review files: a list of comment threads, either on one
/// document (the `.<doc>.review.md` sidecar) or on a repository's diff
/// (`<repo>/.peekaboo/review.md`, which additionally carries a ``DiffContext`` and
/// line-located anchors). The on-disk format is readable markdown (so it can be
/// handed to an AI agent directly) yet round-trips losslessly through ``parse``
/// and ``serialize``. Inline anchors keep their machine data in a hidden HTML
/// comment so the rendered file stays clean.
public struct ReviewFile: Equatable {
    public var documentName: String
    /// Present only for a repo diff review.
    public var diff: DiffContext?
    public var threads: [CommentThread]

    public init(documentName: String, diff: DiffContext? = nil, threads: [CommentThread] = []) {
        self.documentName = documentName
        self.diff = diff
        self.threads = threads
    }

    /// Where a repo's diff review lives, relative to the working tree root.
    public static let repoReviewDirectory = ".peekaboo"
    public static let repoReviewName = "review.md"

    public static func repoReviewURL(forRepo root: URL) -> URL {
        root.appendingPathComponent(repoReviewDirectory, isDirectory: true).appendingPathComponent(repoReviewName)
    }

    /// The sidecar URL for a document: `draft.md` → `.draft.review.md` (hidden in Finder).
    public static func sidecarURL(forDocument url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let hidden = base.hasPrefix(".") ? base : "." + base
        return url.deletingLastPathComponent().appendingPathComponent(hidden + ".review.md")
    }

    /// A review sidecar is never itself reviewable.
    public static func isSidecar(_ url: URL) -> Bool {
        if url.lastPathComponent.hasSuffix(".review.md") { return true }
        return url.lastPathComponent == repoReviewName
            && url.deletingLastPathComponent().lastPathComponent == repoReviewDirectory
    }
}

/// What a repo diff review is a review *of*: recorded in the file so an agent reading
/// it knows which commit the `old` side of every anchor refers to.
public struct DiffContext: Equatable {
    public var repo: String
    /// The ref the user asked to compare against, e.g. `origin/main`.
    public var base: String
    /// The commit actually diffed against (the merge-base with ``base``).
    public var baseSHA: String

    public init(repo: String, base: String, baseSHA: String) {
        self.repo = repo
        self.base = base
        self.baseSHA = baseSHA
    }
}

/// Where in a diff an anchor points: a line range on one side of one file. The line
/// numbers are a hint, not the truth — the working tree keeps changing under a review,
/// so the anchor's ``CommentAnchor/quote`` is what re-locates it.
public struct CommentLocation: Equatable {
    public var file: String
    public var side: DiffSide
    public var line: Int
    public var endLine: Int

    public init(file: String, side: DiffSide, line: Int, endLine: Int) {
        self.file = file
        self.side = side
        self.line = line
        self.endLine = endLine
    }
}

public enum CommentKind: String, Equatable {
    case inline
    case general
}

public enum CommentStatus: String, Equatable {
    case open
    case resolved
}

/// One thread: an inline thread carries an ``CommentAnchor`` locating it in the
/// rendered document; a general thread is document-level and has none.
public struct CommentThread: Equatable {
    public var id: String
    public var kind: CommentKind
    public var status: CommentStatus
    public var anchor: CommentAnchor?
    public var messages: [CommentMessage]

    public init(
        id: String,
        kind: CommentKind,
        status: CommentStatus = .open,
        anchor: CommentAnchor? = nil,
        messages: [CommentMessage] = []
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.anchor = anchor
        self.messages = messages
    }
}

/// Text-quote anchor: the selected `quote` plus a little surrounding context used
/// to disambiguate it when the same text appears more than once. In a diff review the
/// quote is whole lines, the context is the neighbouring lines, and ``location`` says
/// which file and side they were on.
public struct CommentAnchor: Equatable {
    public var quote: String
    public var prefix: String
    public var suffix: String
    public var location: CommentLocation?

    public init(quote: String, prefix: String = "", suffix: String = "", location: CommentLocation? = nil) {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
        self.location = location
    }
}

public struct CommentMessage: Equatable {
    public var speaker: String
    public var timestamp: String
    public var body: String

    public init(speaker: String, timestamp: String, body: String) {
        self.speaker = speaker
        self.timestamp = timestamp
        self.body = body
    }
}

// MARK: - Serialization

extension ReviewFile {
    private static let sep = "·"
    private static let marker = "<!-- peekaboo-review v1 -->"
    private static let diffOpener = "<!-- pkb-review"

    public func serialize() -> String {
        var out: [String] = ["# Review \(Self.sep) \(documentName)", "", Self.marker]
        if let diff {
            out.append(Self.diffOpener)
            out.append("repo: \(Self.jsonScalar(diff.repo, escapingSlashes: false))")
            out.append("base: \(Self.jsonScalar(diff.base, escapingSlashes: false))")
            out.append("base_sha: \(Self.jsonScalar(diff.baseSHA, escapingSlashes: false))")
            out.append("-->")
        }
        for thread in threads {
            out.append("")
            out.append("## \(thread.kind.rawValue) \(Self.sep) \(thread.status.rawValue) \(Self.sep) #\(thread.id)")
            if thread.kind == .inline, let anchor = thread.anchor {
                for line in anchor.quote.components(separatedBy: "\n") {
                    out.append(line.isEmpty ? ">" : "> " + line)
                }
                out.append("<!-- pkb")
                if let location = anchor.location {
                    out.append("file: \(Self.jsonScalar(location.file, escapingSlashes: false))")
                    out.append("side: \(location.side.rawValue)")
                    out.append("line: \(location.line)")
                    out.append("end_line: \(location.endLine)")
                }
                out.append("prefix: \(Self.jsonScalar(anchor.prefix))")
                out.append("suffix: \(Self.jsonScalar(anchor.suffix))")
                out.append("-->")
            }
            for message in thread.messages {
                out.append("")
                out.append("**\(message.speaker)** \(Self.sep) \(message.timestamp)")
                if !message.body.isEmpty {
                    out.append(message.body)
                }
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A JSON-encoded string is always single-line and is valid YAML (a flow
    /// scalar), so it survives the `<!-- pkb -->` block without block-scalar quirks.
    ///
    /// Paths are written with plain slashes so a person or agent can read them.
    /// `prefix`/`suffix` keep JSONEncoder's default `\/`: existing sidecars were written
    /// that way, and re-saving one must not change bytes nobody edited.
    private static func jsonScalar(_ string: String, escapingSlashes: Bool = true) -> String {
        let encoder = JSONEncoder()
        if !escapingSlashes { encoder.outputFormatting = .withoutEscapingSlashes }
        guard let data = try? encoder.encode([string]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}

// MARK: - Parsing

extension ReviewFile {
    private static let docNameRegex = try! NSRegularExpression(
        pattern: "^#\\s+Review\\s+\(sep)\\s+(.+?)\\s*$")
    private static let threadRegex = try! NSRegularExpression(
        pattern: "^##\\s+(inline|general)\\s+\(sep)\\s+(open|resolved)\\s+\(sep)\\s+#(\\S+)\\s*$")
    /// A message header requires an ISO-date start so prose `**bold** · note`
    /// lines in a body are not mistaken for headers.
    private static let messageRegex = try! NSRegularExpression(
        pattern: "^\\*\\*(.+?)\\*\\*\\s+\(sep)\\s+(\\d{4}-\\d{2}-\\d{2}[^\\n]*?)\\s*$")

    public static func parse(_ text: String) -> ReviewFile {
        let lines = text.components(separatedBy: "\n")
        var documentName = ""
        var headerIndices: [Int] = []
        for (index, line) in lines.enumerated() {
            if documentName.isEmpty, let name = firstGroup(docNameRegex, in: line) {
                documentName = name
            }
            if threadRegex.firstMatch(in: line) != nil {
                headerIndices.append(index)
            }
        }

        // The diff header is only looked for above the first thread, so a comment body
        // that happens to quote the opener is never mistaken for it.
        let preamble = lines[..<(headerIndices.first ?? lines.count)]
        var diff: DiffContext?
        if let opener = preamble.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == diffOpener }) {
            let yaml = preamble[(opener + 1)...].prefix { $0.trimmingCharacters(in: .whitespaces) != "-->" }
            let fields = yamlMapping(yaml.joined(separator: "\n"))
            diff = DiffContext(repo: fields["repo"]?.string ?? "", base: fields["base"]?.string ?? "",
                               baseSHA: fields["base_sha"]?.string ?? "")
        }

        var threads: [CommentThread] = []
        for (position, start) in headerIndices.enumerated() {
            let end = position + 1 < headerIndices.count ? headerIndices[position + 1] : lines.count
            guard let header = threadHeader(lines[start]) else { continue }
            let region = Array(lines[(start + 1)..<end])
            let (anchor, messages) = parseRegion(region, kind: header.kind)
            threads.append(CommentThread(
                id: header.id, kind: header.kind, status: header.status,
                anchor: anchor, messages: messages))
        }
        return ReviewFile(documentName: documentName, diff: diff, threads: threads)
    }

    private static func threadHeader(_ line: String) -> (kind: CommentKind, status: CommentStatus, id: String)? {
        guard let match = threadRegex.firstMatch(in: line),
              let kind = CommentKind(rawValue: group(match, 1, line)),
              let status = CommentStatus(rawValue: group(match, 2, line)) else { return nil }
        return (kind, status, group(match, 3, line))
    }

    private static func parseRegion(_ lines: [String], kind: CommentKind) -> (CommentAnchor?, [CommentMessage]) {
        var index = 0
        func skipBlanks() {
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index += 1 }
        }

        skipBlanks()
        var quoteLines: [String] = []
        while index < lines.count, lines[index] == ">" || lines[index].hasPrefix("> ") {
            quoteLines.append(lines[index] == ">" ? "" : String(lines[index].dropFirst(2)))
            index += 1
        }

        skipBlanks()
        var prefix = "", suffix = ""
        var location: CommentLocation?
        if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "<!-- pkb" {
            index += 1
            var yaml: [String] = []
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "-->" {
                yaml.append(lines[index]); index += 1
            }
            if index < lines.count { index += 1 }
            (prefix, suffix, location) = parseAnchorYAML(yaml.joined(separator: "\n"))
        }

        var messages: [CommentMessage] = []
        while index < lines.count {
            guard let match = messageRegex.firstMatch(in: lines[index]) else { index += 1; continue }
            let speaker = group(match, 1, lines[index])
            let timestamp = group(match, 2, lines[index])
            index += 1
            var body: [String] = []
            while index < lines.count, messageRegex.firstMatch(in: lines[index]) == nil {
                body.append(lines[index]); index += 1
            }
            messages.append(CommentMessage(
                speaker: speaker, timestamp: timestamp, body: trimBlankEdges(body).joined(separator: "\n")))
        }

        let anchor = kind == .inline
            ? CommentAnchor(quote: quoteLines.joined(separator: "\n"), prefix: prefix, suffix: suffix,
                            location: location)
            : nil
        return (anchor, messages)
    }

    private static func parseAnchorYAML(_ yaml: String) -> (String, String, CommentLocation?) {
        let fields = yamlMapping(yaml)
        // A location needs at least a file and a line; a missing end means one line.
        var location: CommentLocation?
        if let file = fields["file"]?.string, let line = fields["line"]?.int {
            location = CommentLocation(
                file: file, side: fields["side"]?.string.flatMap(DiffSide.init(rawValue:)) ?? .new,
                line: line, endLine: max(line, fields["end_line"]?.int ?? line))
        }
        return (fields["prefix"]?.string ?? "", fields["suffix"]?.string ?? "", location)
    }

    private static func yamlMapping(_ yaml: String) -> [String: Yams.Node] {
        guard let node = try? Yams.compose(yaml: yaml), let mapping = node.mapping else { return [:] }
        var fields: [String: Yams.Node] = [:]
        for (key, value) in mapping {
            if let name = key.string { fields[name] = value }
        }
        return fields
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var result = lines
        while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty { result.removeFirst() }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty { result.removeLast() }
        return result
    }

    private static func firstGroup(_ regex: NSRegularExpression, in line: String) -> String? {
        guard let match = regex.firstMatch(in: line) else { return nil }
        return group(match, 1, line)
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ line: String) -> String {
        guard let range = Range(match.range(at: index), in: line) else { return "" }
        return String(line[range])
    }
}

private extension NSRegularExpression {
    func firstMatch(in line: String) -> NSTextCheckingResult? {
        firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }
}
