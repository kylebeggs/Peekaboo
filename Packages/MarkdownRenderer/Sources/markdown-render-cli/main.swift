import Foundation
import MarkdownRenderer

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: markdown-render-cli <file>\n".utf8))
    exit(64)
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
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
