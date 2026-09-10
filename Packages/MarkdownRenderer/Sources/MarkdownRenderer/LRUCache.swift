import Foundation

/// Least-recently-used cache bounded both by entry count and by the caller-supplied
/// byte cost of its contents. Not thread-safe: the owner serialises access.
final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        // `older` links run from the head down to the tail and own the chain;
        // `newer` is weak so the list never forms a retain cycle.
        var older: Node?
        weak var newer: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    let entryLimit: Int
    let byteLimit: Int
    private(set) var totalBytes = 0

    private var nodes: [Key: Node] = [:]
    private var head: Node?  // most recently used
    private var tail: Node?  // least recently used

    init(entryLimit: Int, byteLimit: Int) {
        self.entryLimit = entryLimit
        self.byteLimit = byteLimit
    }

    var count: Int { nodes.count }

    /// Returns the cached value and marks the entry as most recently used.
    func value(forKey key: Key) -> Value? {
        guard let node = nodes[key] else { return nil }
        unlink(node)
        pushFront(node)
        return node.value
    }

    /// Stores `value` as the most recently used entry, replacing any existing entry
    /// for `key`, then evicts from the least recently used end until both limits hold.
    /// A single value larger than the byte limit is never cached.
    func insert(_ value: Value, forKey key: Key, cost: Int) {
        if let existing = nodes[key] { remove(existing) }
        guard cost <= byteLimit else { return }
        let node = Node(key: key, value: value, cost: cost)
        nodes[key] = node
        totalBytes += cost
        pushFront(node)
        while let oldest = tail, nodes.count > entryLimit || totalBytes > byteLimit {
            remove(oldest)
        }
    }

    // MARK: - Linked list

    private func remove(_ node: Node) {
        unlink(node)
        nodes[node.key] = nil
        totalBytes -= node.cost
    }

    private func unlink(_ node: Node) {
        let newer = node.newer
        let older = node.older
        newer?.older = older
        older?.newer = newer
        if head === node { head = older }
        if tail === node { tail = newer }
        node.newer = nil
        node.older = nil
    }

    private func pushFront(_ node: Node) {
        node.older = head
        head?.newer = node
        head = node
        if tail == nil { tail = node }
    }
}
