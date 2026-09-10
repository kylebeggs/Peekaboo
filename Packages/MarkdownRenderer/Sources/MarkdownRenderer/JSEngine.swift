import Foundation
import JavaScriptCore

enum KaTeXFailure: Error, Equatable {
    case parse(String)
    case other(String)

    var message: String {
        switch self {
        case .parse(let message), .other(let message): return message
        }
    }
}

/// One process-wide JSContext confined to a serial queue. Scripts load lazily:
/// highlight.js on the first fenced code block, KaTeX on the first math segment.
///
/// Bridge results are memoised in a byte-bounded LRU because a live reload
/// re-renders the whole document and each KaTeX call costs ~2 ms. Failures are
/// cached too: for a given input the bridge is deterministic.
final class JSEngine {
    static let shared = JSEngine()
    static let defaultCacheEntryLimit = 4000
    static let defaultCacheByteLimit = 8 * 1024 * 1024

    struct CacheStatistics {
        let entries: Int
        let bytes: Int
    }

    private enum CacheKey: Hashable {
        case katex(tex: String, display: Bool)
        case highlight(code: String, language: String)

        var inputBytes: Int {
            switch self {
            case .katex(let tex, _): return tex.utf8.count
            case .highlight(let code, _): return code.utf8.count
            }
        }
    }

    private enum CacheEntry {
        case katex(Result<String, KaTeXFailure>)
        case highlight(String?)

        var outputBytes: Int {
            switch self {
            case .katex(.success(let html)): return html.utf8.count
            case .katex(.failure(let failure)): return failure.message.utf8.count
            case .highlight(let html): return html?.utf8.count ?? 0
            }
        }
    }

    private let queue = DispatchQueue(label: "com.kylebeggs.peekaboo.jsengine")
    private let cache: LRUCache<CacheKey, CacheEntry>
    private var context: JSContext?
    private var katexReady = false
    private var hljsReady = false
    private var bridgeCalls = 0

    init(cacheEntryLimit: Int = JSEngine.defaultCacheEntryLimit,
         cacheByteLimit: Int = JSEngine.defaultCacheByteLimit) {
        cache = LRUCache(entryLimit: cacheEntryLimit, byteLimit: cacheByteLimit)
    }

    /// Number of calls that reached JavaScript, i.e. cache misses.
    var bridgeCallCount: Int { queue.sync { bridgeCalls } }

    var cacheStatistics: CacheStatistics {
        queue.sync { CacheStatistics(entries: cache.count, bytes: cache.totalBytes) }
    }

    func highlight(code: String, language: String) -> String? {
        queue.sync { () -> String? in
            let key = CacheKey.highlight(code: code, language: language)
            if case .highlight(let cached)? = cache.value(forKey: key) { return cached }
            let highlighted = autoreleasepool { callHighlight(code: code, language: language) }
            let entry = CacheEntry.highlight(highlighted)
            cache.insert(entry, forKey: key, cost: key.inputBytes + entry.outputBytes)
            return highlighted
        }
    }

    func renderKaTeX(tex: String, display: Bool) -> Result<String, KaTeXFailure> {
        queue.sync { () -> Result<String, KaTeXFailure> in
            let key = CacheKey.katex(tex: tex, display: display)
            if case .katex(let cached)? = cache.value(forKey: key) { return cached }
            let result = autoreleasepool { callKaTeX(tex: tex, display: display) }
            let entry = CacheEntry.katex(result)
            cache.insert(entry, forKey: key, cost: key.inputBytes + entry.outputBytes)
            return result
        }
    }

    // MARK: - Bridge calls (all on `queue`)

    private func callHighlight(code: String, language: String) -> String? {
        bridgeCalls += 1
        guard let ctx = ensureHLJS(),
              let fn = ctx.objectForKeyedSubscript("__peekabooHighlight"), !fn.isUndefined,
              let result = fn.call(withArguments: [code, language]), result.isString else { return nil }
        return result.toString()
    }

    private func callKaTeX(tex: String, display: Bool) -> Result<String, KaTeXFailure> {
        bridgeCalls += 1
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
