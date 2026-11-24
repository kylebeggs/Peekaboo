import SwiftUI
import MarkdownRenderer

/// Window content for a repo review: the split diff on the left, the same comments
/// sidebar documents use on the right.
struct ReviewView: View {
    @StateObject private var model: ReviewModel
    @State private var window = WeakWindow()
    @AppStorage("pageZoom") private var pageZoom = 1.0
    @AppStorage("showReviewComments") private var showComments = true

    init(requestURL: URL) {
        _model = StateObject(wrappedValue: ReviewModel(requestURL: requestURL))
    }

    var body: some View {
        HSplitView {
            // The diff takes every spare point: two columns of code need the width far
            // more than a column of comments does.
            content
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            if showComments {
                CommentsSidebar(store: model.store)
                    .frame(minWidth: minSidebarWidth, idealWidth: 360, maxWidth: 460, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .navigationTitle(model.root.lastPathComponent)
        .navigationSubtitle(model.base.map { "against \($0.label)" } ?? "")
        .toolbar {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([model.root])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the repository in Finder")
            Button {
                model.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-run the diff")
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
            Button {
                showComments.toggle()
            } label: {
                Label("Comments", systemImage: "text.bubble")
            }
            .help(showComments ? "Hide comments" : "Show comments")
        }
        .focusedSceneValue(\.refreshReview, RefreshReviewAction { model.refresh() })
        .background(WindowAccessor { window.value = $0 })
        // Coming back to the window is the moment the reader wants current state; it
        // also picks up a base changed by re-running `peekaboo diff <base>`.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let key = note.object as? NSWindow, key === window.value { model.refresh() }
        }
        .onChange(of: model.store.pending) { pending in
            if pending != nil { showComments = true }
        }
        .onChange(of: model.store.selectedThreadID) { id in
            if id != nil { showComments = true }
        }
        .task { model.start() }
    }

    @ViewBuilder private var content: some View {
        // The web view stays mounted once there is something to show: an error from a
        // later refresh (say, mid-rebase) must not throw away the page and its scroll
        // position, so it is laid over the top instead.
        ZStack(alignment: .top) {
            if model.snapshot != nil {
                DiffWebView(model: model)
            } else if model.error == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
            }
        }
    }
}
