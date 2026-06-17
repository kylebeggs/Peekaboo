import Foundation

public struct RenderOptions {
    public var baseURL: URL?
    public var title: String = "Markdown"
    public var allowMathJaxFallback: Bool = true
    public var pageZoom: Double = 1.0

    public init() {}
}

public enum RenderError: Error, LocalizedError {
    case parserCreationFailed
    case missingExtension(String)
    case parseFailed
    case renderFailed
    case missingResource(String)
    case javascript(String)

    public var errorDescription: String? {
        switch self {
        case .parserCreationFailed: return "Could not create the markdown parser."
        case .missingExtension(let name): return "Missing cmark-gfm extension: \(name)."
        case .parseFailed: return "Could not parse the markdown document."
        case .renderFailed: return "Could not render the markdown document to HTML."
        case .missingResource(let name): return "Missing bundled resource: \(name)."
        case .javascript(let message): return "JavaScript error: \(message)."
        }
    }
}

public struct RenderedDocument {
    public let bodyHTML: String
    public let css: String
    public let title: String

    public var html: String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <style id="peekaboo-style">
        \(css)
        </style>
        </head>
        <body class="markdown-body">
        \(bodyHTML)
        </body>
        </html>
        """
    }
}

public struct MarkdownRenderer {
    /// Above this size, math and syntax highlighting are skipped to keep renders
    /// fast and within the Quick Look extension memory budget.
    public static let expensivePassByteLimit = 2 * 1024 * 1024

    public init() {}

    public func renderDocument(markdown: String, options: RenderOptions = RenderOptions()) throws -> RenderedDocument {
        var source = markdown
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }

        var frontMatterHTML = ""
        if let frontMatter = FrontMatterPass.split(source: source) {
            frontMatterHTML = frontMatter.html
            source = frontMatter.remainder
        }

        let oversized = source.utf8.count > Self.expensivePassByteLimit
        let math = MathRegistry()
        let extracted = oversized ? source : MathExtractor.extract(from: source, into: math)
        var body = try CMarkPipeline.render(markdown: extracted, math: math, highlightCode: !oversized)
        if oversized {
            body = "<p class=\"peekaboo-notice\">Large document — math and syntax highlighting disabled.</p>\n" + body
        }
        let hasMath = !math.isEmpty
        if hasMath {
            body = MathRenderer.substitute(registry: math, in: body, allowMathJaxFallback: options.allowMathJaxFallback)
        }
        body = frontMatterHTML + body
        body = HeadingIDs.addAnchors(to: body)
        // After HeadingIDs so [[#Heading]] anchors resolve against the generated
        // slugs, before ImageInliner so ![[image]] embeds get inlined.
        body = WikiLinksPass.transform(html: body)
        if let baseURL = options.baseURL {
            body = ImageInliner.inline(html: body, baseURL: baseURL)
        }
        var css = HTMLTemplate.css(includeMath: hasMath)
        if options.pageZoom != 1 {
            css += "\nbody { zoom: \(options.pageZoom); }"
        }
        return RenderedDocument(bodyHTML: body, css: css, title: options.title)
    }

    public func renderHTML(markdown: String, options: RenderOptions = RenderOptions()) throws -> String {
        try renderDocument(markdown: markdown, options: options).html
    }

    /// Renders the contents of a file, routing by extension: recognized source-code
    /// types are syntax-highlighted; markdown and unrecognized types render as markdown.
    public func renderDocument(fileContents: String, pathExtension: String, options: RenderOptions = RenderOptions()) throws -> RenderedDocument {
        guard let language = CodeLanguage.highlightLanguage(forPathExtension: pathExtension) else {
            return try renderDocument(markdown: fileContents, options: options)
        }
        return try renderDocument(sourceCode: fileContents, language: language, options: options)
    }

    /// Wraps `sourceCode` in a fenced code block tagged `language` and renders it
    /// through the markdown pipeline. The fence is longer than any backtick run in
    /// the source so an embedded ``` cannot close the block early.
    public func renderDocument(sourceCode: String, language: String, options: RenderOptions = RenderOptions()) throws -> RenderedDocument {
        let fence = String(repeating: "`", count: max(3, longestBacktickRun(in: sourceCode) + 1))
        return try renderDocument(markdown: "\(fence)\(language)\n\(sourceCode)\n\(fence)\n", options: options)
    }

    private func longestBacktickRun(in text: String) -> Int {
        var longest = 0, current = 0
        for character in text {
            if character == "`" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

func escapeHTML(_ string: String) -> String {
    string
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
