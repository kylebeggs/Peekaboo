import SwiftUI
import MarkdownRenderer

private let minSidebarWidth = 260.0
private let dividerWidth = 1.0

struct DocumentView: View {
    let initialText: String
    let fileURL: URL?

    @StateObject private var store: CommentStore
    @State private var document: RenderedDocument?
    @State private var renderError: String?
    @State private var watcher: FileWatcher?
    @State private var window: NSWindow?
    @AppStorage("pageZoom") private var pageZoom = 1.0
    @AppStorage("showCommentsPanel") private var showComments = false
    @AppStorage("commentsTextPaneWidth") private var textPaneWidth = 900.0
    @AppStorage("commentsSidebarWidth") private var sidebarWidth = 400.0

    init(initialText: String, fileURL: URL?) {
        self.initialText = initialText
        self.fileURL = fileURL
        _store = StateObject(wrappedValue: CommentStore(documentURL: fileURL))
    }

    private var commentsEnabled: Bool { store.sidecarURL != nil }

    var body: some View {
        Group {
            if let renderError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(renderError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if commentsEnabled && showComments {
                HStack(spacing: 0) {
                    WebView(document: document, fileURL: fileURL, store: store)
                        .frame(width: textPaneWidth)
                    Divider()
                    CommentsSidebar(store: store)
                        .frame(minWidth: minSidebarWidth)
                }
            } else {
                WebView(document: document, fileURL: fileURL, store: store)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
            if let fileURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show in Finder")
            }
            Button {
                pageZoom = Zoom.zoomedOut(pageZoom)
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom Out")
            Button {
                pageZoom = Zoom.zoomedIn(pageZoom)
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom In")
            if commentsEnabled {
                Button {
                    showComments.toggle()
                } label: {
                    Label("Comments", systemImage: "text.bubble")
                }
                .help(showComments ? "Hide comments" : "Show comments")
            }
        }
        .background(WindowAccessor { resolved in
            window = resolved
            if let resolved, showComments { fitWindowToComments(resolved) }
        })
        .onChange(of: showComments) { applyCommentsLayout(show: $0) }
        .onChange(of: store.pending) { pending in
            if pending != nil { showComments = true }
        }
        .onChange(of: store.selectedThreadID) { id in
            if id != nil { showComments = true }
        }
        .task {
            await render(text: initialText)
            startWatching()
        }
    }

    private func render(text: String) async {
        let url = fileURL
        let result = await Task.detached(priority: .userInitiated) { () -> Result<RenderedDocument, Error> in
            var options = RenderOptions()
            options.baseURL = url?.deletingLastPathComponent()
            options.title = url?.lastPathComponent ?? "Markdown"
            do {
                return .success(try MarkdownRenderer().renderDocument(
                    fileContents: text,
                    pathExtension: url?.pathExtension ?? "",
                    options: options))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let rendered):
            document = rendered
            renderError = nil
        case .failure(let error):
            renderError = error.localizedDescription
        }
    }

    private func applyCommentsLayout(show: Bool) {
        guard let window else { return }
        var frame = window.frame
        if show {
            textPaneWidth = frame.width
            frame.size.width = textPaneWidth + dividerWidth + sidebarWidth
        } else {
            sidebarWidth = max(minSidebarWidth, frame.width - dividerWidth - textPaneWidth)
            frame.size.width = textPaneWidth
        }
        constrainToScreen(&frame, in: window)
        window.setFrame(frame, display: true, animate: false)
    }

    // On reopen, a window restored too narrow for the pinned text width clips the WebView.
    // Grow it to fit; leave already-wide windows alone so a manual resize survives.
    private func fitWindowToComments(_ window: NSWindow) {
        guard window.frame.width < textPaneWidth + dividerWidth + minSidebarWidth else { return }
        var frame = window.frame
        frame.size.width = textPaneWidth + dividerWidth + sidebarWidth
        constrainToScreen(&frame, in: window)
        window.setFrame(frame, display: true)
    }

    private func constrainToScreen(_ frame: inout NSRect, in window: NSWindow) {
        if let visible = window.screen?.visibleFrame, frame.maxX > visible.maxX {
            frame.origin.x = max(visible.minX, visible.maxX - frame.size.width)
        }
    }

    private func startWatching() {
        guard watcher == nil, let url = fileURL else { return }
        watcher = FileWatcher(url: url) {
            guard let data = try? Data(contentsOf: url) else { return }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            Task { await render(text: text) }
        }
    }
}
