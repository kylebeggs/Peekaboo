import XCTest
@testable import MarkdownRenderer

final class CodeRenderingTests: XCTestCase {
    private func renderCode(_ source: String, ext: String) throws -> String {
        try MarkdownRenderer().renderDocument(fileContents: source, pathExtension: ext).bodyHTML
    }

    // MARK: - Extension → language map

    func testExtensionToLanguage() {
        XCTAssertEqual(CodeLanguage.highlightLanguage(forPathExtension: "py"), "python")
        XCTAssertEqual(CodeLanguage.highlightLanguage(forPathExtension: "PY"), "python")
        XCTAssertEqual(CodeLanguage.highlightLanguage(forPathExtension: "m"), "matlab")
        XCTAssertEqual(CodeLanguage.highlightLanguage(forPathExtension: "jl"), "julia")
        XCTAssertEqual(CodeLanguage.highlightLanguage(forPathExtension: "cpp"), "cpp")
        XCTAssertEqual(CodeLanguage.highlightLanguage(forPathExtension: "h"), "c")
        XCTAssertNil(CodeLanguage.highlightLanguage(forPathExtension: "md"))
        XCTAssertNil(CodeLanguage.highlightLanguage(forPathExtension: "unknownext"))
    }

    // MARK: - Highlighted rendering

    func testPythonHighlight() throws {
        let html = try renderCode("def f():\n    return 1", ext: "py")
        XCTAssertTrue(html.contains("class=\"hljs language-python\""), html)
        XCTAssertTrue(html.contains("hljs-keyword"), "expected highlighted tokens, got:\n\(html)")
    }

    func testCppHighlight() throws {
        let html = try renderCode("int main() { return 0; }", ext: "cpp")
        XCTAssertTrue(html.contains("class=\"hljs language-cpp\""), html)
    }

    func testMatlabHighlight() throws {
        let html = try renderCode("function y = f(x)\n  y = x.^2;\nend", ext: "m")
        XCTAssertTrue(html.contains("class=\"hljs language-matlab\""), html)
        XCTAssertTrue(html.contains("hljs-"), "expected MATLAB grammar to highlight, got:\n\(html)")
    }

    func testJuliaHighlight() throws {
        let html = try renderCode("f(x) = x^2\nprintln(f(3))", ext: "jl")
        XCTAssertTrue(html.contains("class=\"hljs language-julia\""), html)
        XCTAssertTrue(html.contains("hljs-"), "expected Julia grammar to highlight, got:\n\(html)")
    }

    // MARK: - Fence safety & routing

    func testEmbeddedBacktickFenceDoesNotBreakRender() throws {
        // A Python docstring containing a ``` run must not terminate the wrapper fence.
        let source = "x = '''\n```\ninner_fence_text\n```\n'''\nsentinel_after"
        let html = try renderCode(source, ext: "py")
        XCTAssertTrue(html.contains("class=\"hljs language-python\""), html)
        // The embedded backticks survive as literal code content (a wider wrapper fence
        // means the 3-backtick run cannot close the block); content after them is preserved.
        XCTAssertTrue(html.contains("```"), "embedded backticks were consumed as a fence:\n\(html)")
        XCTAssertTrue(html.contains("inner_fence_text"), "embedded fence content was dropped:\n\(html)")
        XCTAssertTrue(html.contains("sentinel_after"), "content after embedded fence was dropped:\n\(html)")
    }

    func testMarkdownExtensionStillRendersMarkdown() throws {
        let html = try renderCode("# Heading", ext: "md")
        XCTAssertTrue(html.contains("<h1"), "markdown path should produce <h1>, got:\n\(html)")
    }

    func testUnknownExtensionFallsBackToMarkdown() throws {
        let html = try renderCode("# Heading", ext: "")
        XCTAssertTrue(html.contains("<h1"), html)
    }

    func testLargeSourceSkipsHighlighting() throws {
        let big = String(repeating: "x = 1\n", count: 350_000) // > 2MB byte budget
        let html = try renderCode(big, ext: "py")
        XCTAssertFalse(html.contains("class=\"hljs"), "highlighting should be skipped above 2MB")
        XCTAssertTrue(html.contains("peekaboo-notice"), "expected large-document banner, got prefix:\n\(html.prefix(200))")
    }
}
