import Foundation
import JavaScriptCore

enum KaTeXFailure: Error {
    case parse(String)
    case other(String)
}

/// One process-wide JSContext confined to a serial queue. Scripts load lazily:
/// highlight.js on the first fenced code block, KaTeX on the first math segment.
final class JSEngine {
    static let shared = JSEngine()

    private let queue = DispatchQueue(label: "com.kylebeggs.peekaboo.jsengine")
    private var context: JSContext?
    private var katexReady = false
    private var hljsReady = false

    private init() {}

    func highlight(code: String, language: String) -> String? {
        queue.sync {
            guard let ctx = ensureHLJS() else { return nil }
            guard let fn = ctx.objectForKeyedSubscript("__peekabooHighlight"), !fn.isUndefined else { return nil }
            let result = fn.call(withArguments: [code, language])
            guard let result, result.isString else { return nil }
            return result.toString()
        }
    }

    func renderKaTeX(tex: String, display: Bool) -> Result<String, KaTeXFailure> {
        queue.sync {
            guard let ctx = ensureKaTeX() else {
                return .failure(.other("KaTeX failed to load"))
            }
            guard let fn = ctx.objectForKeyedSubscript("__peekabooKatex"), !fn.isUndefined,
                  let result = fn.call(withArguments: [tex, display]), result.isObject else {
                return .failure(.other("KaTeX bridge call failed"))
            }
            if result.objectForKeyedSubscript("ok")?.toBool() == true,
               let html = result.objectForKeyedSubscript("html")?.toString() {
                return .success(html)
            }
            let message = result.objectForKeyedSubscript("message")?.toString() ?? "unknown KaTeX error"
            let isParse = result.objectForKeyedSubscript("parse")?.toBool() ?? false
            return isParse ? .failure(.parse(message)) : .failure(.other(message))
        }
    }

    // MARK: - Lazy setup (all on `queue`)

    private func ensureContext() -> JSContext? {
        if let context { return context }
        guard let ctx = JSContext() else { return nil }
        ctx.evaluateScript("if (typeof globalThis === 'undefined') { var globalThis = this; }")
        context = ctx
        return ctx
    }

    private func ensureKaTeX() -> JSContext? {
        guard let ctx = ensureContext() else { return nil }
        if katexReady { return ctx }
        guard load(resource: "katex.min", ext: "js", subdirectory: "Resources/katex", into: ctx) else { return nil }
        ctx.evaluateScript("""
        function __peekabooKatex(tex, display) {
            try {
                return { ok: true, html: katex.renderToString(tex, {
                    displayMode: display, throwOnError: true, strict: 'ignore', output: 'html'
                }) };
            } catch (e) {
                return { ok: false, parse: e instanceof katex.ParseError, message: String(e) };
            }
        }
        """)
        katexReady = true
        return ctx
    }

    private func ensureHLJS() -> JSContext? {
        guard let ctx = ensureContext() else { return nil }
        if hljsReady { return ctx }
        guard load(resource: "highlight.min", ext: "js", subdirectory: "Resources/highlight", into: ctx) else { return nil }
        ctx.evaluateScript("""
        function __peekabooHighlight(code, lang) {
            try {
                if (!hljs.getLanguage(lang)) { return null; }
                return hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
            } catch (e) {
                return null;
            }
        }
        """)
        hljsReady = true
        return ctx
    }

    private func load(resource: String, ext: String, subdirectory: String, into ctx: JSContext) -> Bool {
        guard let url = Bundle.module.url(forResource: resource, withExtension: ext, subdirectory: subdirectory),
              let script = try? String(contentsOf: url, encoding: .utf8) else { return false }
        ctx.evaluateScript(script, withSourceURL: url)
        return ctx.exception == nil
    }
}
