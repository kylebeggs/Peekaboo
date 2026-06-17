import Foundation
import MarkdownRenderer

/// A comment awaiting its first message: inline if it has an `anchor`, otherwise
/// document-level.
struct PendingComment: Equatable {
    var anchor: CommentAnchor?
}

/// Owns the comment threads for one open document and persists them to the
/// `.<doc>.review.md` sidecar (a hidden dot-file). The same file is human- and agent-readable, so it
/// doubles as the artifact handed to Claude. The sidecar is watched so replies
/// an agent appends show up live.
final class CommentStore: ObservableObject {
    @Published private(set) var threads: [CommentThread] = []
    @Published var pending: PendingComment?
    @Published var selectedThreadID: String?
    @Published private(set) var outdatedIDs: Set<String> = []

    /// Set by the web view; scrolls the rendered document to a thread's highlight.
    var scrollHandler: ((String) -> Void)?

    let sidecarURL: URL?
    private let documentName: String
    private var watcher: FileWatcher?
    private var lastWrittenText: String?

    init(documentURL: URL?) {
        if let url = documentURL, !ReviewFile.isSidecar(url) {
            sidecarURL = ReviewFile.sidecarURL(forDocument: url)
            documentName = url.lastPathComponent
        } else {
            sidecarURL = nil
            documentName = documentURL?.lastPathComponent ?? "Document"
        }
        loadFromDisk()
        ensureWatching()
    }

    var openInlineThreads: [CommentThread] {
        threads.filter { $0.kind == .inline && $0.status == .open }
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
        guard !trimmed.isEmpty, let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].messages.append(message(trimmed))
        save()
    }

    func setStatus(_ status: CommentStatus, for threadID: String) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].status = status
        save()
    }

    func delete(_ threadID: String) {
        threads.removeAll { $0.id == threadID }
        if selectedThreadID == threadID { selectedThreadID = nil }
        save()
    }

    // MARK: - Web-view callbacks

    func setOutdated(_ ids: [String]) {
        outdatedIDs = Set(ids)
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

    private func save() {
        guard let url = sidecarURL else { return }
        let text = ReviewFile(documentName: documentName, threads: threads).serialize()
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
        threads = ReviewFile.parse(text).threads
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
        CommentMessage(speaker: "You", timestamp: Self.timestampFormatter.string(from: Date()), body: body)
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
