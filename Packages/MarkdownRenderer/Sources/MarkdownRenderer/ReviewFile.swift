import Foundation
import Yams

/// The model behind Peekaboo's `.<doc>.review.md` sidecar: a list of comment
/// threads on a document. The on-disk format is readable markdown (so it can be
/// handed to an AI agent directly) yet round-trips losslessly through ``parse``
/// and ``serialize``. Inline anchors keep their machine data in a hidden HTML
/// comment so the rendered file stays clean.
public struct ReviewFile: Equatable {
    public var documentName: String
    public var threads: [CommentThread]

    public init(documentName: String, threads: [CommentThread] = []) {
        self.documentName = documentName
        self.threads = threads
    }

    /// The sidecar URL for a document: `draft.md` → `.draft.review.md` (hidden in Finder).
    public static func sidecarURL(forDocument url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let hidden = base.hasPrefix(".") ? base : "." + base
        return url.deletingLastPathComponent().appendingPathComponent(hidden + ".review.md")
    }

    /// A review sidecar is never itself reviewable.
    public static func isSidecar(_ url: URL) -> Bool {
        url.lastPathComponent.hasSuffix(".review.md")
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
/// to disambiguate it when the same text appears more than once.
public struct CommentAnchor: Equatable {
    public var quote: String
    public var prefix: String
    public var suffix: String

    public init(quote: String, prefix: String = "", suffix: String = "") {
        self.quote = quote
        self.prefix = prefix
        self.suffix = suffix
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

    public func serialize() -> String {
        var out: [String] = ["# Review \(Self.sep) \(documentName)", "", Self.marker]
        for thread in threads {
            out.append("")
            out.append("## \(thread.kind.rawValue) \(Self.sep) \(thread.status.rawValue) \(Self.sep) #\(thread.id)")
            if thread.kind == .inline, let anchor = thread.anchor {
                for line in anchor.quote.components(separatedBy: "\n") {
                    out.append(line.isEmpty ? ">" : "> " + line)
                }
                out.append("<!-- pkb")
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
    private static func jsonScalar(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode([string]),
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
        return ReviewFile(documentName: documentName, threads: threads)
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
        if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) == "<!-- pkb" {
            index += 1
            var yaml: [String] = []
            while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "-->" {
                yaml.append(lines[index]); index += 1
            }
            if index < lines.count { index += 1 }
            (prefix, suffix) = parseAnchorYAML(yaml.joined(separator: "\n"))
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
            ? CommentAnchor(quote: quoteLines.joined(separator: "\n"), prefix: prefix, suffix: suffix)
            : nil
        return (anchor, messages)
    }

    private static func parseAnchorYAML(_ yaml: String) -> (String, String) {
        guard let node = try? Yams.compose(yaml: yaml), let mapping = node.mapping else { return ("", "") }
        var prefix = "", suffix = ""
        for (key, value) in mapping {
            switch key.string {
            case "prefix": prefix = value.string ?? ""
            case "suffix": suffix = value.string ?? ""
            default: break
            }
        }
        return (prefix, suffix)
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
