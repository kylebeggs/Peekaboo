import XCTest
@testable import MarkdownRenderer

/// The repo diff review: parsing git's output, rendering it side by side, and keeping
/// line-anchored comments attached while the files change underneath.
final class DiffReviewTests: XCTestCase {
    // MARK: - Review file

    func testDiffReviewRoundTripsAndLegacySidecarIsUntouched() {
        let review = ReviewFile(
            documentName: "Peekaboo",
            diff: DiffContext(repo: "/Users/k/dev/My Repo", base: "origin/main", baseSHA: "328c1155e0aa"),
            threads: [
                CommentThread(
                    id: "a1b2c3", kind: .inline,
                    anchor: CommentAnchor(
                        quote: "        guard let url = sidecarURL else { return }\n\n    }",
                        prefix: "    private func \"save\"() {\n\tindented with a tab",
                        suffix: "",
                        location: CommentLocation(file: "App/My \"Sources\"/Comment Store.swift", side: .old, line: 134, endLine: 136)),
                    messages: [CommentMessage(speaker: "You", timestamp: "2026-11-24 10:12", body: "This drops the header.")]),
                CommentThread(
                    id: "d4e5f6", kind: .general, status: .resolved,
                    messages: [CommentMessage(speaker: "Claude", timestamp: "2026-11-24 10:15", body: "Done.")]),
            ])
        let text = review.serialize()
        XCTAssertEqual(ReviewFile.parse(text), review, "round-trip mismatch.\n--- serialized ---\n\(text)")

        // A document sidecar written before diff reviews existed must come back out
        // byte for byte: the app rewrites the whole file on every save.
        let legacy = """
        # Review · draft.md

        <!-- peekaboo-review v1 -->

        ## inline · open · #a1b2c3
        > the quoted text
        <!-- pkb
        prefix: "see a\\/b "
        suffix: " tail"
        -->

        **You** · 2026-06-17 14:30
        Please clarify.

        """
        let reparsed = ReviewFile.parse(legacy)
        XCTAssertNil(reparsed.diff)
        XCTAssertNil(reparsed.threads.first?.anchor?.location)
        XCTAssertEqual(reparsed.serialize(), legacy)
    }

    // MARK: - Parser

    /// `Fixtures/review.diff` is real `git diff` output (see the flags in `GitRunner.diff`).
    func testParsesGitOutput() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "review", withExtension: "diff", subdirectory: "Fixtures"))
        let files = UnifiedDiff.parse(try String(contentsOf: url, encoding: .utf8))

        let summary = files.map { file in
            "\(file.status.rawValue) \(file.oldPath ?? "-") -> \(file.newPath ?? "-") +\(file.additions) -\(file.deletions)"
                + (file.isBinary ? " binary" : "")
        }
        XCTAssertEqual(summary, [
            "added - -> empty-new.txt +0 -0",
            "deleted gone.txt -> - +0 -1",
            "modified has space.txt -> has space.txt +1 -1",
            "modified image.bin -> image.bin +0 -0 binary",
            "modified nonl.txt -> nonl.txt +1 -1",
            "renamed pure-old.txt -> pure-new.txt +0 -0",
            "renamed renamed-old.txt -> renamed-new.txt +1 -1",
            "modified script.sh -> script.sh +0 -0",
            "modified tab\there.txt -> tab\there.txt +1 -0",
            "modified tricky.txt -> tricky.txt +2 -1",
        ], "parsed:\n\(summary.joined(separator: "\n"))")

        let script = try XCTUnwrap(files.first { $0.path == "script.sh" })
        XCTAssertEqual([script.oldMode, script.newMode], ["100644", "100755"])

        let nonl = try XCTUnwrap(files.first { $0.path == "nonl.txt" }).hunks[0].lines
        XCTAssertEqual(nonl.map(\.noNewline), [false, true, true], "\(nonl)")

        let renamed = try XCTUnwrap(files.first { $0.path == "renamed-new.txt" }).hunks[0]
        let changed = renamed.lines.filter { $0.kind != .context }
        XCTAssertEqual(changed.map(\.text), ["five", "FIVE"])
        XCTAssertEqual([changed[0].oldNumber, changed[1].newNumber], [5, 5])

        // Lines whose content looks like diff structure: a removed `-- a/…` line reads
        // `--- a/…` in the patch, and the added lines read `+diff --git` and `+@@`.
        let tricky = try XCTUnwrap(files.first { $0.path == "tricky.txt" })
        XCTAssertEqual(tricky.hunks.count, 1)
        XCTAssertEqual(tricky.hunks[0].lines.map(\.text), [
            "keep", "-- a/looks-like-header", "diff --git a/fake b/fake", "@@ -1,1 +1,1 @@", "keep2",
        ])
        XCTAssertEqual(files.last?.path, "tricky.txt", "the look-alike lines must not start a new file")
    }

    // MARK: - Renderer

    func testHunkInsideBlockCommentIsHighlightedFromWholeFile() throws {
        func source(_ changed: String) -> String {
            (["/* a comment that opens", " c2", " c3", " c4", " c5", " c6 <b> & co", " c7", changed, " c9", " c10 */",
              "let x = 1", "let y = 2"]).joined(separator: "\n") + "\n"
        }
        let old = source(" old c8"), new = source(" new c8")
        // The hunk starts at line 5: nothing in it says these lines are in a comment.
        let diff = """
        diff --git a/a.swift b/a.swift
        index 1111111..2222222 100644
        --- a/a.swift
        +++ b/a.swift
        @@ -5,7 +5,7 @@
          c5
          c6 <b> & co
          c7
        - old c8
        + new c8
          c9
          c10 */
         let x = 1

        """
        let file = try XCTUnwrap(UnifiedDiff.parse(diff).first)
        var budget = DiffRenderer.highlightBudget
        let html = DiffRenderer().body(for: file, old: old, new: new, forceLoad: false, budget: &budget).html

        let cells = try NSRegularExpression(
            pattern: "<td class=\"c ([lr])[^\"]*\" data-l=\"(\\d+)\"><span class=\"t\">(.*?)</span></td>")
        let matches = cells.matches(in: html, range: NSRange(html.startIndex..., in: html))
        XCTAssertEqual(matches.count, 14, "7 lines a side expected:\n\(html)")
        for match in matches {
            func group(_ index: Int) -> String { String(html[Range(match.range(at: index), in: html)!]) }
            let lines = (group(1) == "l" ? old : new).components(separatedBy: "\n")
            let number = Int(group(2))!
            let inner = group(3)
            let text = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
            XCTAssertEqual(text, lines[number - 1], "side \(group(1)) line \(number): \(inner)")
            if number <= 10 {
                XCTAssertTrue(inner.contains("hljs-comment"), "line \(number) is inside the comment: \(inner)")
            } else {
                XCTAssertTrue(inner.contains("hljs-keyword"), "line \(number) is code: \(inner)")
            }
        }
        // The changed word is marked on both sides, and only it.
        XCTAssertTrue(html.contains("<span class=\"x\">old</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"x\">new</span>"), html)
    }

    func testOversizedFileIsDeferredWithoutHighlighting() {
        let source = (1...2500).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let file = UnifiedDiff.untracked(path: "Generated.swift", contents: Data(source.utf8))
        let renderer = DiffRenderer()
        XCTAssertFalse(renderer.wantsContents(file, forceLoad: false))

        let callsBefore = JSEngine.shared.bridgeCallCount
        var budget = DiffRenderer.highlightBudget
        let deferred = renderer.body(for: file, old: nil, new: source, forceLoad: false, budget: &budget).html
        XCTAssertTrue(deferred.contains("Large diffs are not rendered by default"), String(deferred.prefix(300)))
        XCTAssertTrue(deferred.contains("data-pkb-load"))
        XCTAssertFalse(deferred.contains("<table"))
        XCTAssertEqual(JSEngine.shared.bridgeCallCount, callsBefore, "a deferred file must not reach the highlighter")

        let loaded = renderer.body(for: file, old: nil, new: source, forceLoad: true, budget: &budget).html
        XCTAssertTrue(loaded.contains("data-l=\"2500\""), "Load diff renders every row")
    }

    // MARK: - Anchors

    /// A file as the diff shows it when wholly new: every line numbered on the new side.
    private func diff(_ lines: [String]) -> [FileDiff] {
        [UnifiedDiff.untracked(path: "a.swift", contents: Data((lines.joined(separator: "\n") + "\n").utf8))]
    }

    func testAnchorsFollowTheirLinesOrGoOutdated() throws {
        let original = ["func a() {", "    work()", "}", "", "func b() {", "    more()", "}"]
        let files = diff(original)
        let work = try XCTUnwrap(DiffAnchors.anchor(in: files[0], side: .new, start: 2, end: 2))
        XCTAssertEqual(work.quote, "    work()")
        XCTAssertEqual(work.location, CommentLocation(file: "a.swift", side: .new, line: 2, endLine: 2))

        // Lines inserted above: the anchor moves with its text.
        let shifted = DiffAnchors.resolve(work, in: diff(["import A", "import B"] + original))
        XCTAssertEqual([shifted?.line, shifted?.endLine], [4, 4], "\(String(describing: shifted))")

        // The commented line itself was edited: the comment is about text that is gone.
        var edited = original
        edited[1] = "    work(harder)"
        XCTAssertNil(DiffAnchors.resolve(work, in: diff(edited)))

        // A quote with no identity of its own. Once its surroundings are rewritten there
        // are several `}` and nothing to choose between them: outdated, not a guess.
        let brace = try XCTUnwrap(DiffAnchors.anchor(in: files[0], side: .new, start: 3, end: 3))
        let rewritten = ["func a2() {", "    other()", "    again()", "}", "let x = 1", "func c() {", "}"]
        XCTAssertNil(DiffAnchors.resolve(brace, in: diff(rewritten)))
        // …whereas the same quote with its context intact is found wherever it moved.
        let moved = DiffAnchors.resolve(brace, in: diff(["// header", "func z() {", "}"] + original))
        XCTAssertEqual(moved?.line, 6, "\(String(describing: moved))")
    }
}
