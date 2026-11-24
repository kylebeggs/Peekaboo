import Foundation
import MarkdownRenderer

let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// `git diff <base> | markdown-render-cli --diff [<worktree root>]`: renders the split
// diff page from a unified diff on stdin. With a root, the new side of each file is read
// from disk so it can be syntax-highlighted; the old side has no source here and stays plain.
if arguments.first == "--diff" {
    let root = arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    let files = UnifiedDiff.parse(input)
    let renderer = DiffRenderer()
    var budget = DiffRenderer.highlightBudget
    let rendered = files.enumerated().map { index, file -> String in
        var new: String?
        if let root, let path = file.newPath, renderer.wantsContents(file, forceLoad: false) {
            new = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        let body = renderer.body(for: file, old: nil, new: new, forceLoad: false, budget: &budget)
        return DiffRenderer.fileHTML(file, id: "f\(index)", body: body.html, viewed: false)
    }
    print(DiffRenderer.page(
        title: "Diff", summary: DiffRenderer.summaryHTML(files: files, base: "stdin"), files: rendered))
    exit(0)
}

guard let path = arguments.first else {
    fail("usage: markdown-render-cli <file>\n       markdown-render-cli --diff [<worktree root>] < unified.diff", code: 64)
}

let url = URL(fileURLWithPath: path)
do {
    let data = try Data(contentsOf: url)
    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    var options = RenderOptions()
    options.baseURL = url.deletingLastPathComponent()
    options.title = url.lastPathComponent
    let document = try MarkdownRenderer().renderDocument(fileContents: text, pathExtension: url.pathExtension, options: options)
    print(document.html)
} catch {
    fail("error: \(error.localizedDescription)", code: 1)
}
