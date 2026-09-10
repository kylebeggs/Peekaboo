import Foundation

/// Resolves an Obsidian wikilink target to a file on disk. The vault root is
/// the nearest ancestor directory containing `.obsidian`; targets match on
/// trailing path (`[[Note]]` or `[[folder/Note]]`), case-insensitively, the
/// way Obsidian resolves links anywhere in the vault. First match wins.
public final class WikiLinkResolver {
    public static let shared = WikiLinkResolver()
    static let defaultVaultLimit = 4
    static let defaultByteLimit = 4 * 1024 * 1024

    private struct Entry {
        let url: URL
        let lowercasedPath: String
    }

    private let queue = DispatchQueue(label: "com.kylebeggs.peekaboo.wikilinks")
    private let indexes: LRUCache<String, [Entry]>
    private var scans = 0

    init(vaultLimit: Int = WikiLinkResolver.defaultVaultLimit,
         byteLimit: Int = WikiLinkResolver.defaultByteLimit) {
        indexes = LRUCache(entryLimit: vaultLimit, byteLimit: byteLimit)
    }

    /// Number of vault walks performed.
    var scanCount: Int { queue.sync { scans } }

    public func resolve(target: String, from documentURL: URL) -> URL? {
        queue.sync { () -> URL? in
            var relative = target
            if (relative as NSString).pathExtension.isEmpty { relative += ".md" }
            let suffix = "/" + relative.lowercased()
            let root = WikiLinkResolver.vaultRoot(for: documentURL)

            // A cached index goes stale only in ways the next lookup catches: a hit
            // whose file is gone, or a miss for a note added since the walk. Both
            // rescan, so the index needs no invalidation of its own.
            if let cached = indexes.value(forKey: root.path),
               let hit = match(suffix, in: cached),
               FileManager.default.fileExists(atPath: hit.path) {
                return hit
            }
            let fresh = scan(root: root)
            indexes.insert(fresh, forKey: root.path, cost: fresh.reduce(0) { $0 + $1.lowercasedPath.utf8.count })
            return match(suffix, in: fresh)
        }
    }

    private func match(_ suffix: String, in index: [Entry]) -> URL? {
        index.first { $0.lowercasedPath.hasSuffix(suffix) }?.url
    }

    /// Runs on `queue`.
    private func scan(root: URL) -> [Entry] {
        scans += 1
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [Entry] = []
        for case let candidate as URL in enumerator {
            guard (try? candidate.resourceValues(forKeys: Set(keys)))?.isRegularFile == true else { continue }
            files.append(Entry(url: candidate, lowercasedPath: candidate.path.lowercased()))
        }
        return files
    }

    public static func vaultRoot(for documentURL: URL) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var directory = documentURL.deletingLastPathComponent().standardizedFileURL
        while true {
            var isDirectory: ObjCBool = false
            let marker = directory.appendingPathComponent(".obsidian", isDirectory: true)
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
            }
            let parent = directory.deletingLastPathComponent()
            if directory.path == home || parent.path == directory.path {
                return documentURL.deletingLastPathComponent()
            }
            directory = parent
        }
    }
}
