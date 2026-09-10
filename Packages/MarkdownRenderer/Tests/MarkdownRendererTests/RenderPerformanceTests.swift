import XCTest
@testable import MarkdownRenderer

/// Wall-clock benchmarks over a note-sized fixture: 150 sections, each with three
/// inline equations and one display block (600 equations), every third section
/// carrying a Swift code block. Cold renders vary the TeX per iteration so every
/// equation misses the cache, like a freshly opened document; the warm render
/// repeats one fixture, like a live reload.
final class RenderPerformanceTests: XCTestCase {
    private static let sectionCount = 150
    private static let equationCount = sectionCount * 4

    private static func fixture(seed: Int) -> String {
        var sections: [String] = []
        sections.reserveCapacity(sectionCount)
        for index in 1...sectionCount {
            var section = """
            ## Section \(index)

            Consider $a_{\(index)} + b_{\(seed)}$ together with $\\frac{\(index)}{\(seed) + 1}$ and \
            $\\sqrt{\(index) x_{\(seed)}}$ as the running example for this section.

            $$
            \\int_0^{\(index)} f_{\(seed)}(t)\\,dt = \\sum_{k=1}^{\(index)} c_k^{(\(seed))}
            $$

            """
            if index % 3 == 0 {
                section += """
                ```swift
                func compute\(index)(_ x: Double) -> Double {
                    let scale = \(index).0 * \(seed).0
                    return x * scale + \(index)
                }
                ```

                """
            }
            sections.append(section)
        }
        return "# Benchmark \(seed)\n\n" + sections.joined(separator: "\n")
    }

    private func render(_ markdown: String) throws -> String {
        try MarkdownRenderer().renderDocument(markdown: markdown).bodyHTML
    }

    private func timed(_ label: String, _ body: () throws -> String) rethrows -> String {
        let callsBefore = JSEngine.shared.bridgeCallCount
        let start = Date()
        let html = try body()
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "%@: %.1f ms, %d bridge calls, %d bytes of HTML",
                     label, elapsed * 1000, JSEngine.shared.bridgeCallCount - callsBefore, html.utf8.count))
        return html
    }

    func testFixtureShape() {
        let markdown = Self.fixture(seed: 0)
        print("fixture: \(markdown.utf8.count) bytes, \(Self.sectionCount) sections, \(Self.equationCount) equations")
        XCTAssertEqual(markdown.components(separatedBy: "\n## ").count - 1, Self.sectionCount)
        XCTAssertEqual(markdown.components(separatedBy: "```swift").count - 1, Self.sectionCount / 3)
        XCTAssertLessThan(markdown.utf8.count, MarkdownRenderer.expensivePassByteLimit)
    }

    func testColdThenWarmRenderTiming() throws {
        let markdown = Self.fixture(seed: 999_999)
        let cold = try timed("cold render", { try render(markdown) })
        let warm = try timed("warm render", { try render(markdown) })
        XCTAssertEqual(cold.components(separatedBy: "class=\"katex\"").count - 1, Self.equationCount, "all equations should render")
        XCTAssertEqual(cold, warm, "warm render must reproduce the cold output exactly")
    }

    func testColdRenderPerformance() {
        var iteration = 0
        measure {
            iteration += 1
            do {
                _ = try timed("cold iteration \(iteration)", { try render(Self.fixture(seed: iteration)) })
            } catch {
                XCTFail("render failed: \(error)")
            }
        }
    }

    func testWarmRenderPerformance() throws {
        let markdown = Self.fixture(seed: 0)
        _ = try timed("warm-up render", { try render(markdown) })
        var iteration = 0
        measure {
            iteration += 1
            do {
                _ = try timed("warm iteration \(iteration)", { try render(markdown) })
            } catch {
                XCTFail("render failed: \(error)")
            }
        }
    }
}
