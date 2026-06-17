/// Display ordering for the comment sidebar, kept UI-free so it is testable.
///
/// Whole-document threads come first (chronological by first message), then inline
/// threads in document reading order. Within each group, resolved threads sink below
/// open ones. The thread's original array index is the deterministic tiebreak when sort
/// keys collide — same-minute timestamps, or inline threads with no reported position.
public enum CommentOrdering {
    public static func grouped(
        _ threads: [CommentThread],
        documentOrder: [String: Int]
    ) -> (general: [CommentThread], inline: [CommentThread]) {
        let indexed = Array(threads.enumerated())
        return (
            general: order(indexed.filter { $0.element.kind == .general }) {
                $0.messages.first?.timestamp ?? ""
            },
            inline: order(indexed.filter { $0.element.kind == .inline }) {
                documentOrder[$0.id] ?? Int.max
            }
        )
    }

    private static func order<Key: Comparable>(
        _ items: [(offset: Int, element: CommentThread)],
        by key: (CommentThread) -> Key
    ) -> [CommentThread] {
        items.sorted { lhs, rhs in
            if lhs.element.status != rhs.element.status { return lhs.element.status == .open }
            let lk = key(lhs.element), rk = key(rhs.element)
            if lk != rk { return lk < rk }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }
}
