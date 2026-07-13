import XCTest
@testable import MarkdownRenderer

final class CommentMarkdownTests: XCTestCase {
    // MARK: - Native (inline-only) bodies

    func testPlainProseStaysNative() {
        XCTAssertFalse(CommentMarkdown.needsWebRendering("Sounds good, ship it."))
    }

    func testInlineMarkdownStaysNative() {
        XCTAssertFalse(CommentMarkdown.needsWebRendering(
            "Use `renderDocument` here — it is **already cached** and *fast*, see [docs](https://example.com)."))
    }

    func testMultiParagraphProseStaysNative() {
        XCTAssertFalse(CommentMarkdown.needsWebRendering(
            "First thought about the intro.\n\nSecond thought, still plain prose."))
    }

    func testLiteralDollarsStayNative() {
        XCTAssertFalse(CommentMarkdown.needsWebRendering("This costs $5 vs $10 per run."))
    }

    func testComparisonOperatorsStayNative() {
        XCTAssertFalse(CommentMarkdown.needsWebRendering("Holds when a < b and c > d."))
    }

    func testEmptyBodyStaysNative() {
        XCTAssertFalse(CommentMarkdown.needsWebRendering(""))
    }

    // MARK: - Web-rendered bodies

    func testInlineMathNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering(#"The cost is $O(n \log n)$ overall."#))
    }

    func testDisplayMathNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("Gradient:\n\n$$\\nabla f(x) = 2A^T(Ax - b)$$"))
    }

    func testBacktickFenceNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("Try this:\n```swift\nlet x = 1\n```"))
    }

    func testTildeFenceNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("~~~\nraw block\n~~~"))
    }

    func testBulletListNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("Two issues:\n- sign flip\n- off by one"))
    }

    func testOrderedListNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("1. first\n2. second"))
        XCTAssertTrue(CommentMarkdown.needsWebRendering("1) first"))
    }

    func testHeadingNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("## Summary\nLooks fine."))
    }

    func testBlockquoteNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("> quoted context"))
    }

    func testTableNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("| a | b |\n| - | - |\n| 1 | 2 |"))
    }

    func testImageNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("See ![plot](plot.png)"))
    }

    func testWikilinkNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("Compare with [[other-note]]"))
        XCTAssertTrue(CommentMarkdown.needsWebRendering("Embed: ![[figure.png]]"))
    }

    func testRawHTMLNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("line one<br>line two"))
    }

    func testIndentedCodeAfterBlankLineNeedsWeb() {
        XCTAssertTrue(CommentMarkdown.needsWebRendering("Like so:\n\n    let x = 1"))
    }
}
