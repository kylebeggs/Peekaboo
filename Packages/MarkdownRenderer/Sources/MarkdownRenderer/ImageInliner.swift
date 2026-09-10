import Foundation

/// Rewrites local-path `<img src>` references into base64 data URIs so the
/// rendered document is fully self-contained (WKWebView with a nil base URL and
/// Quick Look both refuse to load external local files).
///
/// Encoded URIs are cached process-wide, keyed by path plus size and modification
/// date: a note with a few screenshots would otherwise re-read and re-encode
/// megabytes on every live reload. The size check runs on file metadata before
/// anything is read.
enum ImageInliner {
    static let maxBytes = 10 * 1024 * 1024

    private static let pattern = try! NSRegularExpression(pattern: "<img\\b[^>]*?\\bsrc=\"([^\"]+)\"")

    private static let mimeTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic", "avif": "image/avif",
        "bmp": "image/bmp", "tiff": "image/tiff", "tif": "image/tiff",
    ]

    /// Cost is the encoded byte count; NSCache also sheds entries under memory pressure,
    /// which matters inside the Quick Look extension.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    static func inline(html: String, baseURL: URL) -> String {
        var resolved: [String: String] = [:]
        // The match covers the whole `<img ... src="..."` prefix; only the src value changes.
        return RegexSplicer.replacingMatches(of: pattern, in: html) { match, ns in
            let srcRange = match.range(at: 1)
            let src = ns.substring(with: srcRange)
            guard !src.contains("://"), !src.hasPrefix("data:"), !src.hasPrefix("//") else { return nil }
            let uri: String
            if let seen = resolved[src] {
                uri = seen
            } else {
                guard let encoded = dataURI(for: src, baseURL: baseURL) else { return nil }
                resolved[src] = encoded
                uri = encoded
            }
            let head = ns.substring(with: NSRange(location: match.range.location, length: srcRange.location - match.range.location))
            let tail = ns.substring(with: NSRange(location: NSMaxRange(srcRange), length: NSMaxRange(match.range) - NSMaxRange(srcRange)))
            return head + uri + tail
        }
    }

    private static func dataURI(for src: String, baseURL: URL) -> String? {
        let decoded = src.removingPercentEncoding ?? src
        let fileURL = URL(fileURLWithPath: decoded, relativeTo: baseURL).standardizedFileURL
        guard let mime = mimeTypes[fileURL.pathExtension.lowercased()],
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size <= maxBytes else { return nil }
        let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(fileURL.path)|\(size)|\(modified)" as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        cache.setObject(uri as NSString, forKey: key, cost: uri.utf8.count)
        return uri
    }
}
