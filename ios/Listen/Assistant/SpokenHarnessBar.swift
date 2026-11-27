import SwiftUI

/// The conversation itself, fixed above the cards of a spoken conversation: what Listen is
/// doing right now, a way to stop it talking, the last words it heard and the sentence it is
/// saying. The voice and what answers are in `SpokenHarnessDetails`, at the top of the cards.
///
/// It names whether the running input actually supports hearing during output; a test
/// double or unavailable input must not advertise native echo cancellation.
/// The sentence shown is the one the player has begun, not one that is only prepared.
///
/// It stays bounded, because it is fixed and everything it takes is taken from the cards:
/// the state and the stop keep a capped type size and are always there, and the words take
/// at most `wordsLimit` and scroll inside it when large type needs more.
struct SpokenHarnessBar: View {
    let model: SessionModel
    let spoken: SpokenHarness
    /// The most height the words may take, a share of the screen given by the owner.
    var wordsLimit: CGFloat = 200
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize

    private static let heardID = "spoken.words.heard"
    private static let sentenceID = "spoken.words.sentence"

    private var state: (title: String, note: String, symbol: String) {
        switch spoken.activity {
        case .paused: ("Paused", "Nothing is said until the conversation goes on.", "pause.fill")
        case .preparing: ("Preparing", spoken.listensWhileSpeaking ? "Listen hears you." : "Listen does not hear you meanwhile.", "speaker.wave.1")
        case .speaking: ("Speaking", spoken.listensWhileSpeaking ? "Listen hears you. Speak to interrupt." : "Listen does not hear you meanwhile.", "speaker.wave.2.fill")
        case .sample: ("Voice sample", spoken.listensWhileSpeaking ? "Listen hears you. Speak to interrupt." : "Listen does not hear you meanwhile.", "play.circle")
        case .thinking: ("Thinking", "Listen still hears you.", "ellipsis")
        case .waitingForPause: ("Waiting for a pause", "The answer starts when it is quiet.", "hourglass")
        case .listening:
            ("Listening", spoken.configuration.speakReplies ? "Listen hears you." : "Answers are shown, not spoken.", "ear")
        }
    }

    /// The newest words the recogniser has, finished or not.
    private var heard: TranscriptSegment? {
        for line in model.core.lines.reversed() {
            if case .speech(let segment) = line.content { return segment }
        }
        return nil
    }

    /// Large type gets the room it needs inside the scrolling words; otherwise the lines are
    /// reserved, so the cards below do not move with every sentence.
    private var roomy: Bool { typeSize.isAccessibilitySize }
    /// A phone on its side: little height and enough width, so the words stand beside the state.
    private var short: Bool { verticalSize == .compact }

    var body: some View {
        Group {
            if short {
                HStack(alignment: .top, spacing: 16) {
                    fixed.frame(maxWidth: .infinity, alignment: .leading)
                    words.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    fixed
                    words
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 640, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 22))
        .frame(maxWidth: .infinity)
        .thinkingCue(while: spoken.waiting)
    }

    /// The state and the stop. Their type stops growing at the second accessibility size, as in
    /// a bar of the system: they must stay on a small screen whatever else is shown.
    private var fixed: some View {
        Group {
            if roomy {
                VStack(alignment: .leading, spacing: 8) { status; stop }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    status.frame(maxWidth: .infinity, alignment: .leading)
                    stop
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private var status: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: state.symbol)
                .font(.title3.weight(.semibold))
                .frame(minWidth: 28)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(roomy ? .headline : .title2.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.note).font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: !roomy && !short)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: spoken.activity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("spoken.status")
    }

    /// Stops what Listen is saying. The conversation goes on; the stop below the cards ends it.
    @ViewBuilder private var stop: some View {
        if spoken.speaking {
            Button(role: .destructive) { spoken.interrupt() } label: {
                Label("Stop speaking", systemImage: "stop.fill")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            .tint(.red)
            .accessibilityHint("Listen stops talking and hears you again")
            .accessibilityIdentifier("spoken.interrupt")
            .transition(.opacity)
        }
    }

    /// The last words heard and the sentence being said. They are shown whole when they fit
    /// into `wordsLimit`; otherwise they scroll inside it, at the side that matters now: the
    /// sentence while Listen speaks, what was heard while it listens.
    private var words: some View {
        ScrollViewReader { proxy in
            ScrollView {
                wordLines.fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("spoken.words")
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: spoken.audible, initial: true) { _, audible in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    proxy.scrollTo(audible ? Self.sentenceID : Self.heardID, anchor: audible ? .bottom : .top)
                }
            }
        }
        .frame(height: max(44, min(wordsLimit, short ? 84 : roomy ? 180 : 152)))
        .clipped()
    }

    private var wordLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(heard.map { model.core.isMine($0) ? "You" : "Heard" } ?? "Heard", heard?.text ?? "Nothing heard yet.",
                 lines: short ? 1 : 2, style: .footnote, dimmed: heard == nil, tentative: heard?.isFinal == false)
                .accessibilityIdentifier("spoken.heard")
                .id(Self.heardID)
            line(spoken.audible ? "Listen says" : "Listen said", spoken.audibleSentence.isEmpty ? "Nothing said yet." : spoken.audibleSentence,
                 lines: short ? 2 : 3, style: .body, dimmed: !spoken.audible, tentative: false)
                .accessibilityIdentifier("spoken.sentence")
                .id(Self.sentenceID)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One side of the exchange: who, then the words.
    private func line(_ who: String, _ text: String, lines: Int, style: Font.TextStyle, dimmed: Bool, tentative: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(who.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            reserved(Text(text).font(.system(style)).italic(tentative).foregroundStyle(dimmed || tentative ? .secondary : .primary),
                     lines: lines)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func reserved(_ text: some View, lines: Int) -> some View {
        if roomy {
            // Whole, however long: the words scroll inside their bound.
            text.fixedSize(horizontal: false, vertical: true)
        } else {
            text.lineLimit(lines, reservesSpace: true).minimumScaleFactor(0.85)
        }
    }
}

/// What a spoken conversation is set to: the voice with its sample, what the voice needs on
/// this device, and which system answers. It is the first block of the cards and scrolls with
/// them, so its height, with large type or the disclosure open, takes nothing from the fixed
/// header. The state and the stop are in `SpokenHarnessBar` and are not repeated here.
struct SpokenHarnessDetails: View {
    let model: SessionModel
    let spoken: SpokenHarness
    @State private var showsSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AssistantVoiceMenu(current: spoken.voice, language: model.core.language, preview: spoken.preview,
                               canSample: !spoken.paused,
                               canPreviewPulse: !spoken.speaking && !spoken.hearing,
                               choose: { try spoken.chooseVoice($0) }, sample: { spoken.playSample() })
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            LocalVoiceNotice(configuration: spoken.configuration).font(.caption)
            if !spoken.source.isEmpty {
                DisclosureGroup("What answers", isExpanded: $showsSource) {
                    VStack(alignment: .leading, spacing: 6) {
                        // Which of the person's systems is answering, in its own name.
                        Text(spoken.source).accessibilityIdentifier("spoken.source")
                        Text("Each answer is also a card below, with its sources.")
                        if model.isRecording { Label("Recording on this device", systemImage: "record.circle") }
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("spoken.details")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 22))
    }
}
