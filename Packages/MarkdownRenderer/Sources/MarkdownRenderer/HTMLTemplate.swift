import Foundation

/// Assembles the document stylesheet from bundled CSS. All pieces respect
/// `prefers-color-scheme`, so light/dark follows the system automatically.
/// KaTeX CSS (with fonts inlined as data URIs) is included only when the
/// document actually contains math.
enum HTMLTemplate {
    static func css(includeMath: Bool) -> String {
        var combined = baseCSS
        if includeMath { combined += "\n" + katexCSS }
        return combined
    }

    private static let baseCSS: String = {
        var css = layoutCSS
        css += load("github-markdown", ext: "css", subdirectory: "Resources/css") ?? ""
        if let light = load("github.min", ext: "css", subdirectory: "Resources/highlight") {
            css += "\n@media (prefers-color-scheme: light) {\n\(light)\n}"
        }
        if let dark = load("github-dark.min", ext: "css", subdirectory: "Resources/highlight") {
            css += "\n@media (prefers-color-scheme: dark) {\n\(dark)\n}"
        }
        css += alertCSS
        return css
    }()

    /// KaTeX stylesheet with woff2 fonts rewritten to data URIs (woff/ttf
    /// fallback sources dropped). Computed once per process.
    private static let katexCSS: String = {
        guard var css = load("katex.min", ext: "css", subdirectory: "Resources/katex") else { return "" }
        let pattern = try! NSRegularExpression(
            pattern: "url\\(fonts/([A-Za-z0-9_-]+)\\.woff2\\) format\\(\"woff2\"\\)[^;}]*"
        )
        let ns = css as NSString
        let matches = pattern.matches(in: css, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let fontName = ns.substring(with: match.range(at: 1))
            guard let fontURL = Bundle.module.url(
                      forResource: fontName, withExtension: "woff2", subdirectory: "Resources/katex/fonts"),
                  let data = try? Data(contentsOf: fontURL),
                  let range = Range(match.range, in: css) else { continue }
            css.replaceSubrange(
                range,
                with: "url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            )
        }
        return css
    }()

    private static func load(_ name: String, ext: String, subdirectory: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static let layoutCSS = """
    body { margin: 0; background-color: #ffffff; }
    @media (prefers-color-scheme: dark) { body { background-color: #0d1117; } }
    .markdown-body { box-sizing: border-box; min-width: 200px; max-width: 980px; margin: 0 auto; padding: 32px; }
    .peekaboo-notice { padding: 8px 16px; border-radius: 6px; background-color: #fff8c5; color: #57606a; }
    @media (prefers-color-scheme: dark) { .peekaboo-notice { background-color: #3a2d12; color: #8b949e; } }
    .math-error { color: #cf222e; }
    @media (prefers-color-scheme: dark) { .math-error { color: #f85149; } }
    .katex-display { overflow-x: auto; overflow-y: hidden; padding: 2px 0; }
    .math-display-svg { text-align: center; margin: 16px 0; }
    .mermaid { text-align: center; }
    table.frontmatter th { text-align: left; }

    """

    private static let alertCSS = """

    .markdown-alert { padding: 8px 16px; margin-bottom: 16px; border-left: 4px solid; border-radius: 0; }
    .markdown-alert > :last-child { margin-bottom: 0; }
    .markdown-alert .markdown-alert-title { display: flex; align-items: center; gap: 8px; font-weight: 500; line-height: 1; margin-bottom: 8px; }
    .markdown-alert .markdown-alert-title svg { fill: currentColor; }
    .markdown-alert-note { border-left-color: #0969da; }
    .markdown-alert-note .markdown-alert-title { color: #0969da; }
    .markdown-alert-tip { border-left-color: #1a7f37; }
    .markdown-alert-tip .markdown-alert-title { color: #1a7f37; }
    .markdown-alert-important { border-left-color: #8250df; }
    .markdown-alert-important .markdown-alert-title { color: #8250df; }
    .markdown-alert-warning { border-left-color: #9a6700; }
    .markdown-alert-warning .markdown-alert-title { color: #9a6700; }
    .markdown-alert-caution { border-left-color: #cf222e; }
    .markdown-alert-caution .markdown-alert-title { color: #cf222e; }
    @media (prefers-color-scheme: dark) {
      .markdown-alert-note { border-left-color: #1f6feb; }
      .markdown-alert-note .markdown-alert-title { color: #4493f8; }
      .markdown-alert-tip { border-left-color: #238636; }
      .markdown-alert-tip .markdown-alert-title { color: #3fb950; }
      .markdown-alert-important { border-left-color: #8957e5; }
      .markdown-alert-important .markdown-alert-title { color: #ab7df8; }
      .markdown-alert-warning { border-left-color: #9e6a03; }
      .markdown-alert-warning .markdown-alert-title { color: #d29922; }
      .markdown-alert-caution { border-left-color: #da3633; }
      .markdown-alert-caution .markdown-alert-title { color: #f85149; }
    }

    """
}
