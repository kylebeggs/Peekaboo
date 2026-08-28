import SwiftUI

/// Bridges per-window document state to app-scope menu commands.
///
/// The content-width toggle is `@State` on each `DocumentView`, so every window keeps its own
/// setting, but `.commands` is built once for the whole app and cannot reach into a window.
/// A focused scene value carries the key window's binding up to the View menu.
struct FullWidthKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var fullWidth: Binding<Bool>? {
        get { self[FullWidthKey.self] }
        set { self[FullWidthKey.self] = newValue }
    }
}

/// The key window's "flush pending autosave now" action, for File > Save (⌘S).
/// An action struct rather than a Binding: Save is a verb, not state to observe.
struct SaveDocumentKey: FocusedValueKey {
    typealias Value = SaveDocumentAction
}

struct SaveDocumentAction {
    let save: () -> Void
}

extension FocusedValues {
    var saveDocument: SaveDocumentAction? {
        get { self[SaveDocumentKey.self] }
        set { self[SaveDocumentKey.self] = newValue }
    }
}
