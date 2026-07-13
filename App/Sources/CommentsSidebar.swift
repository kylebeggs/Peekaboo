import SwiftUI
import MarkdownRenderer

/// The native comment panel: lists threads, hosts the new-comment input, and
/// drives scroll-to-highlight. All persistence and anchoring live in `CommentStore`.
struct CommentsSidebar: View {
    @ObservedObject var store: CommentStore

    @State private var pendingText = ""
    @FocusState private var pendingFocused: Bool

    private var groups: (general: [CommentThread], inline: [CommentThread]) {
        CommentOrdering.grouped(store.threads, documentOrder: store.inlineDocumentOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.pending != nil { pendingCard }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        let ordered = groups
                        if ordered.general.isEmpty && ordered.inline.isEmpty && store.pending == nil {
                            emptyState
                        }
                        ForEach(ordered.general, id: \.id) { card($0) }
                        if !ordered.general.isEmpty && !ordered.inline.isEmpty {
                            Divider().padding(.vertical, 4)
                        }
                        ForEach(ordered.inline, id: \.id) { card($0) }
                    }
                    .padding(8)
                }
                .onChange(of: store.selectedThreadID) { id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .frame(minWidth: 260)
        .background(.background)
    }

    @ViewBuilder
    private func card(_ thread: CommentThread) -> some View {
        ThreadCard(
            store: store,
            thread: thread,
            isSelected: store.selectedThreadID == thread.id,
            isOutdated: store.outdatedIDs.contains(thread.id))
            .id(thread.id)
    }

    private var header: some View {
        HStack {
            Text("Comments").font(.headline)
            Spacer()
            Button {
                store.beginGeneralComment()
                pendingFocused = true
            } label: {
                Label("Add general comment", systemImage: "plus.bubble")
            }
            .labelStyle(.iconOnly)
            .help("Add a general comment")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Select text in the document to comment, or add a general comment.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 12)
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let anchor = store.pending?.anchor {
                QuoteView(text: anchor.quote)
            } else {
                Label("General comment", systemImage: "doc.text")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Comment…", text: $pendingText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
                .focused($pendingFocused)
            HStack {
                Spacer()
                Button("Cancel") {
                    store.cancelPending()
                    pendingText = ""
                }
                Button("Comment") {
                    store.commitPending(pendingText)
                    pendingText = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(pendingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .overlay(Divider(), alignment: .bottom)
        .onAppear { pendingFocused = true }
    }
}

private struct ThreadCard: View {
    @ObservedObject var store: CommentStore
    let thread: CommentThread
    let isSelected: Bool
    let isOutdated: Bool

    @State private var replyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            quote
            messages
            replyRow
            actionRow
        }
        .padding(10)
        .background(cardBackground)
        .overlay(cardBorder)
        .opacity(thread.status == .resolved ? 0.7 : 1)
        .onTapGesture { store.selectThread(thread.id) }
    }

    @ViewBuilder private var headerRow: some View {
        HStack(spacing: 6) {
            Image(systemName: thread.kind == .inline ? "text.quote" : "doc.text")
                .foregroundStyle(.secondary)
            if thread.status == .resolved {
                Tag(text: "resolved", color: .green)
            } else if isOutdated && thread.kind == .inline {
                Tag(text: "outdated", color: .orange)
            }
            Spacer()
            if thread.kind == .inline && !isOutdated {
                Button { store.scrollTo(thread.id) } label: {
                    Image(systemName: "scope")
                }
                .buttonStyle(.borderless)
                .help("Jump to highlight")
            }
        }
    }

    @ViewBuilder private var quote: some View {
        if thread.kind == .inline, let anchor = thread.anchor {
            QuoteView(text: anchor.quote)
                .opacity(isOutdated ? 0.5 : 1)
        }
    }

    private var messages: some View {
        ForEach(Array(thread.messages.enumerated()), id: \.offset) { index, message in
            MessageView(store: store, threadID: thread.id, index: index, message: message)
        }
    }

    private var replyRow: some View {
        HStack(spacing: 6) {
            TextField("Reply…", text: $replyText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            Button("Reply") {
                store.addReply(to: thread.id, body: replyText)
                replyText = ""
            }
            .disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var actionRow: some View {
        HStack {
            if thread.status == .open {
                Button("Resolve") { store.setStatus(.resolved, for: thread.id) }
            } else {
                Button("Reopen") { store.setStatus(.open, for: thread.id) }
            }
            Spacer()
            Button(role: .destructive) { store.delete(thread.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete comment")
        }
        .font(.caption)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
    }
}

private struct QuoteView: View {
    let text: String
    var body: some View {
        Text(text.split(whereSeparator: \.isWhitespace).joined(separator: " "))
            .font(.callout)
            .italic()
            .lineLimit(3)
            .padding(.leading, 8)
            .overlay(Rectangle().frame(width: 3).foregroundStyle(.secondary), alignment: .leading)
            .foregroundStyle(.secondary)
    }
}

private struct MessageView: View {
    @ObservedObject var store: CommentStore
    let threadID: String
    let index: Int
    let message: CommentMessage

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    private var isEditable: Bool { message.speaker == CommentStore.localSpeaker }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.speaker).font(.caption).bold()
                Text(message.timestamp).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if isEditable && !isEditing {
                    Button { beginEdit() } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit comment")
                }
            }
            if isEditing {
                editor
            } else {
                CommentBodyView(text: message.body, cache: store.renderCache)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Comment…", text: $editText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .focused($editFocused)
            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                Button("Save") { commitEdit() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .font(.caption)
        }
    }

    private func beginEdit() {
        editText = message.body
        isEditing = true
        editFocused = true
    }

    private func commitEdit() {
        store.editMessage(in: threadID, at: index, body: editText)
        isEditing = false
    }
}

private struct Tag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.caption2).bold()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
