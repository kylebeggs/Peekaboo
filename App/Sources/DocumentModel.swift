import AppKit
import Combine
import MarkdownRenderer

/// Owns one open document: its edit buffer, disk sync (autosave and live reload), and
/// rendering. A reference type held as `@StateObject`, not view state: the watcher and
/// render callbacks capture it weakly, so a closed window releases everything with it.
/// (A `FileWatcher` closure that captured the `DocumentView` struct held its `@State`
/// boxes, which held the watcher — a cycle that kept closed documents watching,
/// re-rendering, and pinning their window.)
@MainActor
final class DocumentModel: ObservableObject {
    @Published var sourceText: String
    @Published private(set) var document: RenderedDocument?
    @Published private(set) var renderError: String?
    /// The last content this document put on disk (or adopted from it). The watcher drops
    /// events whose disk content matches — the echo of our own atomic save — and never
    /// overwrites the buffer while it is dirty (sourceText != savedText).
    private(set) var savedText: String

    let fileURL: URL?
    private let renderer = RenderCoordinator()
    private var watcher: FileWatcher?
    private var autosaveWork: DispatchWorkItem?

    init(initialText: String, fileURL: URL?) {
        sourceText = initialText
        savedText = initialText
        self.fileURL = fileURL
    }

    deinit {
        watcher?.stop()
        autosaveWork?.cancel()
    }

    /// First render plus the live-reload watcher. Idempotent.
    func start() {
        render(sourceText)
        startWatching()
    }

    // MARK: - Saving

    func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performSave() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func flushAutosave() {
        autosaveWork?.cancel()
        autosaveWork = nil
        performSave()
    }

    // Synchronous and on main by design: the watcher callback also runs on main, so at
    // callback time the disk always reflects the last completed write and a single
    // savedText comparison is race-free. An off-main write would reintroduce the
    // interleaving where our own save looks like an external change.
    private func performSave() {
        guard let url = fileURL, sourceText != savedText else { return }
        let text = sourceText
        let previous = savedText
        savedText = text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // Buffer stays dirty so the next autosave retries.
            savedText = previous
            NSSound.beep()
            return
        }
        // The watcher drops the echo of this write, so the rendered view updates here.
        render(text)
    }

    // MARK: - Live reload

    private func startWatching() {
        guard watcher == nil, let url = fileURL else { return }
        watcher = FileWatcher(url: url) { [weak self] in self?.fileDidChange(at: url) }
    }

    private func fileDidChange(at url: URL) {
        // Dirty buffer wins: un-flushed keystrokes are never clobbered by an external
        // write — the next autosave overwrites it instead. Checked before reading so a
        // dirty buffer costs no I/O at all.
        guard sourceText == savedText else { return }
        // The read runs off main: the file may live in iCloud Drive and be evicted, and a
        // download must not block input. `expected` pins the disk state this event was
        // about; if a save lands while the read is in flight, the result is stale and is
        // dropped (the save's own render already showed the newer text).
        let expected = savedText
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let data = try? Data(contentsOf: url) else { return }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.savedText == expected, self.sourceText == self.savedText else { return }
                // Echo of our own save.
                guard text != self.savedText else { return }
                self.savedText = text
                self.sourceText = text
                self.render(text)
            }
        }
    }

    // MARK: - Rendering

    private func render(_ text: String) {
        renderer.render(text: text, fileURL: fileURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rendered):
                self.document = rendered
                self.renderError = nil
            case .failure(let error):
                self.renderError = error.localizedDescription
            }
        }
    }
}

/// Serialises renders for one document with latest-wins coalescing: at most one render
/// runs at a time, and a request arriving while one is in flight replaces any earlier
/// waiting request rather than queueing behind it. Work runs on a dedicated queue rather
/// than a detached `Task`, so a slow render (KaTeX, 1s+ on math-heavy notes) never parks a
/// cooperative-pool thread — with several windows reloading at once that starved every
/// other `await` in the app.
@MainActor
final class RenderCoordinator {
    typealias Completion = (Result<RenderedDocument, Error>) -> Void

    /// Shared across documents: renders already serialise on `JSEngine`'s queue, so
    /// parallel queues would only add blocked threads.
    private static let queue = DispatchQueue(label: "com.kylebeggs.peekaboo.render", qos: .userInitiated)

    private struct Request {
        let text: String
        let fileURL: URL?
        let completion: Completion
    }

    private var inFlight = false
    private var pending: Request?

    func render(text: String, fileURL: URL?, completion: @escaping Completion) {
        let request = Request(text: text, fileURL: fileURL, completion: completion)
        guard !inFlight else {
            pending = request
            return
        }
        start(request)
    }

    private func start(_ request: Request) {
        inFlight = true
        Self.queue.async {
            // Foundation and JavaScriptCore temporaries (regex matches, substrings, every
            // JSValue) are autoreleased; measured at ~10 MB per render of a math-heavy
            // note, and a dispatch worker only drains them once it goes idle.
            let result = autoreleasepool { Self.perform(request) }
            DispatchQueue.main.async { [weak self] in
                request.completion(result)
                guard let self else { return }
                self.inFlight = false
                if let next = self.pending {
                    self.pending = nil
                    self.start(next)
                }
            }
        }
    }

    private nonisolated static func perform(_ request: Request) -> Result<RenderedDocument, Error> {
        var options = RenderOptions()
        options.baseURL = request.fileURL?.deletingLastPathComponent()
        options.title = request.fileURL?.lastPathComponent ?? "Markdown"
        do {
            return .success(try MarkdownRenderer().renderDocument(
                fileContents: request.text,
                pathExtension: request.fileURL?.pathExtension ?? "",
                options: options))
        } catch {
            return .failure(error)
        }
    }
}
