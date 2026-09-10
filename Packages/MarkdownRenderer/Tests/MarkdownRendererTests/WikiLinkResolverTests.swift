import XCTest
@testable import MarkdownRenderer

/// Wikilink resolution against a real vault on disk. Every click used to walk the
/// whole vault, so the index is cached; the cache has to stay honest about files
/// added or deleted underneath it.
final class WikiLinkResolverTests: XCTestCase {
    private var vault: URL!
    private var resolver: WikiLinkResolver!

    override func setUpWithError() throws {
        vault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peekaboo-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true
        )
        try write("Home.md")
        try write("Notes/Deep Note.md")
        try write("Notes/Archive/Old Note.md")
        resolver = WikiLinkResolver()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vault)
    }

    @discardableResult
    private func write(_ relativePath: String, contents: String = "# note\n") throws -> URL {
        let url = vault.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func resolve(_ target: String, from relativePath: String = "Home.md") -> URL? {
        resolver.resolve(target: target, from: vault.appendingPathComponent(relativePath))
    }

    // MARK: - Resolution

    func testResolvesANoteAnywhereInTheVault() {
        XCTAssertEqual(resolve("Deep Note")?.lastPathComponent, "Deep Note.md")
    }

    func testResolvesAFolderQualifiedTarget() {
        XCTAssertEqual(resolve("Archive/Old Note")?.lastPathComponent, "Old Note.md")
    }

    func testMatchesCaseInsensitively() {
        XCTAssertEqual(resolve("deep note")?.lastPathComponent, "Deep Note.md")
    }

    func testAnExplicitExtensionIsHonoured() {
        XCTAssertEqual(resolve("Deep Note.md")?.lastPathComponent, "Deep Note.md")
    }

    func testUnknownTargetResolvesToNil() {
        XCTAssertNil(resolve("No Such Note"))
    }

    func testVaultRootIsTheNearestObsidianAncestor() {
        let root = WikiLinkResolver.vaultRoot(for: vault.appendingPathComponent("Notes/Deep Note.md"))
        XCTAssertEqual(root.standardizedFileURL.path, vault.standardizedFileURL.path)
    }

    // MARK: - Index cache

    func testRepeatedResolutionDoesNotRescanTheVault() {
        XCTAssertNotNil(resolve("Deep Note"))
        let scans = resolver.scanCount
        XCTAssertNotNil(resolve("Deep Note"))
        XCTAssertNotNil(resolve("Old Note"))
        print("wikilink scans: \(scans) for the first click, \(resolver.scanCount) after three")
        XCTAssertEqual(resolver.scanCount, scans, "later clicks must be served from the cached index")
    }

    func testNoteAddedAfterTheFirstResolutionIsStillFound() throws {
        XCTAssertNotNil(resolve("Deep Note"))
        try write("Notes/Fresh Note.md")
        XCTAssertEqual(resolve("Fresh Note")?.lastPathComponent, "Fresh Note.md", "a miss must rescan the vault")
    }

    func testDeletedNoteIsNotResolvedFromTheCache() throws {
        let target = try write("Notes/Doomed Note.md")
        XCTAssertNotNil(resolve("Doomed Note"))
        try FileManager.default.removeItem(at: target)
        XCTAssertNil(resolve("Doomed Note"), "a cached hit that no longer exists must not be returned")
    }

    func testEachVaultKeepsItsOwnIndex() throws {
        let other = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("peekaboo-vault-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: other.appendingPathComponent(".obsidian", isDirectory: true), withIntermediateDirectories: true
        )
        try "# other\n".write(to: other.appendingPathComponent("Other Note.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: other) }

        XCTAssertNotNil(resolve("Deep Note"))
        XCTAssertNil(resolve("Other Note"), "the first vault does not contain the second vault's note")
        XCTAssertEqual(
            resolver.resolve(target: "Other Note", from: other.appendingPathComponent("Other Note.md"))?
                .lastPathComponent,
            "Other Note.md"
        )
    }
}
