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

    func testDisplayMathInBlockquote() throws {
        let html = try render("> Some text\n> $$\n> x = y\n> $$")
        XCTAssertTrue(html.contains("katex-display"), "expected display math inside blockquote, got:\n\(html)")
        XCTAssertFalse(html.contains("$$"), html)
        XCTAssertTrue(html.contains("Some text"), html)
    }

    func testQuotedSingleLineDisplayMath() throws {
        let html = try render("> $$x = y$$")
        XCTAssertTrue(html.contains("katex-display"), html)
        XCTAssertFalse(html.contains("$$"), html)
    }

    func testGluedDisplayMathOpener() throws {
        // Obsidian lets a $$ block open at the end of a text line.
        let html = try render("or $f$ such as$$\nf(x) = x^2\n$$\nmore text")
        XCTAssertTrue(html.contains("katex-display"), "expected display math, got:\n\(html)")
        XCTAssertTrue(html.contains("such as"), html)
        XCTAssertTrue(html.contains("more text"), html)
        XCTAssertFalse(html.contains("$$"), html)
    }

    func testGluedOpenerWithoutCloserLeftAlone() throws {
        let html = try render("price is 5$$\nand that is all")
        XCTAssertFalse(html.contains("katex"), html)
        XCTAssertTrue(html.contains("5$$"), html)
        XCTAssertTrue(html.contains("and that is all"), html)
    }

    func testGluedDisplayMathCloser() throws {
        // Obsidian lets a $$ block close at the start of a text line; the prose
        // after the delimiter must not be swallowed into the TeX or mispair the
        // next block.
        let html = try render("$$\nC^2 = 1\n$$where $x$ is small, then\n$$\n\\beta = 2\n$$")
        XCTAssertTrue(html.contains("katex-display"), "expected display math, got:\n\(html)")
        XCTAssertTrue(html.contains("is small, then"), "glued prose should survive as text, got:\n\(html)")
        XCTAssertFalse(html.contains("$$"), html)
        XCTAssertFalse(html.contains("math-error"), html)
        XCTAssertEqual(html.components(separatedBy: "katex-display").count - 1, 2,
                       "both blocks should render as display math, got:\n\(html)")
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

    // MARK: - Obsidian callouts

    func testObsidianCalloutWithTitle() throws {
        let html = try render("> [!info] Custom Title\n> Body here.")
        XCTAssertTrue(html.contains("markdown-alert-note"), "info should reuse the note style, got:\n\(html)")
        XCTAssertTrue(html.contains("Custom Title"), html)
        XCTAssertTrue(html.contains("Body here."), html)
        XCTAssertFalse(html.contains("[!info]"), html)
    }

    func testObsidianCalloutKindStyles() throws {
        for (kind, style) in [("info", "note"), ("question", "warning"), ("danger", "caution"),
                              ("example", "important"), ("success", "tip")] {
            let html = try render("> [!\(kind)]\n> Body text.")
            XCTAssertTrue(html.contains("markdown-alert-\(style)"), "\(kind) should map to \(style), got:\n\(html)")
        }
    }

    func testCalloutKindIsCaseInsensitive() throws {
        let html = try render("> [!INFO] Hilbert Space\n> Body.")
        XCTAssertTrue(html.contains("markdown-alert-note"), html)
        XCTAssertTrue(html.contains("Hilbert Space"), html)
    }

    func testCalloutDefaultTitleIsKindName() throws {
        let html = try render("> [!question]\n> Body.")
        XCTAssertTrue(html.contains("Question"), html)
    }

    func testCalloutWithoutSpaceAfterQuoteMarker() throws {
        let html = try render(">[!info]\n> Body.")
        XCTAssertTrue(html.contains("markdown-alert-note"), html)
        XCTAssertFalse(html.contains("[!info]"), html)
    }

    func testCalloutTitleWithInlineMath() throws {
        let html = try render("> [!question] What is $df$ again?\n> Body.")
        XCTAssertTrue(html.contains("markdown-alert-warning"), html)
        XCTAssertTrue(html.contains("class=\"katex\""), "math in the title should render, got:\n\(html)")
        XCTAssertTrue(html.contains("again?"), html)
    }

    func testCalloutTitleKeepsInlineFormatting() throws {
        let html = try render("> [!info] See **this** now\n> Body.")
        XCTAssertTrue(html.contains("<strong>this</strong>"), html)
        XCTAssertTrue(html.contains("See <strong>"), "space before formatting must survive, got:\n\(html)")
    }

    func testCalloutWithDisplayMathBody() throws {
        let html = try render("> [!warning] Not commutative!\n> Careful here\n> $$\n> AB \\neq BA\n> $$")
        XCTAssertTrue(html.contains("markdown-alert-warning"), html)
        XCTAssertTrue(html.contains("katex-display"), "display math inside callout should render, got:\n\(html)")
        XCTAssertFalse(html.contains("$$"), html)
    }

    func testFoldedCalloutMarker() throws {
        let html = try render("> [!info]- Folded Title\n> Body.")
        XCTAssertTrue(html.contains("<details class=\"markdown-alert markdown-alert-note\">"),
                      "folded callout should be a collapsed details element, got:\n\(html)")
        XCTAssertTrue(html.contains("<summary class=\"markdown-alert-title\">"), html)
        XCTAssertTrue(html.contains("</details>"), html)
        XCTAssertTrue(html.contains("Folded Title"), html)
    }

    func testFoldedOpenCallout() throws {
        let html = try render("> [!tip]+ Open Title\n> Body.")
        XCTAssertTrue(html.contains("<details class=\"markdown-alert markdown-alert-tip\" open>"),
                      "[!tip]+ should be an expanded details element, got:\n\(html)")
        XCTAssertTrue(html.contains("Open Title"), html)
    }

    func testBareCalloutStaysDiv() throws {
        let html = try render("> [!info] Plain Title\n> Body.")
        XCTAssertTrue(html.contains("<div class=\"markdown-alert markdown-alert-note\">"), html)
        XCTAssertFalse(html.contains("<details"), "bare callout must not be collapsible, got:\n\(html)")
    }

    func testFoldedCalloutTitleMath() throws {
        let html = try render("> [!question]- What is $df$?\n> Body.")
        XCTAssertTrue(html.contains("<details"), html)
        XCTAssertTrue(html.contains("class=\"katex\""), "math in a folded title should render, got:\n\(html)")
    }

    func testNestedFoldedCallout() throws {
        let html = try render("> [!note]- Outer\n> Outer body.\n> > [!tip] Inner\n> > Inner body.")
        XCTAssertTrue(html.contains("<details class=\"markdown-alert markdown-alert-note\">"), html)
        XCTAssertTrue(html.contains("<div class=\"markdown-alert markdown-alert-tip\">"), html)
        let inner = html.range(of: "markdown-alert-tip")
        let outerClose = html.range(of: "</details>")
        XCTAssertTrue(inner!.upperBound < outerClose!.lowerBound,
                      "inner callout should nest inside the folded outer, got:\n\(html)")
    }

    func testNestedCallouts() throws {
        let html = try render("> [!note] Outer\n> Outer body.\n> > [!warning] Inner\n> > Inner body.")
        XCTAssertTrue(html.contains("markdown-alert-note"), html)
        XCTAssertTrue(html.contains("markdown-alert-warning"), html)
        XCTAssertTrue(html.contains("Inner body."), html)
        let outer = html.range(of: "markdown-alert-note")
        let inner = html.range(of: "markdown-alert-warning")
        let outerClose = html.range(of: "</div>", options: .backwards)
        XCTAssertTrue(outer!.lowerBound < inner!.lowerBound && inner!.upperBound < outerClose!.lowerBound,
                      "inner callout should nest inside the outer, got:\n\(html)")
    }

    func testUnknownCalloutKindLeftAsBlockquote() throws {
        let html = try render("> [!notakind] Title\n> Body.")
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
        // isDirectory: true is required: without the trailing slash, relative
        // resolution against this base URL drops the directory component.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-test-\(UUID().uuidString)", isDirectory: true)
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

    func testPageZoomEmitsBodyZoomRule() throws {
        var options = RenderOptions()
        options.pageZoom = 0.9
        let document = try MarkdownRenderer().renderDocument(markdown: "# Hi", options: options)
        XCTAssertTrue(document.css.contains("body { zoom: 0.9; }"), "expected zoom rule, got:\n\(document.css.suffix(200))")
    }

    func testDefaultPageZoomEmitsNoZoomRule() throws {
        let document = try MarkdownRenderer().renderDocument(markdown: "# Hi")
        XCTAssertFalse(document.css.contains("body { zoom:"), "default options should not emit a zoom rule")
    }
}
