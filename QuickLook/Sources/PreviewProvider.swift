import QuickLookUI
import UniformTypeIdentifiers
import MarkdownRenderer

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let data = try Data(contentsOf: request.fileURL)
        let markdown = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)

        var options = RenderOptions()
        options.baseURL = request.fileURL.deletingLastPathComponent()
        options.title = request.fileURL.lastPathComponent
        options.pageZoom = 0.9
        let html = try MarkdownRenderer().renderHTML(markdown: markdown, options: options)

        let reply = QLPreviewReply(
            dataOfContentType: .html,
            contentSize: CGSize(width: 900, height: 800)
        ) { _ in
            Data(html.utf8)
        }
        reply.title = request.fileURL.lastPathComponent
        reply.stringEncoding = .utf8
        return reply
    }
}
