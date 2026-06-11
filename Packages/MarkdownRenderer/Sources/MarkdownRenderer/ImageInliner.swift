import Foundation

/// Rewrites local-path `<img src>` references into base64 data URIs so the
/// rendered document is fully self-contained (WKWebView with a nil base URL and
/// Quick Look both refuse to load external local files).
enum ImageInliner {
    static let maxBytes = 10 * 1024 * 1024

    private static let pattern = try! NSRegularExpression(pattern: "<img\\b[^>]*?\\bsrc=\"([^\"]+)\"")

    private static let mimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic", "avif": "image/avif",
        "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff",
    ]

    static func inline(html: String, baseURL: URL) -> String {
        let ns = html as NSString
        let matches = pattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return html }

        var result = html
        for match in matches.reversed() {
            let srcRange = match.range(at: 1)
            let src = ns.substring(with: srcRange)
            guard !src.contains("://"), !src.hasPrefix("data:"), !src.hasPrefix("//") else { continue }
            let decoded = src.removingPercentEncoding ?? src
            let fileURL = URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
            guard let mime = mimeTypes[fileURL.pathExtension.lowercased()],
                  let data = try? Data(contentsOf: fileURL),
                  data.count <= maxBytes else { continue }
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            if let range = Range(srcRange, in: result) {
                result.replaceSubrange(range, with: uri)
            }
        }
        return result
    }
}
