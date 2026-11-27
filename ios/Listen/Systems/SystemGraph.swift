import SwiftUI

/// How a system is wired, drawn from its blocks: the path from the sound to the cards, what feeds
/// the decisions, and what happens at the end. Blocks that are off are drawn faint and dashed;
/// blocks this build cannot run yet are dashed in orange. The path that decides how fast a card
/// comes is drawn in the accent colour.
struct SystemGraph: View {
    let system: ListenSystem

    /// A place in the drawing: the blocks, plus the sound and the table they lead to.
    enum Node: Hashable {
        case sound, table
        case block(ListenSystem.Kind)
    }

    private static let width: CGFloat = 156
    private static let height: CGFloat = 52
    private static let columnStep: CGFloat = 186
    private static let rowStep: CGFloat = 74

    /// Where each node sits: column and row. Modifier blocks (Swiss German, research of weak
    /// drafts, forecast while speaking) are shown on the block they modify.
    static func place(_ node: Node) -> (column: Int, row: Int)? {
        switch node {
        case .sound: (0, 1)
        case .table: (4, 1)
        case .block(let kind):
            switch kind {
            case .hearing: (1, 1)
            case .secondHearing: (1, 2)
            case .speakers: (1, 3)
            case .repositories: (2, 0)
            case .decisions: (2, 1)
            case .forecast: (2, 3)
            case .quotes: (3, 0)
            case .writer: (3, 1)
            case .research: (3, 2)
            case .meetingItems: (3, 3)
            case .names: (0, 3)
            case .summary: (5, 1)
            case .meetingMinutes: (5, 2)
            case .swissGerman, .researchRejected, .forecastWhileSpeaking: nil
            }
        }
    }

    struct Edge: Hashable {
        var from: Node
        var to: Node
        /// On the path that decides how fast a card comes.
        var critical = false
    }

    /// The connections of a system: which block hands what to which.
    static func edges(of system: ListenSystem) -> [Edge] {
        let decides = system.isOn(.decisions)
        let next: Node = decides ? .block(.decisions) : .block(.writer)
        var edges = [
            Edge(from: .sound, to: .block(.hearing), critical: true),
            Edge(from: .block(.hearing), to: next, critical: true),
            Edge(from: .block(.hearing), to: .block(.secondHearing)),
            Edge(from: .block(.secondHearing), to: next),
            Edge(from: .block(.secondHearing), to: .block(.speakers)),
            Edge(from: .block(.writer), to: .table, critical: true),
            Edge(from: .table, to: .block(.summary)),
            Edge(from: .block(.hearing), to: .block(.meetingMinutes)),
            Edge(from: .block(.hearing), to: .block(.meetingItems)),
            Edge(from: .block(.meetingItems), to: .table),
        ]
        if decides {
            edges += [
                Edge(from: .block(.decisions), to: .block(.writer), critical: true),
                Edge(from: .block(.decisions), to: .block(.quotes)),
                Edge(from: .block(.decisions), to: .block(.research)),
                Edge(from: .block(.forecast), to: .block(.decisions)),
                Edge(from: .block(.repositories), to: .block(.decisions)),
                Edge(from: .block(.quotes), to: .table),
            ]
        } else {
            edges.append(Edge(from: .block(.repositories), to: .block(.writer)))
        }
        edges.append(Edge(from: .block(.research), to: .table))
        return edges
    }

    private func frame(_ node: Node) -> CGRect? {
        guard let place = Self.place(node) else { return nil }
        return CGRect(x: 8 + CGFloat(place.column) * Self.columnStep, y: 8 + CGFloat(place.row) * Self.rowStep,
                      width: Self.width, height: Self.height)
    }

    private func isOn(_ node: Node) -> Bool {
        if case .block(let kind) = node { return system.isOn(kind) }
        return true
    }

    private func isMissing(_ node: Node) -> Bool {
        if case .block(let kind) = node { return system.isOn(kind) && !kind.isBuilt }
        return false
    }

    @ViewBuilder var body: some View {
        if system.isVoiceAssistant {
            HStack(spacing: 12) {
                Label("Microphone", systemImage: "mic")
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Label("On-device recognition", systemImage: "waveform")
                    Label("Selected conversation model", systemImage: "bubble.left.and.bubble.right")
                    Text("\(system.configuration?.conversation?.toolIDs.count ?? 0) requested tool bindings").font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Label(system.configuration?.conversation?.speakReplies == false ? "Text reply"
                    : system.configuration?.conversation?.talkBackEngine == .local ? "Spoken reply · local voice" : "Spoken reply", systemImage: "speaker.wave.2")
            }.padding(12)
        } else { cardGraph }
    }

    @ViewBuilder private var cardGraph: some View {
        let nodes: [Node] = [.sound, .table] + ListenSystem.Kind.allCases.map { .block($0) }.filter { frame($0) != nil }
        let edges = Self.edges(of: system)
        ZStack(alignment: .topLeading) {
            ForEach(edges, id: \.self) { edge in
                if let from = frame(edge.from), let to = frame(edge.to) {
                    let live = isOn(edge.from) && isOn(edge.to)
                    Self.connection(from: from, to: to)
                        .stroke(edge.critical && live ? Color.accentColor : Color.secondary.opacity(live ? 0.8 : 0.3),
                                style: StrokeStyle(lineWidth: edge.critical && live ? 2 : 1.2, dash: live ? [] : [4, 4]))
                }
            }
            ForEach(nodes, id: \.self) { node in
                if let rect = frame(node) { box(node).frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY) }
            }
        }
        .frame(width: 8 + 5 * Self.columnStep + Self.width + 8, height: 8 + 3 * Self.rowStep + Self.height + 8, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let on = system.blocks.filter(\.on).map(\.kind.title)
        return "\(system.name) runs: " + on.joined(separator: ", ")
    }

    @ViewBuilder private func box(_ node: Node) -> some View {
        let on = isOn(node), missing = isMissing(node)
        let tint: Color = missing ? .orange : (critical(node) && on ? .accentColor : .secondary)
        VStack(alignment: .leading, spacing: 2) {
            Label(title(node), systemImage: symbol(node)).font(.caption.weight(.semibold)).lineLimit(1)
            Text(subtitle(node)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(tint.opacity(on ? 1 : 0.35), style: StrokeStyle(lineWidth: critical(node) && on ? 2 : 1.2, dash: on && !missing ? [] : [4, 3]))
        }
        .opacity(on ? 1 : 0.45)
    }

    private func critical(_ node: Node) -> Bool {
        switch node {
        case .sound, .table: true
        case .block(let kind): kind == .hearing || kind == .writer || (kind == .decisions && system.isOn(.decisions))
        }
    }

    private func title(_ node: Node) -> String {
        switch node {
        case .sound: "Sound"
        case .table: system.isOn(.meetingItems) ? "Protocol and cards" : "Card table"
        case .block(let kind): kind.title
        }
    }

    private func symbol(_ node: Node) -> String {
        switch node {
        case .sound: "mic"
        case .table: "rectangle.stack"
        case .block(let kind): kind.symbol
        }
    }

    private func subtitle(_ node: Node) -> String {
        switch node {
        case .sound: return "Microphone, app sound"
        case .table: return "One block per subject"
        case .block(let kind):
            if !kind.isBuilt && system.isOn(kind) { return "Not built yet" }
            if !system.isOn(kind) { return "Off" }
            switch kind {
            case .secondHearing: return system.isOn(.swissGerman) ? "Whisper + Swiss German" : "Whisper"
            case .research: return system.isOn(.researchRejected) ? "Also for weak drafts" : "With sources"
            case .forecast: return system.isOn(.forecastWhileSpeaking) ? "Also while speaking" : "Prepared cards"
            case .decisions: return "Jev"
            case .writer: return "Fast model"
            case .speakers: return "Voices, call sides"
            default: return "On"
            }
        }
    }

    /// From the right of one box into the left of the next, with a bend between columns; a box
    /// in the same column is joined top to bottom.
    static func connection(from: CGRect, to: CGRect) -> Path {
        var path = Path()
        if abs(from.midX - to.midX) < 1 {
            let down = to.midY > from.midY
            let start = CGPoint(x: from.midX, y: down ? from.maxY : from.minY)
            let end = CGPoint(x: to.midX, y: down ? to.minY : to.maxY)
            path.move(to: start)
            path.addLine(to: end)
            path.addPath(arrow(at: end, pointing: CGVector(dx: 0, dy: down ? 1 : -1)))
            return path
        }
        let start = CGPoint(x: from.maxX, y: from.midY)
        let end = CGPoint(x: to.minX, y: to.midY)
        let bend = to.minX - 12
        path.move(to: start)
        path.addLine(to: CGPoint(x: bend, y: start.y))
        path.addLine(to: CGPoint(x: bend, y: end.y))
        path.addLine(to: end)
        path.addPath(arrow(at: end, pointing: CGVector(dx: 1, dy: 0)))
        return path
    }

    private static func arrow(at tip: CGPoint, pointing direction: CGVector) -> Path {
        let back = CGPoint(x: tip.x - direction.dx * 7, y: tip.y - direction.dy * 7)
        let side = CGVector(dx: -direction.dy * 4, dy: direction.dx * 4)
        var path = Path()
        path.move(to: CGPoint(x: back.x + side.dx, y: back.y + side.dy))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: back.x - side.dx, y: back.y - side.dy))
        return path
    }
}
