import XCTest
@testable import MarkdownRenderer

final class CommentOrderingTests: XCTestCase {
    private func thread(
        _ id: String,
        _ kind: CommentKind,
        _ status: CommentStatus = .open,
        ts: String = "2026-06-17 10:00"
    ) -> CommentThread {
        CommentThread(
            id: id,
            kind: kind,
            status: status,
            anchor: kind == .inline ? CommentAnchor(quote: id) : nil,
            messages: [CommentMessage(speaker: "You", timestamp: ts, body: "body")])
    }

    private func ids(_ threads: [CommentThread]) -> [String] { threads.map(\.id) }

    func testGeneralSortedChronologically() {
        let threads = [
            thread("g1", .general, ts: "2026-06-17 10:30"),
            thread("g2", .general, ts: "2026-06-17 09:00"),
            thread("g3", .general, ts: "2026-06-17 10:00"),
        ]
        let result = CommentOrdering.grouped(threads, documentOrder: [:])
        XCTAssertEqual(ids(result.general), ["g2", "g3", "g1"])
        XCTAssertTrue(result.inline.isEmpty)
    }

    func testInlineSortedByDocumentPosition() {
        let threads = [thread("i1", .inline), thread("i2", .inline), thread("i3", .inline)]
        let order = ["i3": 0, "i1": 1, "i2": 2]
        let result = CommentOrdering.grouped(threads, documentOrder: order)
        XCTAssertEqual(ids(result.inline), ["i3", "i1", "i2"])
        XCTAssertTrue(result.general.isEmpty)
    }

    func testResolvedSinkWithinEachGroup() {
        let threads = [
            thread("g1", .general, .open, ts: "2026-06-17 10:00"),
            thread("g2", .general, .resolved, ts: "2026-06-17 09:00"),
            thread("g3", .general, .open, ts: "2026-06-17 11:00"),
            thread("i1", .inline, .open),
            thread("i2", .inline, .resolved),
        ]
        // i2 has the lower document position but is resolved, so it still sinks.
        let order = ["i1": 1, "i2": 0]
        let result = CommentOrdering.grouped(threads, documentOrder: order)
        XCTAssertEqual(ids(result.general), ["g1", "g3", "g2"])
        XCTAssertEqual(ids(result.inline), ["i1", "i2"])
    }

    func testUnpositionedInlineFallsToBottomOfOpenGroup() {
        let threads = [thread("i1", .inline), thread("i2", .inline), thread("i3", .inline)]
        let order = ["i1": 0, "i3": 1] // i2 has no reported position
        let result = CommentOrdering.grouped(threads, documentOrder: order)
        XCTAssertEqual(ids(result.inline), ["i1", "i3", "i2"])
    }

    func testTiesPreserveOriginalOrder() {
        let threads = [
            thread("gA", .general, ts: "2026-06-17 10:00"),
            thread("gB", .general, ts: "2026-06-17 10:00"),
            thread("gC", .general, ts: "2026-06-17 10:00"),
            thread("i1", .inline),
            thread("i2", .inline),
        ]
        let result = CommentOrdering.grouped(threads, documentOrder: [:])
        XCTAssertEqual(ids(result.general), ["gA", "gB", "gC"])
        XCTAssertEqual(ids(result.inline), ["i1", "i2"])
    }
}
