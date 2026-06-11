import XCTest
@testable import MarkdownRenderer

final class MarkdownRendererTests: XCTestCase {
    private func render(_ markdown: String, baseURL: URL? = nil) throws -> String {
        var options = RenderOptions()
        options.baseURL = baseURL
        return try MarkdownRenderer().renderDocument(markdown: markdown, options: options).bodyHTML
    }

    // MARK: - GFM core

    func testTable() throws {
        let html = try render("| a | b |\n| --- | --- |\n| 1 | 2 |")
        XCTAssertTrue(html.contains("<table>"), "expected a <table>, got:\n\(html)")
        XCTAssertTrue(html.contains("<td>1</td>"), html)
    }

    func testStrikethrough() throws {
        let html = try render("~~gone~~")
        XCTAssertTrue(html.contains("<del>gone</del>"), html)
    }

    func testTaskList() throws {
        let html = try render("- [x] done\n- [ ] todo")
        XCTAssertTrue(html.contains("type=\"checkbox\""), html)
        XCTAssertTrue(html.contains("checked"), html)
    }

    func testAutolink() throws {
        let html = try render("Visit https://example.com today")
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">"), html)
    }

    func testFootnotes() throws {
        let html = try render("Text.[^1]\n\n[^1]: The note.")
        XCTAssertTrue(html.contains("footnote"), "expected footnote markup, got:\n\(html)")
        XCTAssertTrue(html.contains("The note."), html)
    }

    func testRawHTMLPassthrough() throws {
        let html = try render("<details><summary>More</summary>hidden</details>")
        XCTAssertTrue(html.contains("<details>"), html)
    }

    // MARK: - Math

    func testInlineMath() throws {
        let html = try render("Euler: $e^{i\\pi} + 1 = 0$.")
        XCTAssertTrue(html.contains("class=\"katex\""), "expected KaTeX output, got:\n\(html)")
        XCTAssertFalse(html.contains("$e^"), html)
    }

    func testDisplayMath() throws {
        let html = try render("$$\n\\frac{a}{b}\n$$")
        XCTAssertTrue(html.contains("katex-display"), "expected display KaTeX output, got:\n\(html)")
    }

    func testMathFence() throws {
        let html = try render("```math\n\\sum_{i=1}^n i\n```")
        XCTAssertTrue(html.contains("katex-display"), html)
        XCTAssertFalse(html.contains("language-math"), html)
    }

    func testUnderscoresInMathSurviveEmphasis() throws {
        let html = try render("$a_i + b_j$")
        XCTAssertFalse(html.contains("<em>"), html)
        XCTAssertTrue(html.contains("class=\"katex\""), html)
    }

    func testCurrencyIsNotMath() throws {
        let html = try render("It costs $5 and $10 at the store.")
        XCTAssertFalse(html.contains("katex"), html)
        XCTAssertTrue(html.contains("$5 and $10"), html)
    }

    func testDollarInFencedCodeUntouched() throws {
        let html = try render("```\nprice = $42 and $7\n```")
        XCTAssertFalse(html.contains("katex"), html)
        XCTAssertTrue(html.contains("price = $42 and $7"), html)
    }

    func testDollarInInlineCodeUntouched() throws {
        let html = try render("Use `$HOME` and `$PATH` vars.")
        XCTAssertFalse(html.contains("katex"), html)
        XCTAssertTrue(html.contains("<code>$HOME</code>"), html)
    }

    func testDollarInIndentedCodeUntouched() throws {
        let html = try render("Paragraph.\n\n    price = $1 plus $2\n")
        XCTAssertFalse(html.contains("katex"), html)
    }

    func testInvalidMathFallsBackGracefully() throws {
        let html = try render("$\\notarealcommand{x}$")
        // Either MathJax rescued it (svg) or an error badge is shown; never a crash.
        XCTAssertTrue(html.contains("svg") || html.contains("math-error"), html)
    }

    // MARK: - Alerts

    func testNoteAlert() throws {
        let html = try render("> [!NOTE]\n> Useful information.")
        XCTAssertTrue(html.contains("markdown-alert-note"), html)
        XCTAssertTrue(html.contains("Useful information."), html)
        XCTAssertFalse(html.contains("[!NOTE]"), html)
    }

    func testAllAlertKinds() throws {
        for kind in ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"] {
            let html = try render("> [!\(kind)]\n> Body text.")
            XCTAssertTrue(html.contains("markdown-alert-\(kind.lowercased())"), html)
        }
    }

    func testPlainBlockquoteUnchanged() throws {
        let html = try render("> Just a quote.")
        XCTAssertTrue(html.contains("<blockquote>"), html)
        XCTAssertFalse(html.contains("markdown-alert"), html)
    }

    // MARK: - Emoji

    func testEmojiShortcode() throws {
        let html = try render("Ship it :rocket: :+1:")
        XCTAssertTrue(html.contains("🚀"), html)
        XCTAssertTrue(html.contains("👍"), html)
    }

    func testUnknownShortcodeLeftAlone() throws {
        let html = try render("Strange :notarealemoji: code")
        XCTAssertTrue(html.contains(":notarealemoji:"), html)
    }

    func testEmojiNotReplacedInCode() throws {
        let html = try render("`:rocket:` and\n\n```\n:rocket:\n```")
        XCTAssertFalse(html.contains("🚀"), html)
    }

    // MARK: - Front matter

    func testFrontMatterTable() throws {
        let html = try render("---\ntitle: Hello\nauthor: Kyle\n---\n\n# Body")
        XCTAssertTrue(html.contains("frontmatter"), html)
        XCTAssertTrue(html.contains("<th>title</th>"), html)
        XCTAssertTrue(html.contains("<td>Hello</td>"), html)
        XCTAssertFalse(html.contains("title: Hello"), html)
    }

    func testNoFrontMatterWhenUnclosed() throws {
        let html = try render("---\ntitle: Hello\n\n# Body")
        XCTAssertFalse(html.contains("frontmatter"), html)
    }

    // MARK: - Syntax highlighting

    func testCodeHighlighting() throws {
        let html = try render("```python\ndef f(x):\n    return x + 1\n```")
        XCTAssertTrue(html.contains("hljs"), "expected hljs spans, got:\n\(html)")
        XCTAssertTrue(html.contains("language-python"), html)
    }

    func testUnknownLanguageLeftPlain() throws {
        let html = try render("```notalanguage\nstuff\n```")
        XCTAssertTrue(html.contains("stuff"), html)
        XCTAssertFalse(html.contains("class=\"hljs"), html)
    }

    func testMermaidLeftAsCodeBlock() throws {
        let html = try render("```mermaid\ngraph TD;\nA-->B;\n```")
        XCTAssertTrue(html.contains("language-mermaid"), html)
    }

    // MARK: - Headings & images

    func testHeadingAnchors() throws {
        let html = try render("# My Section Title\n\n## My Section Title")
        XCTAssertTrue(html.contains("id=\"my-section-title\""), html)
        XCTAssertTrue(html.contains("id=\"my-section-title-1\""), html)
    }

    func testImageInlining() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("peekaboo-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // 1x1 transparent PNG
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        try png.write(to: dir.appendingPathComponent("pixel.png"))

        let html = try render("![alt](pixel.png)", baseURL: dir)
        XCTAssertTrue(html.contains("data:image/png;base64,"), html)
    }

    func testMissingImageLeftAlone() throws {
        let html = try render("![alt](missing.png)", baseURL: URL(fileURLWithPath: "/tmp"))
        XCTAssertTrue(html.contains("missing.png"), html)
    }

    // MARK: - Full document

    func testKitchenSinkRenders() throws {
        let url = Bundle.module.url(forResource: "kitchen-sink", withExtension: "md", subdirectory: "Fixtures")!
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let document = try MarkdownRenderer().renderDocument(markdown: markdown)
        let html = document.html
        for needle in ["katex", "hljs", "markdown-alert-note", "frontmatter", "🚀", "language-mermaid", "<table>"] {
            XCTAssertTrue(html.contains(needle), "kitchen sink missing: \(needle)")
        }
        XCTAssertTrue(html.contains("@font-face"), "KaTeX fonts should be inlined when math present")
    }

    func testOversizedDocumentSkipsExpensivePasses() throws {
        let filler = String(repeating: "Lorem ipsum dolor sit amet. ", count: 80_000)
        let markdown = "# Big\n\n$e^x$\n\n```python\nx = 1\n```\n\n" + filler
        XCTAssertGreaterThan(markdown.utf8.count, MarkdownRenderer.expensivePassByteLimit)
        let html = try render(markdown)
        XCTAssertTrue(html.contains("peekaboo-notice"), "expected the large-document notice")
        XCTAssertFalse(html.contains("class=\"katex\""), "math should be skipped for oversized docs")
        XCTAssertFalse(html.contains("class=\"hljs"), "highlighting should be skipped for oversized docs")
    }

    func testNoMathMeansNoKaTeXCSS() throws {
        let document = try MarkdownRenderer().renderDocument(markdown: "plain text only")
        XCTAssertFalse(document.css.contains("KaTeX_AMS"), "KaTeX CSS should be omitted without math")
    }
}
