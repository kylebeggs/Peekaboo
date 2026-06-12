import Foundation

/// Resolves an Obsidian wikilink target to a file on disk. The vault root is
/// the nearest ancestor directory containing `.obsidian`; targets match on
/// trailing path (`[[Note]]` or `[[folder/Note]]`), case-insensitively, the
/// way Obsidian resolves links anywhere in the vault. First match wins.
enum WikiLinkResolver {
    static func resolve(target: String, from documentURL: URL) -> URL? {
        var relative = target
        if (relative as NSString).pathExtension.isEmpty { relative += ".md" }
        let suffix = "/" + relative.lowercased()

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultRoot(for: documentURL),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let candidate as URL in enumerator {
            guard (try? candidate.resourceValues(forKeys: Set(keys)))?.isRegularFile == true,
                  candidate.path.lowercased().hasSuffix(suffix) else { continue }
            return candidate
        }
        return nil
    }

    static func vaultRoot(for documentURL: URL) -> URL {
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
