import SwiftUI

/// Plain-text markdown editor. Every automatic substitution is disabled — smart quotes,
/// dashes, and text replacement silently corrupt markdown and code blocks.
struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double
    /// Fired on user keystrokes only, never on programmatic adoption of external text,
    /// so the caller can debounce autosave without echoing watcher updates back to disk.
    var onEdit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        // Force TextKit 1: the find bar over TextKit 2 is unreliable on macOS 13.
        _ = textView.layoutManager
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.string = text
        // No window exists yet at make time; claiming first responder must wait a turn.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? NSTextView else { return }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != font { textView.font = font }
        // After a view-originated edit the binding already matches, so this only fires for
        // external text. Never replace the string mid-IME-composition — it destroys the
        // marked text under the user's fingers.
        if textView.string != text, !textView.hasMarkedText() {
            let selection = textView.selectedRange()
            textView.string = text
            let location = min(selection.location, (text as NSString).length)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            // Undo must not cross an external adoption: ⌘Z would resurrect stale text
            // and the next autosave would clobber the file with it.
            textView.undoManager?.removeAllActions()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
        }
    }
}
