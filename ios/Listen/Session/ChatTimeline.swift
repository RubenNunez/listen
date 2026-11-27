import Foundation

/// The conversation as one stream: what was said, with each answer placed
/// directly under the line that triggered it.
enum ChatItem: Identifiable, Equatable {
    case line(SessionCore.Line)
    case card(SessionCore.Card)

    var id: String {
        switch self {
        case .line(let line): line.id
        case .card(let card): "c\(card.id)"
        }
    }
}

extension SessionCore {
    var timeline: [ChatItem] {
        // A request that was replaced before it wrote anything is not shown.
        var pending = cards.filter { !$0.text.isEmpty || $0.status == .streaming }
        var items: [ChatItem] = []
        for line in lines {
            items.append(.line(line))
            guard case .speech(let segment) = line.content, segment.isFinal else { continue }
            items += pending.filter { $0.start.triggerSegment == segment.segmentID }.map(ChatItem.card)
            pending.removeAll { $0.start.triggerSegment == segment.segmentID }
        }
        return items + pending.map(ChatItem.card)
    }

    /// Whether a transcript line belongs to the user, including lines spoken
    /// before the voice was marked.
    func isMine(_ segment: TranscriptSegment) -> Bool {
        segment.speaker == .me || (segment.voice != nil && segment.voice == meVoice)
    }
}
