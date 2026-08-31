import SwiftUI

enum Zoom {
    static func zoomedIn(_ zoom: Double) -> Double { min(zoom * 1.1, 3.0) }
    static func zoomedOut(_ zoom: Double) -> Double { max(zoom / 1.1, 0.5) }
}

@main
struct PeekabooApp: App {
    @AppStorage("pageZoom") private var pageZoom = 1.0
    // Published by whichever DocumentView currently has focus; nil when no document window does.
    @FocusedValue(\.fullWidth) private var fullWidth: Binding<Bool>?
    @FocusedValue(\.saveDocument) private var saveDocument: SaveDocumentAction?

    var body: some Scene {
        DocumentGroup(viewing: MarkdownFile.self) { configuration in
            DocumentView(initialText: configuration.document.text, fileURL: configuration.fileURL)
        }
        .defaultSize(width: defaultWindowWidth, height: 1330)
        .commands {
            // `replacing:`, not `after:`: if a system Save chain ever materializes (it
            // does when CFBundleTypeRole is Editor), a duplicate ⌘S resolves to the item
            // higher in the menu — the system one, which routes into NSDocument and hits
            // its stale-snapshot conflict sheet. Saving here flushes the pending autosave
            // immediately; flushing a clean buffer is a no-op, so it stays enabled in
            // both modes rather than beeping at a reflexive ⌘S.
            CommandGroup(replacing: .saveItem) {
                Button("Save") { saveDocument?.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(saveDocument == nil)
            }
            CommandGroup(after: .sidebar) {
                Divider()
                Toggle("Full Width", isOn: fullWidth ?? .constant(false))
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(fullWidth == nil)
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
