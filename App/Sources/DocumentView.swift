import SwiftUI
import MarkdownRenderer

let minSidebarWidth = 260.0
private let minTextPaneWidth = 400.0
// The divider is a real 6pt strip, not a 1pt rule with an overlay: SwiftUI overlay
// hit-testing across the NSViewRepresentable-hosted WKWebView is unreliable, so the
// drag target has to own actual layout width.
private let dividerWidth = 6.0
private let defaultSidebarWidth = 410.0
private let defaultDocumentWidth = 920.0
// AppKit restores the previous document window's frame and ignores the scene's
// `defaultSize`, so this is only the width of the very first window ever opened;
// `fitWindowToComments` re-grows a restored frame that is too narrow for the panes.
let defaultWindowWidth = defaultDocumentWidth + dividerWidth + defaultSidebarWidth
// The drag must be measured against a frame that does not itself move with the drag.
// A .local DragGesture on the divider oscillates: changing the split moves the divider,
// which moves the gesture's own reference frame, which changes the next translation.
private let splitSpace = "peekaboo.split"

struct DocumentView: View {
    let initialText: String
    let fileURL: URL?

    @StateObject private var store: CommentStore
    @State private var document: RenderedDocument?
    @State private var isEditing = false
    // Per window, and deliberately not persisted: a document opened fresh starts at the
    // fixed-width column, and widening one window doesn't reflow every other one.
    @State private var fullWidth = false
    @State private var sourceText: String
    // The last content this window put on disk (or adopted from it). The watcher drops
    // events whose disk content matches — the echo of our own atomic save — and never
    // overwrites the buffer while it is dirty (sourceText != savedText).
    @State private var savedText: String
    @State private var autosaveWork: DispatchWorkItem?
    @State private var renderError: String?
    @State private var watcher: FileWatcher?
    @State private var window: NSWindow?
    @State private var dragStartDocWidth: Double?
    // Held in @State during a drag so the split isn't written through UserDefaults on
    // every frame; committed to `sidebarWidth` on release.
    @State private var liveSidebarWidth: Double?
    @State private var isHoveringDivider = false
    @AppStorage("pageZoom") private var pageZoom = 1.0
    @AppStorage("showCommentsPanel") private var showComments = false
    // The comments pane keeps an absolute width, so a wider window widens the document
    // and leaves the sidebar alone. `textPaneWidth` is the last known absolute document
    // width, used only by the show/hide window math and the too-narrow-on-reopen fixup.
    @AppStorage("commentsPaneWidth") private var sidebarWidth = defaultSidebarWidth
    @AppStorage("commentsTextPaneWidth") private var textPaneWidth = defaultDocumentWidth

    init(initialText: String, fileURL: URL?) {
        self.initialText = initialText
        self.fileURL = fileURL
        _sourceText = State(initialValue: initialText)
        _savedText = State(initialValue: initialText)
        _store = StateObject(wrappedValue: CommentStore(documentURL: fileURL))
    }

    private var commentsEnabled: Bool { store.sidecarURL != nil }

    // The web view stays mounted beneath the editor: destroying it on a mode switch would
    // reload the page, losing scroll position and the pushed comment anchors.
    @ViewBuilder
    private var contentView: some View {
        ZStack {
            WebView(
                document: document, fileURL: fileURL,
                fullWidth: fullWidth, store: store)
            if isEditing {
                MarkdownTextEditor(
                    text: $sourceText, fontSize: 13 * pageZoom, onEdit: scheduleAutosave)
            }
        }
    }

    var body: some View {
        Group {
            // A render error must never replace the editor — it's the tool for fixing the text.
            if let renderError, !isEditing {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(renderError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding()
            } else if commentsEnabled && showComments {
                GeometryReader { geo in
                    let available = geo.size.width - dividerWidth
                    HStack(spacing: 0) {
                        contentView
                            .frame(width: documentWidth(in: available))
                        splitDivider(available: available)
                        CommentsSidebar(store: store)
                            .frame(minWidth: minSidebarWidth)
                    }
                    .coordinateSpace(name: splitSpace)
                }
            } else {
                contentView
            }
        }
        // A GeometryReader has no intrinsic minimum, so the floor the fixed-width WebView
        // used to propagate up through the HStack has to be stated explicitly.
        .frame(minWidth: commentsEnabled && showComments ? minSplitWidth : 480, minHeight: 320)
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
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sourceText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy markdown source")
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
            Picker("View Mode", selection: $isEditing) {
                Label("Rendered", systemImage: "doc.richtext").tag(false)
                Label("Edit", systemImage: "square.and.pencil").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(fileURL == nil)
            .help("Switch between rendered view and editing")
            Picker("Content Width", selection: $fullWidth) {
                Label("Fixed", systemImage: "arrow.right.and.line.vertical.and.arrow.left").tag(false)
                Label("Full", systemImage: "arrow.left.and.line.vertical.and.arrow.right").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Switch between a fixed-width column and text that fills the window")
            if commentsEnabled {
                Button {
                    showComments.toggle()
                } label: {
                    Label("Comments", systemImage: "text.bubble")
                }
                .help(showComments ? "Hide comments" : "Show comments")
            }
        }
        // Hands the key window's width toggle and save action to the app-level menus.
        .focusedSceneValue(\.fullWidth, $fullWidth)
        .focusedSceneValue(\.saveDocument, SaveDocumentAction { flushAutosave() })
        .background(WindowAccessor { resolved in
            window = resolved
            if let resolved, showComments { fitWindowToComments(resolved) }
        })
        .onChange(of: isEditing) { editing in
            if !editing { flushAutosave() }
        }
        .onDisappear { flushAutosave() }
        // onDisappear is not guaranteed on ⌘Q. willTerminate is delivered synchronously
        // and the save is a synchronous write, so it completes before the process exits.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.willTerminateNotification)) { _ in flushAutosave() }
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

    private var minSplitWidth: Double { minTextPaneWidth + dividerWidth + minSidebarWidth }

    /// The document pane's width for a given content width, clamped so neither pane can
    /// be crushed past its minimum. Rounded to whole points — a fractional width makes
    /// the WebView relayout on subpixel changes, which reads as jitter while dragging.
    private func documentWidth(in available: Double) -> Double {
        let ceiling = max(minTextPaneWidth, available - minSidebarWidth)
        return min(max(available - (liveSidebarWidth ?? sidebarWidth), minTextPaneWidth), ceiling)
            .rounded()
    }

    /// A 1pt separator centred in a 6pt drag strip. Drag moves the split, double-click
    /// resets it; `minimumDistance: 1` lets the tap through.
    private func splitDivider(available: Double) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: dividerWidth)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != isHoveringDivider else { return }
                isHoveringDivider = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(splitSpace))
                    .onChanged { value in
                        let start = dragStartDocWidth ?? documentWidth(in: available)
                        if dragStartDocWidth == nil { dragStartDocWidth = start }
                        let ceiling = max(minTextPaneWidth, available - minSidebarWidth)
                        let target = min(max(start + value.translation.width, minTextPaneWidth), ceiling)
                        liveSidebarWidth = available - target
                    }
                    .onEnded { _ in
                        dragStartDocWidth = nil
                        if let liveSidebarWidth { sidebarWidth = liveSidebarWidth }
                        liveSidebarWidth = nil
                        textPaneWidth = documentWidth(in: available)
                    })
            .onTapGesture(count: 2) {
                sidebarWidth = defaultSidebarWidth
                textPaneWidth = documentWidth(in: available)
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

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        let work = DispatchWorkItem { performSave() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func flushAutosave() {
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
        Task { await render(text: text) }
    }

    // Grow/shrink the window so the document pane keeps its width across a toggle. The two
    // branches are exact inverses, so hiding and re-showing lands on the same split.
    private func applyCommentsLayout(show: Bool) {
        guard let window else { return }
        var frame = window.frame
        if show {
            textPaneWidth = frame.width
            frame.size.width = max(minSplitWidth, windowWidth(forDocumentWidth: frame.width))
        } else {
            textPaneWidth = max(minTextPaneWidth, frame.width - dividerWidth - sidebarWidth)
            frame.size.width = textPaneWidth
        }
        constrainToScreen(&frame, in: window)
        window.setFrame(frame, display: true, animate: false)
    }

    // On reopen, a window restored too narrow for the remembered text width squeezes the
    // WebView. Grow it to fit; leave already-wide windows alone so a manual resize survives.
    private func fitWindowToComments(_ window: NSWindow) {
        guard window.frame.width < textPaneWidth + dividerWidth + minSidebarWidth else { return }
        var frame = window.frame
        frame.size.width = max(minSplitWidth, windowWidth(forDocumentWidth: textPaneWidth))
        constrainToScreen(&frame, in: window)
        window.setFrame(frame, display: true)
    }

    private func windowWidth(forDocumentWidth width: Double) -> Double {
        width + dividerWidth + sidebarWidth
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
            // Echo of our own save.
            guard text != savedText else { return }
            // Dirty buffer wins: un-flushed keystrokes are never clobbered by an external
            // write — the next autosave overwrites it instead.
            guard sourceText == savedText else { return }
            savedText = text
            sourceText = text
            Task { await render(text: text) }
        }
    }
}
