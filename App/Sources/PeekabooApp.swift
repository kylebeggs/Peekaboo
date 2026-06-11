import SwiftUI

@main
struct PeekabooApp: App {
    var body: some Scene {
        DocumentGroup(viewing: MarkdownFile.self) { configuration in
            DocumentView(initialText: configuration.document.text, fileURL: configuration.fileURL)
        }
    }
}
