import Foundation

/// Renders parsed diffs as GitHub-style split (side-by-side) HTML.
///
/// The page is built from independent pieces so the app can replace one file at a time:
/// ``body(for:old:new:forceLoad:budget:)`` is the expensive part (highlighting) and
/// depends only on the file's patch; ``fileHTML(_:id:body:viewed:)`` wraps it in the
/// collapsible header; ``page(title:summary:files:)`` assembles the document.
///
/// One instance per review window: it owns that window's highlight cache.
public final class DiffRenderer {
    public struct Limits {
        /// Above either, a file shows "Large diffs are not rendered by default".
        public var maxRows = 2000
        public var maxPatchBytes = 200_000
        /// A side larger than this, or with a longer line, is shown unhighlighted.
        public var maxHighlightBytes = 256 * 1024
        public var maxLineLength = 5000

        public init() {}
    }

    public struct Body {
        public let html: String
        /// Highlighting was skipped only because the per-refresh budget ran out; a
        /// later render with a fresh budget would produce a better result.
        public let highlightDeferred: Bool
    }

    /// Bytes of uncached source one refresh may highlight; the same ceiling the
    /// markdown path uses for its expensive passes.
    public static let highlightBudget = MarkdownRenderer.expensivePassByteLimit

    public var limits = Limits()
    private let highlighter = DiffHighlighter()

    public init() {}

    // MARK: - Gates

    private static let lockfiles: Set<String> = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "Package.resolved",
        "Manifest.toml", "Gemfile.lock", "poetry.lock", "uv.lock", "composer.lock",
        "Podfile.lock", "go.sum", "flake.lock",
    ]

    private func isDeferred(_ file: FileDiff) -> Bool {
        let rows = file.hunks.reduce(0) { $0 + $1.lines.count }
        let name = (file.path as NSString).lastPathComponent
        return rows > limits.maxRows || file.patchBytes > limits.maxPatchBytes || Self.lockfiles.contains(name)
    }

    /// Whether ``body(for:old:new:forceLoad:budget:)`` would use the file's contents,
    /// so the caller can skip reading them for binary, empty and deferred files.
    public func wantsContents(_ file: FileDiff, forceLoad: Bool) -> Bool {
        guard !file.isBinary, !file.isSubmodule, !file.hunks.isEmpty else { return false }
        return forceLoad || !isDeferred(file)
    }

    // MARK: - File body

    /// The diff table (or a one-line note) for one file. `old` and `new` are the
    /// complete file contents on each side, used only for syntax highlighting; pass nil
    /// when a side does not exist or could not be read.
    public func body(for file: FileDiff, old: String?, new: String?, forceLoad: Bool, budget: inout Int) -> Body {
        if file.isBinary { return note("Binary file not shown.") }
        if file.hunks.isEmpty {
            if file.status == .renamed { return note("File renamed without changes.") }
            if let oldMode = file.oldMode, let newMode = file.newMode, oldMode != newMode {
                return note("File mode changed from \(oldMode) to \(newMode).")
            }
            return note("Empty file.")
        }
        if !forceLoad, isDeferred(file) {
            return note("Large diffs are not rendered by default.<button type=\"button\" data-pkb-load>Load diff</button>")
        }

        var deferred = false
        let oldLines = highlighted(old, path: file.oldPath, budget: &budget, deferred: &deferred)
        let newLines = highlighted(new, path: file.newPath, budget: &budget, deferred: &deferred)

        var out = "<table class=\"split\"><colgroup><col class=\"cn\"><col><col class=\"cn\"><col></colgroup><tbody>"
        out.reserveCapacity(file.patchBytes * 4)
        for hunk in file.hunks {
            out += "<tr class=\"hunk\"><td class=\"n\"></td><td class=\"hh\" colspan=\"3\">"
            out += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
            if !hunk.section.isEmpty { out += " " + escapeHTML(hunk.section) }
            out += "</td></tr>"
            for row in Self.rows(of: hunk) {
                var left = row.left.map { cellHTML($0, side: .old, lines: oldLines) }
                var right = row.right.map { cellHTML($0, side: .new, lines: newLines) }
                // A removed line paired with an added one: mark what changed within it.
                if let removed = row.left, let added = row.right, removed.kind == .removed,
                   let ranges = Self.changedRanges(removed.text, added.text) {
                    left = left.map { DiffHighlighter.mark($0, range: ranges.0) }
                    right = right.map { DiffHighlighter.mark($0, range: ranges.1) }
                }
                out += "<tr>"
                Self.appendCell(&out, line: row.left, side: .old, html: left)
                Self.appendCell(&out, line: row.right, side: .new, html: right)
                out += "</tr>"
            }
        }
        out += "</tbody></table>"
        return Body(html: out, highlightDeferred: deferred)
    }

    private func note(_ html: String) -> Body {
        Body(html: "<div class=\"note\">\(html)</div>", highlightDeferred: false)
    }

    private struct SideLines {
        let source: [Substring]
        let html: [String]
    }

    private func highlighted(_ contents: String?, path: String?, budget: inout Int, deferred: inout Bool) -> SideLines? {
        guard let contents, let path, contents.utf8.count <= limits.maxHighlightBytes,
              let language = Self.language(forPath: path) else { return nil }
        let source = contents.split(separator: "\n", omittingEmptySubsequences: false)
        guard !source.contains(where: { $0.utf8.count > limits.maxLineLength }) else { return nil }
        var exhausted = false
        let html = highlighter.lines(of: contents, language: language, budget: &budget, exhausted: &exhausted)
        if exhausted { deferred = true }
        guard let html, html.count == source.count else { return nil }
        return SideLines(source: source, html: html)
    }

    private static func language(forPath path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["md", "markdown", "mdown", "mkd", "mkdn"].contains(ext) { return "markdown" }
        return CodeLanguage.highlightLanguage(forPathExtension: ext)
    }

    /// The line's inner HTML: its highlighted form when the file contents still agree
    /// with the diff (they are read separately, so the file can change in between),
    /// otherwise the escaped plain text.
    private func cellHTML(_ line: DiffLine, side: DiffSide, lines: SideLines?) -> String {
        if let lines, let number = line.number(on: side), number >= 1, number <= lines.source.count,
           lines.source[number - 1] == line.text {
            return lines.html[number - 1]
        }
        return escapeHTML(line.text)
    }

    private static func appendCell(_ out: inout String, line: DiffLine?, side: DiffSide, html: String?) {
        guard let line, let number = line.number(on: side) else {
            out += "<td class=\"n nil\"></td><td class=\"c nil\"></td>"
            return
        }
        let kind = line.kind == .added ? " add" : line.kind == .removed ? " del" : ""
        let sideClass = side == .old ? "l" : "r"
        out += "<td class=\"n\(kind)\" data-n=\"\(number)\"></td>"
        out += "<td class=\"c \(sideClass)\(kind)\(line.noNewline ? " nonl" : "")\" data-l=\"\(number)\">"
        out += "<span class=\"t\">\(html ?? "")</span></td>"
    }

    // MARK: - Row pairing

    struct Row: Equatable {
        var left: DiffLine?
        var right: DiffLine?
    }

    /// Lays a hunk out side by side: a context line fills both columns; within a run of
    /// changes the i-th removed line sits beside the i-th added line, and whichever
    /// side runs out first leaves blank cells.
    static func rows(of hunk: DiffHunk) -> [Row] {
        var rows: [Row] = []
        rows.reserveCapacity(hunk.lines.count)
        var index = 0
        let lines = hunk.lines
        while index < lines.count {
            if lines[index].kind == .context {
                rows.append(Row(left: lines[index], right: lines[index]))
                index += 1
                continue
            }
            let removedStart = index
            while index < lines.count, lines[index].kind == .removed { index += 1 }
            let addedStart = index
            while index < lines.count, lines[index].kind == .added { index += 1 }
            let removed = lines[removedStart..<addedStart], added = lines[addedStart..<index]
            for offset in 0..<max(removed.count, added.count) {
                rows.append(Row(
                    left: offset < removed.count ? removed[removedStart + offset] : nil,
                    right: offset < added.count ? added[addedStart + offset] : nil))
            }
        }
        return rows
    }

    /// The differing middle of two lines after trimming their common prefix and suffix,
    /// as Unicode-scalar ranges. Nil when the lines share nothing worth pointing at
    /// (beyond indentation), where marking would just repaint the whole line.
    static func changedRanges(_ old: String, _ new: String) -> (Range<Int>, Range<Int>)? {
        let a = Array(old.unicodeScalars), b = Array(new.unicodeScalars)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let shared = a[..<prefix].filter { !$0.properties.isWhitespace }.count
            + a[(a.count - suffix)...].filter { !$0.properties.isWhitespace }.count
        guard shared > 0 else { return nil }
        return (prefix..<(a.count - suffix), prefix..<(b.count - suffix))
    }

    // MARK: - Page assembly

    /// One file as a collapsible `<details>`: header (path, status, counts, Viewed)
    /// plus `body`. A viewed file starts closed.
    public static func fileHTML(_ file: FileDiff, id: String, body: String, viewed: Bool) -> String {
        var title = escapeHTML(file.path)
        if file.status == .renamed, let old = file.oldPath, let new = file.newPath {
            title = "\(escapeHTML(old)) → \(escapeHTML(new))"
        }
        var badges = ""
        if file.status != .modified { badges += "<span class=\"badge\">\(file.status.rawValue)</span>" }
        if file.isBinary { badges += "<span class=\"badge\">binary</span>" }
        if file.isSubmodule { badges += "<span class=\"badge\">submodule</span>" }
        var stat = ""
        if !file.hunks.isEmpty {
            stat = "<span class=\"stat\"><span class=\"plus\">+\(file.additions)</span> "
                + "<span class=\"minus\">−\(file.deletions)</span></span>"
        }
        return """
        <details class="file" id="\(escapeHTML(id))"\(viewed ? "" : " open")>\
        <summary><span class="chev"></span><span class="path">\(title)</span>\(badges)\(stat)\
        <label class="viewed"><input type="checkbox" data-pkb-viewed\(viewed ? " checked" : "")>Viewed</label>\
        </summary><div class="body">\(body)</div></details>
        """
    }

    /// The strip above the files: totals, what the diff is against, and any notices.
    public static func summaryHTML(files: [FileDiff], base: String, notices: [String] = []) -> String {
        var out = ""
        if files.isEmpty {
            out += "<div class=\"empty\">No changes against \(escapeHTML(base)).</div>"
        } else {
            let additions = files.reduce(0) { $0 + $1.additions }
            let deletions = files.reduce(0) { $0 + $1.deletions }
            out += "<div class=\"line\"><span class=\"count\">\(files.count) file\(files.count == 1 ? "" : "s") changed</span>"
            out += "<span><span class=\"plus\">+\(additions)</span> <span class=\"minus\">−\(deletions)</span></span>"
            out += "<span class=\"base\">against \(escapeHTML(base))</span></div>"
        }
        for notice in notices {
            out += "<div class=\"notice\">\(escapeHTML(notice))</div>"
        }
        return out
    }

    public static var css: String { DiffCSS.css }

    public static func page(title: String, summary: String, files: [String]) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <style id="peekaboo-style">
        \(DiffCSS.css)
        </style>
        </head>
        <body class="pkb-diff">
        <div id="pkb-summary">\(summary)</div>
        <div id="pkb-files">\(files.joined(separator: "\n"))</div>
        </body>
        </html>
        """
    }
}
