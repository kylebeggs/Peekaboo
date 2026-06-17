import XCTest
@testable import MarkdownRenderer

final class ReviewFileTests: XCTestCase {
    /// Parsing the serialization of any model must reproduce that model exactly.
    private func assertRoundTrips(_ file: ReviewFile, file testFile: StaticString = #filePath, line: UInt = #line) {
        let text = file.serialize()
        let reparsed = ReviewFile.parse(text)
        XCTAssertEqual(reparsed, file, "round-trip mismatch.\n--- serialized ---\n\(text)\n--- reparsed ---\n\(reparsed)", file: testFile, line: line)
    }

    // MARK: - Round-trips

    func testInlineAndGeneralRoundTrip() {
        let file = ReviewFile(documentName: "draft.md", threads: [
            CommentThread(
                id: "a1b2c3", kind: .inline, status: .open,
                anchor: CommentAnchor(quote: "the exact selected text", prefix: "before ", suffix: " after"),
                messages: [CommentMessage(speaker: "You", timestamp: "2026-06-17 14:30", body: "Too vague — add an example.")]),
            CommentThread(
                id: "d4e5f6", kind: .general, status: .resolved,
                messages: [CommentMessage(speaker: "You", timestamp: "2026-06-17 14:40", body: "Intro is too long overall.")]),
        ])
        assertRoundTrips(file)
    }

    func testMultiMessageThreadRoundTrip() {
        let file = ReviewFile(documentName: "notes.md", threads: [
            CommentThread(
                id: "x1", kind: .inline,
                anchor: CommentAnchor(quote: "claim", prefix: "the ", suffix: " here"),
                messages: [
                    CommentMessage(speaker: "You", timestamp: "2026-06-17 09:00", body: "Citation?"),
                    CommentMessage(speaker: "You", timestamp: "2026-06-17 09:05", body: "Also tighten this."),
                    CommentMessage(speaker: "Claude", timestamp: "2026-06-17 09:10", body: "Added a citation and trimmed it."),
                ]),
        ])
        assertRoundTrips(file)
    }

    func testQuoteWithTrickyCharactersRoundTrips() {
        // Quote spanning blank lines and containing a leading '>' and quotes.
        let quote = "first line\n\n> nested looking\nhe said \"hi\""
        let file = ReviewFile(documentName: "a.b.md", threads: [
            CommentThread(
                id: "q1", kind: .inline,
                anchor: CommentAnchor(quote: quote, prefix: "x \"y\"", suffix: "line1\nline2"),
                messages: [CommentMessage(speaker: "You", timestamp: "2026-06-17 12:00", body: "note")]),
        ])
        assertRoundTrips(file)
    }

    func testBodyWithInternalBlankLinesPreserved() {
        let body = "Paragraph one.\n\nParagraph two with a list:\n- a\n- b"
        let file = ReviewFile(documentName: "d.md", threads: [
            CommentThread(
                id: "b1", kind: .general,
                messages: [CommentMessage(speaker: "You", timestamp: "2026-06-17 15:00", body: body)]),
        ])
        assertRoundTrips(file)
    }

    func testEmptyFileRoundTrips() {
        assertRoundTrips(ReviewFile(documentName: "empty.md"))
    }

    // MARK: - Parsing real text

    func testParsesHandWrittenSidecar() {
        let text = """
        # Review · draft.md

        <!-- peekaboo-review v1 -->

        ## inline · open · #a1b2c3
        > the quoted text
        <!-- pkb
        prefix: "lead "
        suffix: " tail"
        -->
        **You** · 2026-06-17 14:30
        Please clarify.

        ## general · resolved · #zz
        **Claude** · 2026-06-17 16:00
        Done.
        """
        let parsed = ReviewFile.parse(text)
        XCTAssertEqual(parsed.documentName, "draft.md")
        XCTAssertEqual(parsed.threads.count, 2)

        let inline = parsed.threads[0]
        XCTAssertEqual(inline.kind, .inline)
        XCTAssertEqual(inline.status, .open)
        XCTAssertEqual(inline.id, "a1b2c3")
        XCTAssertEqual(inline.anchor?.quote, "the quoted text")
        XCTAssertEqual(inline.anchor?.prefix, "lead ")
        XCTAssertEqual(inline.anchor?.suffix, " tail")
        XCTAssertEqual(inline.messages, [CommentMessage(speaker: "You", timestamp: "2026-06-17 14:30", body: "Please clarify.")])

        let general = parsed.threads[1]
        XCTAssertEqual(general.kind, .general)
        XCTAssertEqual(general.status, .resolved)
        XCTAssertNil(general.anchor)
        XCTAssertEqual(general.messages, [CommentMessage(speaker: "Claude", timestamp: "2026-06-17 16:00", body: "Done.")])
    }

    /// A bold run in a body must not be misread as a new message header — only
    /// `**name** · <iso-date>` starts a message.
    func testBoldInBodyIsNotAMessageHeader() {
        let text = """
        # Review · d.md

        <!-- peekaboo-review v1 -->

        ## general · open · #m1
        **You** · 2026-06-17 14:30
        See **Section** · the appendix for details.
        Second line.
        """
        let parsed = ReviewFile.parse(text)
        XCTAssertEqual(parsed.threads.count, 1)
        XCTAssertEqual(parsed.threads[0].messages.count, 1)
        XCTAssertEqual(parsed.threads[0].messages[0].body, "See **Section** · the appendix for details.\nSecond line.")
    }

    // MARK: - Sidecar path mapping

    func testSidecarURLMapping() {
        XCTAssertEqual(
            ReviewFile.sidecarURL(forDocument: URL(fileURLWithPath: "/tmp/draft.md")).lastPathComponent,
            ".draft.review.md")
        XCTAssertEqual(
            ReviewFile.sidecarURL(forDocument: URL(fileURLWithPath: "/tmp/a.b.md")).lastPathComponent,
            ".a.b.review.md")
        XCTAssertEqual(
            ReviewFile.sidecarURL(forDocument: URL(fileURLWithPath: "/tmp/.secret.md")).lastPathComponent,
            ".secret.review.md")
        XCTAssertTrue(ReviewFile.isSidecar(URL(fileURLWithPath: "/tmp/.draft.review.md")))
        XCTAssertFalse(ReviewFile.isSidecar(URL(fileURLWithPath: "/tmp/draft.md")))
    }
}
