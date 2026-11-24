import CoreServices
import Foundation

/// Watches a whole working tree for file changes via FSEvents (recursive, unlike the
/// single-file `FileWatcher`). The callback runs on main, coalesced by the stream's
/// own latency, and only for changes outside `.git/` and `.peekaboo/`:
///
/// - `.git/` churns on every git command, including the ones a refresh runs itself,
///   and nothing in there changes what "base versus working tree" looks like.
/// - `.peekaboo/` holds the review's own files, which have their own watcher.
final class RepoWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let ignored: [String]

    init(root: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // FSEvents reports resolved paths, so compare against the resolved root.
        let base = root.resolvingSymlinksInPath().path
        ignored = [base + "/.git/", base + "/.peekaboo/"]

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] else { return }
            let watcher = Unmanaged<RepoWatcher>.fromOpaque(info).takeUnretainedValue()
            if paths.prefix(count).contains(where: watcher.isRelevant) { watcher.onChange() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [base] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    /// Idempotent. Must run before the watcher is released: the stream holds an
    /// unretained pointer to it.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func isRelevant(_ path: String) -> Bool {
        !ignored.contains { path.hasPrefix($0) || path + "/" == $0 }
    }
}
