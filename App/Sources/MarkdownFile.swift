import SwiftUI
import UniformTypeIdentifiers

struct MarkdownFile: FileDocument {
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown")
    static var readableContentTypes: [UTType] { [markdownType, .plainText] }

    let text: String

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
