import Foundation

/// Maps source-file extensions to highlight.js language tokens. Used to route a
/// file to the syntax-highlighted code path; a `nil` result means render as markdown.
/// `.m` is treated as MATLAB (not Objective-C); `.h` defaults to C.
enum CodeLanguage {
    private static let extensionToLanguage: [String: String] = [
        "py": "python", "pyw": "python",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "c++": "cpp",
        "hpp": "cpp", "hh": "cpp", "hxx": "cpp", "h++": "cpp",
        "m": "matlab",
        "jl": "julia",
        "cs": "csharp",
        "java": "java",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript",
        "rb": "ruby",
        "rs": "rust",
        "go": "go",
        "swift": "swift",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "php": "php",
        "pl": "perl", "pm": "perl",
        "lua": "lua",
        "r": "r",
        "sql": "sql",
        "json": "json",
        "yaml": "yaml", "yml": "yaml",
        "xml": "xml",
        "css": "css", "scss": "scss", "less": "less",
        "kt": "kotlin", "kts": "kotlin",
        "diff": "diff", "patch": "diff",
        "ini": "ini", "toml": "ini", "cfg": "ini",
    ]

    /// highlight.js language token for a code-file extension, or `nil` for markdown
    /// and unrecognized extensions (both render through the markdown pipeline).
    static func highlightLanguage(forPathExtension ext: String) -> String? {
        extensionToLanguage[ext.lowercased()]
    }
}
