import XCTest
@testable import MarkdownRenderer

/// Memoisation of KaTeX and highlight.js bridge results. Equations and code here
/// are deliberately distinctive so no other test file has already cached them.
final class JSEngineCacheTests: XCTestCase {
    private func render(_ markdown: String) throws -> String {
        try MarkdownRenderer().renderDocument(markdown: markdown).bodyHTML
    }

    private func count(_ needle: String, in html: String) -> Int {
        html.components(separatedBy: needle).count - 1
    }

    private func logCache(_ engine: JSEngine, _ label: String) {
        let stats = engine.cacheStatistics
        print("JSEngine \(label): bridge calls \(engine.bridgeCallCount), cache \(stats.entries) entries / \(stats.bytes) bytes")
    }

    // MARK: - Renderer level

    func testSecondRenderOfSameMathDocumentSkipsBridge() throws {
        let inline = (1...40).map { "$\\zeta_{\($0)} = \\frac{\($0)}{\\varepsilon}$" }
        let markdown = "# Cache\n\n" + inline.joined(separator: ", ") + "\n\n$$\n\\prod_{k=1}^{40} \\zeta_k\n$$\n"
        let engine = JSEngine.shared

        let callsBefore = engine.bridgeCallCount
        let first = try render(markdown)
        let callsAfterFirst = engine.bridgeCallCount
        logCache(engine, "after first render")
        let second = try render(markdown)
        let callsAfterSecond = engine.bridgeCallCount
        logCache(engine, "after second render")

        XCTAssertEqual(count("class=\"katex\"", in: first), 41, "every equation should render:\n\(first)")
        XCTAssertEqual(callsAfterFirst - callsBefore, 41, "first render should call the bridge once per distinct equation")
        XCTAssertEqual(callsAfterSecond, callsAfterFirst, "second identical render must be served entirely from cache")
        XCTAssertEqual(first, second, "cached output must be byte-identical to the original")
    }

    func testRepeatedEquationWithinOneDocumentRendersOnce() throws {
        let engine = JSEngine.shared
        let callsBefore = engine.bridgeCallCount
        let html = try render("$\\Xi_{dup}$ and again $\\Xi_{dup}$ and once more $\\Xi_{dup}$")
        XCTAssertEqual(count("class=\"katex\"", in: html), 3, html)
        XCTAssertEqual(engine.bridgeCallCount - callsBefore, 1, "identical segments should share one bridge call")
    }

    func testSecondRenderOfSameCodeBlockSkipsBridge() throws {
        let markdown = "```swift\nlet cacheProbe = [1, 2, 3].map { $0 * 7 }\n```\n"
        let engine = JSEngine.shared

        let callsBefore = engine.bridgeCallCount
        let first = try render(markdown)
        let callsAfterFirst = engine.bridgeCallCount
        let second = try render(markdown)
        logCache(engine, "after two code renders")

        XCTAssertTrue(first.contains("class=\"hljs language-swift\""), first)
        XCTAssertEqual(callsAfterFirst - callsBefore, 1)
        XCTAssertEqual(engine.bridgeCallCount, callsAfterFirst, "highlighting must be cached")
        XCTAssertEqual(first, second)
    }

    // MARK: - Engine level

    func testParseFailureIsCached() {
        let engine = JSEngine.shared
        let tex = "\\notARealCommandForCacheTest{x}"
        let first = engine.renderKaTeX(tex: tex, display: false)
        let calls = engine.bridgeCallCount
        let second = engine.renderKaTeX(tex: tex, display: false)
        print("cached failure: \(first)")

        guard case .failure(.parse) = first else { return XCTFail("expected a KaTeX parse failure, got \(first)") }
        XCTAssertEqual(engine.bridgeCallCount, calls, "a deterministic failure must not be retried")
        XCTAssertEqual(first, second)
    }

    func testUnknownLanguageResultIsCached() {
        let engine = JSEngine.shared
        let code = "cache probe for an unknown grammar"
        XCTAssertNil(engine.highlight(code: code, language: "not-a-language"))
        let calls = engine.bridgeCallCount
        XCTAssertNil(engine.highlight(code: code, language: "not-a-language"))
        XCTAssertEqual(engine.bridgeCallCount, calls, "a nil highlight result should be cached too")
    }

    func testDisplayModeIsPartOfTheKey() {
        let engine = JSEngine.shared
        let tex = "\\omega_{modekey}^2"
        let inline = engine.renderKaTeX(tex: tex, display: false)
        let calls = engine.bridgeCallCount
        let display = engine.renderKaTeX(tex: tex, display: true)
        XCTAssertEqual(engine.bridgeCallCount, calls + 1, "display and inline renders are different outputs")
        XCTAssertNotEqual(inline, display)
        guard case .success(let displayHTML) = display else { return XCTFail("\(display)") }
        XCTAssertTrue(displayHTML.contains("katex-display"), displayHTML)
    }

    func testEngineEvictsLeastRecentlyUsedUnderByteCap() throws {
        let byteLimit = 4096
        let engine = JSEngine(cacheEntryLimit: 4000, cacheByteLimit: byteLimit)
        let equations = (0...30).map { "\\alpha_{\($0)}" }

        guard case .success(let firstHTML) = engine.renderKaTeX(tex: equations[0], display: false) else {
            return XCTFail("KaTeX failed to render \(equations[0])")
        }
        let entryBytes = equations[0].utf8.count + firstHTML.utf8.count
        print("one cached equation costs \(entryBytes) bytes; byte limit \(byteLimit)")
        XCTAssertLessThan(entryBytes, byteLimit, "fixture must fit in the cache for the test to be meaningful")

        for tex in equations.dropFirst() {
            _ = engine.renderKaTeX(tex: tex, display: false)
        }
        logCache(engine, "after \(equations.count) distinct equations")
        let stats = engine.cacheStatistics
        XCTAssertLessThanOrEqual(stats.bytes, byteLimit, "cache must stay under its byte cap")
        XCTAssertLessThan(stats.entries, equations.count, "cap should have forced evictions")
        XCTAssertGreaterThan(stats.entries, 0)

        let calls = engine.bridgeCallCount
        _ = engine.renderKaTeX(tex: equations[30], display: false)
        XCTAssertEqual(engine.bridgeCallCount, calls, "the most recent equation must still be cached")

        let refetched = engine.renderKaTeX(tex: equations[0], display: false)
        XCTAssertEqual(engine.bridgeCallCount, calls + 1, "the oldest equation must have been evicted")
        XCTAssertEqual(refetched, .success(firstHTML), "re-rendering after eviction yields the same output")
    }
}
