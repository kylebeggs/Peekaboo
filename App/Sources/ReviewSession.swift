import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The request file behind a repo review window: `<repo>/.peekaboo/<name>.pkbreview`,
/// written by `peekaboo diff` (or the Review Repository… command) and opened like any
/// other document. Going through the document system rather than a URL scheme means a
/// cold launch shows no Open panel and reopening the same repo focuses its window.
///
/// The file holds one line: the base ref to compare against, empty for the default
/// (merge-base with the default branch). The repo is wherever the file lives.
struct ReviewSession: FileDocument {
    static let reviewType = UTType(exportedAs: "com.kylebeggs.peekaboo.review")
    static var readableContentTypes: [UTType] { [reviewType] }

    static let directoryName = ".peekaboo"
    static let fileExtension = "pkbreview"

    let base: String

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        base = Self.base(from: String(decoding: data, as: UTF8.self))
    }

    static func base(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // Never written through the document system; see `MarkdownFile.fileWrapper`.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }

    /// The working tree a request file belongs to: the parent of its `.peekaboo` folder.
    static func repoRoot(forRequest url: URL) -> URL {
        url.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Creates `.peekaboo/` (self-ignoring, so it never shows in `git status`) and the
    /// request file for `root`, returning the request file's URL.
    static func writeRequest(forRepo root: URL, base: String) throws -> URL {
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ignore = directory.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) {
            try "*\n".write(to: ignore, atomically: true, encoding: .utf8)
        }
        let request = directory.appendingPathComponent(root.lastPathComponent + "." + fileExtension)
        try (base + "\n").write(to: request, atomically: true, encoding: .utf8)
        return request
    }

    /// File > Review Repository…: pick a folder inside a working tree and open its
    /// review, the same thing `peekaboo diff` does from a shell.
    @MainActor
    static func chooseRepository() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Review"
        panel.message = "Choose a git repository to review its changes."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard let root = GitRunner.worktreeRoot(containing: folder) else {
            let alert = NSAlert()
            alert.messageText = "“\(folder.lastPathComponent)” is not inside a git repository."
            alert.runModal()
            return
        }
        do {
            let request = try writeRequest(forRepo: root, base: existingBase(forRepo: root))
            NSDocumentController.shared.openDocument(withContentsOf: request, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// The base a repo's request file already names, so reopening from the menu keeps
    /// whatever `peekaboo diff <base>` last chose.
    private static func existingBase(forRepo root: URL) -> String {
        let request = root.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(root.lastPathComponent + "." + fileExtension)
        return base(from: (try? String(contentsOf: request, encoding: .utf8)) ?? "")
    }
}
