import SwiftUI
import MarkdownRenderer

struct DocumentView: View {
    let initialText: String
    let fileURL: URL?

    @State private var document: RenderedDocument?
    @State private var renderError: String?
    @State private var watcher: FileWatcher?
    @AppStorage("pageZoom") private var pageZoom = 1.0

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
            } else {
                WebView(document: document, fileURL: fileURL)
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .toolbar {
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
        }
        .task {
            await render(markdown: initialText)
            startWatching()
        }
    }

    private func render(markdown: String) async {
        let url = fileURL
        let result = await Task.detached(priority: .userInitiated) { () -> Result<RenderedDocument, Error> in
            var options = RenderOptions()
            options.baseURL = url?.deletingLastPathComponent()
            options.title = url?.lastPathComponent ?? "Markdown"
            do {
                return .success(try MarkdownRenderer().renderDocument(markdown: markdown, options: options))
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

    private func startWatching() {
        guard watcher == nil, let url = fileURL else { return }
        watcher = FileWatcher(url: url) {
            guard let data = try? Data(contentsOf: url) else { return }
            let markdown = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            Task { await render(markdown: markdown) }
        }
    }
}
