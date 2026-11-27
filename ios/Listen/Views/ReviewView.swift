import SwiftUI

/// After a conversation: a summary in one narrow, centred column, on a phone
/// and on a Mac alike. Who took part, then what Listen showed; what was heard
/// is folded away, because it matters least.
struct ReviewView: View {
    let model: SessionModel
    @State private var showsHeard = false


    private var cards: [SessionCore.Card] {
        model.core.cards.filter { !$0.text.isEmpty && $0.status != .superseded && $0.status != .cancelled }
    }

    private var heard: [TranscriptSegment] {
        model.core.lines.compactMap {
            if case .speech(let segment) = $0.content, segment.isFinal { segment } else { nil }
        }
    }

    private var duration: String {
        let seconds = model.capturedFrames / 10
        return seconds < 60 ? "\(seconds) s" : String(format: "%d:%02d min", seconds / 60, seconds % 60)
    }

    /// What stays on this device after Done, said plainly.
    private var saved: String {
        var parts: [String] = []
        if model.savedNote != nil {
            parts.append("A note with the cards and a short summary is kept in this topic, so the next conversation here continues from it.")
        }
        if let run = model.recordedTo {
            parts.append("Recorded on this device for improving Listen: \(run.lastPathComponent).")
        }
        return parts.isEmpty
            ? "Nothing was saved. This disappears when you choose Done."
            : parts.joined(separator: " ") + " Both can be deleted in Account."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // Everything that is not a card starts where the text inside the cards starts.
                header.padding(.horizontal, CardMetrics.inset)
                people.padding(.horizontal, CardMetrics.inset)
                shown
                said.padding(.horizontal, CardMetrics.inset)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 24)
            .frame(maxWidth: CardMetrics.column + 48, alignment: .leading)  // 24 of margin on each side
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button { model.send(.done) } label: {
                Text("Done").font(.headline).foregroundStyle(Color(.systemBackground))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .frame(maxWidth: 320)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.topicName.isEmpty ? "Conversation" : model.topicName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Session ended").font(.largeTitle.weight(.bold))
            Text("\(duration) listened · \(heard.count) sentences · \(cards.count) cards")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(saved)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            if let run = model.recordedTo {
                // The whole conversation again, moment by moment, with what the harness did.
                Button("Replay this conversation", systemImage: "play.circle") { model.replaying = run }
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
            }
        }
    }

    /// Everyone who spoke, as the soft figures.
    @ViewBuilder
    private var people: some View {
        let people = model.everyone
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                label("At the table")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(people) { person in
                        VStack(spacing: 6) {
                            if person.label == .me {
                                SpeakerFigure(figure: .mine, style: .soft, size: 64)
                            } else {
                                let animal = Figure.forVoice(person.id)
                                SpeakerFigure(figure: animal.figure, style: .soft, size: 64, turn: animal.turn)
                            }
                            Text(person.title).font(.caption.weight(.semibold))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var shown: some View {
        VStack(alignment: .leading, spacing: 22) {
            label("Listen showed").padding(.horizontal, CardMetrics.inset)
            if cards.isEmpty {
                Text("No cards in this conversation.").foregroundStyle(.secondary).padding(.horizontal, CardMetrics.inset)
            }
            ForEach(CardBlocks.blocks(from: model.core.cards)) { block in
                CardStack(block: block, cornerRadius: 22) { card, _ in
                    CardBody(text: card.text, type: .regular)
                }
            }
        }
    }

    /// The transcript, closed until asked for.
    private var said: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.smooth) { showsHeard.toggle() }
            } label: {
                HStack {
                    label("Heard · \(heard.count) sentences")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showsHeard ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(heard.isEmpty)
            .accessibilityHint(showsHeard ? "Hides what was heard" : "Shows what was heard")
            if showsHeard {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(heard, id: \.segmentID) { segment in
                        HStack(alignment: .top, spacing: 8) {
                            if model.core.isMine(segment) {
                                SpeakerFigure(figure: .mine, style: .pixel, size: 22)
                            } else if let voice = segment.voice {
                                let animal = Figure.forVoice(voice)
                                SpeakerFigure(figure: animal.figure, style: .pixel, size: 22, turn: animal.turn)
                            }
                            Text(segment.text).font(.footnote).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote.weight(.bold)).foregroundStyle(.secondary)
    }
}
