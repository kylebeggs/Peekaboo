import AppKit
import Combine
import CryptoKit
import MarkdownRenderer

/// Owns one repo review: runs git, renders the diff, tracks which files are viewed,
/// and keeps comment anchors located as the working tree changes underneath.
///
/// The flow on every refresh: git → parse → per-file bodies (cached by patch) on a
/// background queue, then on main the bodies are wrapped with their Viewed state into
/// a ``Snapshot`` the web view diffs against what it last pushed.
@MainActor
final class ReviewModel: ObservableObject {
    struct RenderedFile: Equatable {
        let id: String
        /// Changes exactly when the file's `<details>` element must be replaced.
        let key: String
        let html: String
    }

    struct Snapshot: Equatable {
        var summary: String
        var files: [RenderedFile]
    }

    /// A commented line range to mark in the page.
    struct Marker: Equatable, Encodable {
        let thread: String
        let file: String
        let side: String
        let start: Int
        let end: Int
        let resolved: Bool
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var markers: [Marker] = []
    @Published private(set) var base: GitRunner.Base?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false

    let root: URL
    let store: CommentStore

    private let requestURL: URL
    private let worker: ReviewWorker
    private var watcher: RepoWatcher?
    private var storeSubscription: AnyCancellable?
    private var started = false
    private var inFlight = false
    private var pending = false

    private var result: ReviewWorker.Output?
    /// Path → the `changeDigest` the file had when it was marked viewed. A file whose
    /// changes have moved on since no longer matches and shows as unviewed again.
    private var viewed: [String: String]
    private var forceLoaded: Set<String> = []

    init(requestURL: URL) {
        self.requestURL = requestURL
        root = ReviewSession.repoRoot(forRequest: requestURL)
        store = CommentStore(repoRoot: root)
        worker = ReviewWorker(root: root, requestURL: requestURL)
        viewed = Self.loadViewed(root)
    }

    deinit {
        watcher?.stop()
    }

    /// First refresh plus the live-refresh watcher. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        watcher = RepoWatcher(root: root) { [weak self] in self?.refresh() }
        // Anchors are re-resolved when threads change (a comment added here, or a
        // reply/resolve written by an agent), not only when the diff does.
        storeSubscription = store.$threads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.resolveAnchors() }
        refresh()
    }

    // MARK: - Refresh

    /// Re-runs git and re-renders whatever changed. Calls made while one is running
    /// collapse into a single follow-up run, so a burst of file events (a build, a
    /// branch switch) costs at most two.
    func refresh() {
        guard !inFlight else {
            pending = true
            return
        }
        inFlight = true
        isRefreshing = true
        let input = ReviewWorker.Input(forceLoaded: forceLoaded, previous: result?.signature)
        worker.run(input) { [weak self] outcome in
            guard let self else { return }
            self.inFlight = false
            self.isRefreshing = false
            switch outcome {
            case .failure(let failure):
                self.error = failure.localizedDescription
            case .success(nil):
                break // nothing changed since the last run
            case .success(let output?):
                self.error = nil
                self.adopt(output)
            }
            if self.pending {
                self.pending = false
                self.refresh()
            }
        }
    }

    private func adopt(_ output: ReviewWorker.Output) {
        result = output
        base = output.base
        store.setDiffContext(DiffContext(repo: root.path, base: output.base.ref, baseSHA: output.base.sha))

        // Drop Viewed marks whose file changed or left the diff.
        let current = Dictionary(output.files.map { ($0.diff.path, $0.changeDigest) }, uniquingKeysWith: { first, _ in first })
        let stillViewed = viewed.filter { current[$0.key] == $0.value }
        if stillViewed != viewed {
            viewed = stillViewed
            saveViewed()
        }
        forceLoaded.formIntersection(current.keys)

        var notices: [String] = []
        if let notice = output.base.notice { notices.append(notice) }
        notices.append(contentsOf: output.notices)
        let previous = Dictionary(uniqueKeysWithValues: (snapshot?.files ?? []).map { ($0.id, $0) })
        snapshot = Snapshot(
            summary: DiffRenderer.summaryHTML(files: output.files.map(\.diff), base: output.base.label, notices: notices),
            files: output.files.map { file in
                let key = self.key(for: file)
                // Reuse the assembled element when nothing about it changed: the
                // strings are large and `==` on the snapshot is how the web view
                // decides what to send.
                if let old = previous[file.id], old.key == key { return old }
                return RenderedFile(id: file.id, key: key, html: DiffRenderer.fileHTML(
                    file.diff, id: file.id, body: file.body, viewed: isViewed(file)))
            })
        resolveAnchors()
    }

    private func isViewed(_ file: ReviewWorker.File) -> Bool {
        viewed[file.diff.path] == file.changeDigest
    }

    private func key(for file: ReviewWorker.File) -> String {
        file.bodyKey + (isViewed(file) ? "|viewed" : "")
    }

    // MARK: - Page actions

    /// The page toggled a file's Viewed checkbox (and has already collapsed or opened
    /// it). Returns the file's new key so the web view can record the element as
    /// current instead of replacing it with an identical one.
    func setViewed(_ viewedNow: Bool, fileID: String) -> String? {
        guard let file = result?.files.first(where: { $0.id == fileID }) else { return nil }
        viewed[file.diff.path] = viewedNow ? file.changeDigest : nil
        saveViewed()
        let key = key(for: file)
        if let index = snapshot?.files.firstIndex(where: { $0.id == fileID }) {
            snapshot?.files[index] = RenderedFile(id: fileID, key: key, html: DiffRenderer.fileHTML(
                file.diff, id: fileID, body: file.body, viewed: viewedNow))
        }
        return key
    }

    /// "Load diff" on a file that was too large to render by default.
    func loadFile(_ fileID: String) {
        guard let file = result?.files.first(where: { $0.id == fileID }) else { return }
        forceLoaded.insert(file.diff.path)
        refresh()
    }

    /// Starts a comment on lines `start...end` of one side of a file.
    func beginComment(fileID: String, side: DiffSide, start: Int, end: Int) {
        guard let file = result?.files.first(where: { $0.id == fileID }),
              let anchor = DiffAnchors.anchor(in: file.diff, side: side, start: start, end: end) else { return }
        store.beginInlineComment(anchor)
    }

    // MARK: - Anchors

    /// Locates every line-anchored thread in the current diff. Threads whose lines are
    /// found get a marker in the page and a position for the sidebar's ordering; the
    /// rest are reported as outdated.
    private func resolveAnchors() {
        guard let files = result?.files else { return }
        let diffs = files.map(\.diff)
        var located: [(marker: Marker, fileIndex: Int)] = []
        var outdated: [String] = []
        for thread in store.inlineThreads {
            guard let anchor = thread.anchor, let found = DiffAnchors.resolve(anchor, in: diffs) else {
                outdated.append(thread.id)
                continue
            }
            located.append((Marker(
                thread: thread.id, file: files[found.fileIndex].id, side: found.side.rawValue,
                start: found.line, end: found.endLine, resolved: thread.status == .resolved), found.fileIndex))
        }
        located.sort { ($0.fileIndex, $0.marker.start) < ($1.fileIndex, $1.marker.start) }
        let newMarkers = located.map(\.marker)
        if newMarkers != markers { markers = newMarkers }
        store.setOutdated(outdated, order: newMarkers.map(\.thread))
    }

    // MARK: - Viewed persistence

    private static func viewedURL(_ root: URL) -> URL {
        root.appendingPathComponent(ReviewSession.directoryName, isDirectory: true)
            .appendingPathComponent("viewed.json")
    }

    private static func loadViewed(_ root: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: viewedURL(root)),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return decoded
    }

    private func saveViewed() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(viewed) else { return }
        try? data.write(to: Self.viewedURL(root), options: .atomic)
    }
}

/// The background half of a refresh. All state here is touched only on `queue`.
final class ReviewWorker {
    struct Input {
        let forceLoaded: Set<String>
        /// Signature of the last adopted output; a run that reproduces it reports "no change".
        let previous: String?
    }

    struct File {
        let id: String
        let diff: FileDiff
        let changeDigest: String
        let body: String
        /// Identifies `body`: the file's patch plus whether it was force-loaded.
        let bodyKey: String
    }

    struct Output {
        let base: GitRunner.Base
        let files: [File]
        let notices: [String]
        let signature: String
    }

    /// Untracked files beyond this many are not listed; a stray build directory that
    /// is not ignored should not turn a review into ten thousand "added" files.
    private static let untrackedLimit = 200
    private static let untrackedByteLimit = 1024 * 1024

    private let queue = DispatchQueue(label: "com.kylebeggs.peekaboo.review", qos: .userInitiated)
    private let git: GitRunner
    private let requestURL: URL
    private let renderer = DiffRenderer()
    private var bodies: [String: (key: String, body: String)] = [:]

    init(root: URL, requestURL: URL) {
        git = GitRunner(root: root)
        self.requestURL = requestURL
    }

    func run(_ input: Input, completion: @escaping @MainActor (Result<Output?, Error>) -> Void) {
        queue.async { [self] in
            let outcome = autoreleasepool { Result { try perform(input) } }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private func perform(_ input: Input) throws -> Output? {
        // Re-read every time: `peekaboo diff <other-base>` rewrites the request file
        // while this window is open, and the next refresh should follow it.
        let requested = ReviewSession.base(from: (try? String(contentsOf: requestURL, encoding: .utf8)) ?? "")
        let base = try git.resolveBase(requested)
        let raw = try git.diff(against: base.sha)

        var notices: [String] = []
        var untracked = try git.untrackedPaths()
        if untracked.count > Self.untrackedLimit {
            notices.append("\(untracked.count - Self.untrackedLimit) more untracked files are not shown.")
            untracked = Array(untracked.prefix(Self.untrackedLimit))
        }
        let untrackedDiffs = untracked.map { path -> FileDiff in
            let url = git.root.appendingPathComponent(path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = size <= Self.untrackedByteLimit ? try? Data(contentsOf: url) : nil
            return UnifiedDiff.untracked(path: path, contents: data)
        }

        var hasher = SHA256()
        hasher.update(data: Data((base.sha + "\n" + raw).utf8))
        for diff in untrackedDiffs { hasher.update(data: Data(diff.digest.utf8)) }
        for path in input.forceLoaded.sorted() { hasher.update(data: Data(("!" + path).utf8)) }
        let signature = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if signature == input.previous { return nil }

        let diffs = (UnifiedDiff.parse(raw) + untrackedDiffs).sorted { $0.path < $1.path }
        var budget = DiffRenderer.highlightBudget
        var seen: [String: Int] = [:]
        var live: Set<String> = []
        let files = diffs.map { diff -> File in
            // The id is the element's DOM id, so it must be stable across refreshes
            // (hence the path, not the position) and unique (a type change yields two
            // blocks for one path).
            var id = "f" + SHA256.hash(data: Data(diff.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            seen[id, default: 0] += 1
            if let count = seen[id], count > 1 { id += "-\(count)" }
            live.insert(id)

            let force = input.forceLoaded.contains(diff.path)
            let bodyKey = diff.digest + (force ? "|loaded" : "")
            let body: String
            if let cached = bodies[id], cached.key == bodyKey {
                body = cached.body
            } else {
                let rendered = render(diff, base: base, force: force, budget: &budget)
                body = rendered.html
                // A body that missed out on highlighting only because this refresh's
                // budget ran out is not cached, so the next refresh tries again.
                bodies[id] = rendered.highlightDeferred ? nil : (bodyKey, body)
            }
            return File(id: id, diff: diff, changeDigest: diff.changeDigest, body: body, bodyKey: bodyKey)
        }
        bodies = bodies.filter { live.contains($0.key) }
        return Output(base: base, files: files, notices: notices, signature: signature)
    }

    private func render(_ diff: FileDiff, base: GitRunner.Base, force: Bool, budget: inout Int) -> DiffRenderer.Body {
        var old: String?
        var new: String?
        if renderer.wantsContents(diff, forceLoad: force) {
            if let path = diff.oldPath, Self.isRegularFile(diff.oldMode) {
                old = git.contents(of: path, at: base.sha)
            }
            if let path = diff.newPath, Self.isRegularFile(diff.newMode) {
                new = try? String(contentsOf: git.root.appendingPathComponent(path), encoding: .utf8)
            }
        }
        return renderer.body(for: diff, old: old, new: new, forceLoad: force, budget: &budget)
    }

    /// Symlinks and submodules have a "content" that is a path or a commit id, not
    /// source to highlight. A nil mode is an untracked file, which is always regular.
    private static func isRegularFile(_ mode: String?) -> Bool {
        mode == nil || mode == "100644" || mode == "100755"
    }
}
