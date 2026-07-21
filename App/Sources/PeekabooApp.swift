import SwiftUI

enum Zoom {
    static func zoomedIn(_ zoom: Double) -> Double { min(zoom * 1.1, 3.0) }
    static func zoomedOut(_ zoom: Double) -> Double { max(zoom / 1.1, 0.5) }
}

@main
struct PeekabooApp: App {
    @AppStorage("pageZoom") private var pageZoom = 1.0

    var body: some Scene {
        DocumentGroup(viewing: MarkdownFile.self) { configuration in
            DocumentView(initialText: configuration.document.text, fileURL: configuration.fileURL)
        }
        .defaultSize(width: 900, height: 1560)
        .commands {
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Zoom In") { pageZoom = Zoom.zoomedIn(pageZoom) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { pageZoom = Zoom.zoomedOut(pageZoom) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { pageZoom = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
