import Foundation
import MarkdownRenderer

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: markdown-render-cli <file.md>\n".utf8))
    exit(64)
}

let url = URL(fileURLWithPath: path)
do {
    let data = try Data(contentsOf: url)
    let markdown = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    var options = RenderOptions()
    options.baseURL = url.deletingLastPathComponent()
    options.title = url.lastPathComponent
    let document = try MarkdownRenderer().renderDocument(markdown: markdown, options: options)
    print(document.html)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
