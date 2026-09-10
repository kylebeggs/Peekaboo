import XCTest
@testable import MarkdownRenderer

/// The inline `$...$` scanner. A `$` that opens nothing must not cost a fresh scan
/// of the rest of the line — a line of dollar amounts is otherwise quadratic.
final class InlineMathScanTests: XCTestCase {
    private func extract(_ source: String) -> String {
        MathExtractor.extract(from: source, into: MathRegistry())
    }

    // MARK: - Behaviour

    func testDollarAmountsAreLeftAlone() {
        let line = "Costs $1 and $2 and $3 for the year."
        XCTAssertEqual(extract(line), line, "no `$` here can close, so nothing is math")
    }

    func testMathStillPairsAfterALeadingLoneDollar() {
        let source = "$ not an opener but $x + y$ is math"
        let extracted = extract(source)
        XCTAssertFalse(extracted.contains("$x + y$"), "the equation should have been replaced by a token:\n\(extracted)")
        XCTAssertTrue(extracted.hasPrefix("$ not an opener but "), extracted)
    }

    /// Each line is scanned independently, so giving up on one line must not
    /// disarm the scanner for the next.
    func testMathOnALaterLineStillRendersAfterAnUnclosableLine() throws {
        let markdown = "Prices $1 $2 $3 for the year.\n\nThen $\\gamma_{scan}$ closes.\n"
        let html = try MarkdownRenderer().renderDocument(markdown: markdown).bodyHTML
        XCTAssertTrue(html.contains("class=\"katex\""), "the later equation must still render:\n\(html)")
        XCTAssertTrue(html.contains("$1 $2 $3"), "the dollar amounts must survive verbatim:\n\(html)")
    }

    func testEmptyAndAdjacentDollarsAreNotMath() {
        XCTAssertEqual(extract("$$"), "$$")
        XCTAssertEqual(extract("a $ b $ c"), "a $ b $ c", "a `$` followed by a space cannot open")
    }

    // MARK: - Cost

    func testLineOfDollarAmountsScansLinearly() {
        let line = (1...3000).map { "$\($0)" }.joined(separator: " ")
        let start = Date()
        let extracted = extract(line)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "inline scan: %d chars in %.1f ms", line.count, elapsed * 1000))

        XCTAssertEqual(extracted, line, "nothing on this line is math")
        XCTAssertLessThan(elapsed, 0.05, "a failed scan must not restart at every `$`")
    }
}
