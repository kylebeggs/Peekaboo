import Foundation
import MarkdownRenderer

/// A comment awaiting its first message: inline if it has an `anchor`, otherwise
/// document-level.
struct PendingComment: Equatable {
    var anchor: CommentAnchor?
}

/// Owns the comment threads for one window and persists them to its review file: the
/// `.<doc>.review.md` sidecar (a hidden dot-file) for a document, or
/// `<repo>/.peekaboo/review.md` for a repo diff review. The same file is human- and
/// agent-readable, so it doubles as the artifact handed to Claude. It is watched so
/// replies an agent appends show up live.
final class CommentStore: ObservableObject {
    @Published private(set) var threads: [CommentThread] = []
    @Published var pending: PendingComment?
    @Published var selectedThreadID: String?
    @Published private(set) var outdatedIDs: Set<String> = []
    /// Inline thread id → its position in the rendered document, reported by the web
    /// view; drives top-to-bottom ordering of inline threads in the sidebar.
    @Published private(set) var inlineDocumentOrder: [String: Int] = [:]

    /// Set by the web view; scrolls the rendered document to a thread's highlight.
    var scrollHandler: ((String) -> Void)?

    /// Speaker stamped on messages the user writes; only these are editable.
    static let localSpeaker = "You"

    let sidecarURL: URL?
    let renderCache: CommentRenderCache
    /// True for a repo diff review, whose inline anchors are line-located.
    let isDiffReview: Bool
    private let documentName: String
    /// What a diff review is against; written into the file's header for the agent.
    private var diffContext: DiffContext?
    private var watcher: FileWatcher?
    private var lastWrittenText: String?

    init(documentURL: URL?) {
        renderCache = CommentRenderCache(baseURL: documentURL?.deletingLastPathComponent())
        if let url = documentURL, !ReviewFile.isSidecar(url) {
            sidecarURL = ReviewFile.sidecarURL(forDocument: url)
            documentName = url.lastPathComponent
        } else {
            sidecarURL = nil
            documentName = documentURL?.lastPathComponent ?? "Document"
        }
        isDiffReview = false
        loadFromDisk()
        ensureWatching()
    }

    /// A store for a repo diff review. Unlike a document sidecar, the file is created
    /// straight away: an agent then always has a file to answer in, and the watcher has
    /// something to watch from the start (a file created later would go unnoticed).
    init(repoRoot: URL) {
        renderCache = CommentRenderCache(baseURL: repoRoot)
        sidecarURL = ReviewFile.repoReviewURL(forRepo: repoRoot)
        documentName = repoRoot.lastPathComponent
        isDiffReview = true
        if let url = sidecarURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        loadFromDisk()
        if let url = sidecarURL, !FileManager.default.fileExists(atPath: url.path) { save() }
        ensureWatching()
    }

    /// Records what the review is currently diffed against, rewriting the file only
    /// when that actually changed (every write invalidates an agent's last read of it).
    func setDiffContext(_ context: DiffContext) {
        guard context != diffContext else { return }
        reloadFromDisk()
        diffContext = context
        save()
    }

    var inlineThreads: [CommentThread] {
        threads.filter { $0.kind == .inline }
    }

    // MARK: - Mutations

    func beginInlineComment(_ anchor: CommentAnchor) {
        pending = PendingComment(anchor: anchor)
    }

    func beginGeneralComment() {
        pending = PendingComment(anchor: nil)
    }

    func cancelPending() {
        pending = nil
    }

    func commitPending(_ body: String) {
        guard let pending else { return }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reloadFromDisk()
        let thread = CommentThread(
            id: newID(),
            kind: pending.anchor == nil ? .general : .inline,
            anchor: pending.anchor,
            messages: [message(trimmed)])
        threads.append(thread)
        self.pending = nil
        selectedThreadID = thread.id
        save()
    }

    func addReply(to threadID: String, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        reloadFromDisk()
        guard !trimmed.isEmpty, let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].messages.append(message(trimmed))
        save()
    }

    func setStatus(_ status: CommentStatus, for threadID: String) {
        reloadFromDisk()
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].status = status
        save()
    }

    func delete(_ threadID: String) {
        reloadFromDisk()
        threads.removeAll { $0.id == threadID }
        if selectedThreadID == threadID { selectedThreadID = nil }
        save()
    }

    func editMessage(in threadID: String, at index: Int, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        reloadFromDisk()
        guard !trimmed.isEmpty,
              let ti = threads.firstIndex(where: { $0.id == threadID }),
              threads[ti].messages.indices.contains(index),
              threads[ti].messages[index].speaker == Self.localSpeaker else { return }
        threads[ti].messages[index].body = trimmed
        save()
    }

    // MARK: - Web-view callbacks

    /// Called after every body swap; assigns only on change so an unchanged reload does
    /// not republish and rebuild every card in the sidebar.
    func setOutdated(_ ids: [String], order: [String]) {
        let outdated = Set(ids)
        if outdated != outdatedIDs { outdatedIDs = outdated }
        let documentOrder = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        if documentOrder != inlineDocumentOrder { inlineDocumentOrder = documentOrder }
    }

    func selectThread(_ id: String) {
        selectedThreadID = id
    }

    /// Scrolls the rendered document to a thread's highlight (no-op until the web
    /// view installs ``scrollHandler``).
    func scrollTo(_ id: String) {
        scrollHandler?(id)
    }

    // MARK: - Persistence

    // Every mutation above calls `reloadFromDisk()` first. `save()` rewrites the whole
    // file from memory, and the watcher that would have told us about an agent's edit
    // is debounced: without the reload, a reply sent in that window silently erases
    // whatever the agent had just written.
    private func save() {
        guard let url = sidecarURL else { return }
        let text = ReviewFile(documentName: documentName, diff: diffContext, threads: threads).serialize()
        lastWrittenText = text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // A failed write leaves in-memory state intact; surfacing it via the
            // sidebar is out of scope, but we must not crash the viewer.
            lastWrittenText = nil
            return
        }
        ensureWatching()
    }

    private func loadFromDisk() {
        guard let url = sidecarURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        lastWrittenText = text
        let file = ReviewFile.parse(text)
        threads = file.threads
        diffContext = file.diff
    }

    private func reloadFromDisk() {
        guard let url = sidecarURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        guard text != lastWrittenText else { return }
        lastWrittenText = text
        threads = ReviewFile.parse(text).threads
    }

    private func ensureWatching() {
        guard watcher == nil, let url = sidecarURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        watcher = FileWatcher(url: url) { [weak self] in self?.reloadFromDisk() }
    }

    // MARK: - Helpers

    private func message(_ body: String) -> CommentMessage {
        CommentMessage(speaker: Self.localSpeaker, timestamp: Self.timestampFormatter.string(from: Date()), body: body)
    }

    private func newID() -> String {
        var id = String(UUID().uuidString.prefix(6)).lowercased()
        while threads.contains(where: { $0.id == id }) {
            id = String(UUID().uuidString.prefix(6)).lowercased()
        }
        return id
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
