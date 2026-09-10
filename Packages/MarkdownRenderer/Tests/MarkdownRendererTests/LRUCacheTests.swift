import XCTest
@testable import MarkdownRenderer

final class LRUCacheTests: XCTestCase {
    private func describe(_ cache: LRUCache<String, String>, _ label: String) {
        print("LRU \(label): \(cache.count) entries, \(cache.totalBytes) bytes (limits \(cache.entryLimit) entries / \(cache.byteLimit) bytes)")
    }

    func testEvictsLeastRecentlyUsedOverEntryLimit() {
        let cache = LRUCache<String, String>(entryLimit: 2, byteLimit: 1_000)
        cache.insert("A", forKey: "a", cost: 1)
        cache.insert("B", forKey: "b", cost: 1)
        cache.insert("C", forKey: "c", cost: 1)
        describe(cache, "after three inserts with entry limit 2")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(forKey: "a"), "oldest entry should be evicted")
        XCTAssertEqual(cache.value(forKey: "b"), "B")
        XCTAssertEqual(cache.value(forKey: "c"), "C")
    }

    func testEvictsUntilUnderByteLimit() {
        let cache = LRUCache<String, String>(entryLimit: 100, byteLimit: 10)
        cache.insert("A", forKey: "a", cost: 4)
        cache.insert("B", forKey: "b", cost: 4)
        XCTAssertEqual(cache.totalBytes, 8)
        cache.insert("C", forKey: "c", cost: 4)
        describe(cache, "after inserting 12 bytes with byte limit 10")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalBytes, 8)
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertEqual(cache.value(forKey: "c"), "C")

        // A single large insert must push out as many entries as it takes.
        cache.insert("D", forKey: "d", cost: 9)
        describe(cache, "after a 9-byte insert")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalBytes, 9)
        XCTAssertEqual(cache.value(forKey: "d"), "D")
    }

    func testReadRefreshesRecency() {
        let cache = LRUCache<String, String>(entryLimit: 2, byteLimit: 1_000)
        cache.insert("A", forKey: "a", cost: 1)
        cache.insert("B", forKey: "b", cost: 1)
        XCTAssertEqual(cache.value(forKey: "a"), "A", "touch `a` so `b` becomes the oldest")
        cache.insert("C", forKey: "c", cost: 1)
        describe(cache, "after touching a then inserting c")
        XCTAssertEqual(cache.value(forKey: "a"), "A", "recently read entry must survive")
        XCTAssertNil(cache.value(forKey: "b"), "untouched entry should be the one evicted")
    }

    func testReinsertingKeyReplacesValueAndCost() {
        let cache = LRUCache<String, String>(entryLimit: 10, byteLimit: 1_000)
        cache.insert("A", forKey: "a", cost: 5)
        cache.insert("A2", forKey: "a", cost: 7)
        describe(cache, "after reinserting the same key")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalBytes, 7, "cost must be replaced, not accumulated")
        XCTAssertEqual(cache.value(forKey: "a"), "A2")
    }

    func testValueLargerThanByteLimitIsNotCached() {
        let cache = LRUCache<String, String>(entryLimit: 10, byteLimit: 10)
        cache.insert("A", forKey: "a", cost: 1)
        cache.insert("HUGE", forKey: "huge", cost: 11)
        describe(cache, "after an insert larger than the byte limit")
        XCTAssertNil(cache.value(forKey: "huge"))
        XCTAssertEqual(cache.value(forKey: "a"), "A", "an uncacheable insert must not evict others")
        XCTAssertEqual(cache.totalBytes, 1)
    }

    func testSingleEntryListSurvivesRemovalAndReinsert() {
        let cache = LRUCache<String, String>(entryLimit: 1, byteLimit: 1_000)
        cache.insert("A", forKey: "a", cost: 1)
        cache.insert("B", forKey: "b", cost: 1)
        cache.insert("C", forKey: "c", cost: 1)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(forKey: "c"), "C")
        XCTAssertNil(cache.value(forKey: "a"))
        XCTAssertNil(cache.value(forKey: "b"))
    }
}
