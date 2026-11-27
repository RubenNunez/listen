import SwiftUI

struct ListenView: View {
    let model: SessionModel
    private var core: SessionCore { model.core }

    private var isPaused: Bool {
        switch core.phase {
        case .pausedByUser, .interrupted: true
        default: false
        }
    }

    @AppStorage("showLayers") private var showLayers = false

    /// What was heard is secondary and can be hidden; what Listen shows is the point.
    @AppStorage("showHeard") private var showHeard = true
    @State private var naming: UInt32?
    @State private var draftName = ""

    /// The conversation is spoken: its state, the last words heard and the sentence being said
    /// are in `SpokenHarnessBar`, so the header and the feeds do not say them a second time.
    /// Its voice and what answers are the first block of the cards (`SpokenHarnessDetails`).
    private var spoken: SpokenHarness? { model.spoken }
    private var showsHeaderControls: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        spoken == nil
        #endif
    }
    /// The layout with what was heard as a sidebar.
    @State private var wide = false
    /// The height of the whole screen, with what the header and the controls take. The fixed
    /// header gives the spoken words a share of it, so the cards keep the rest.
    @State private var fullHeight: CGFloat = 700
    @State private var showsVoiceSettings = false

    var body: some View {
        Group {
            if spoken != nil {
                // Separate layout regions: scrolling cards cannot draw through the voice
                // panel, and the panel cannot advertise less height than it renders.
                VStack(spacing: 0) {
                    header.fixedSize(horizontal: false, vertical: true)
                    feed.frame(maxHeight: .infinity).clipped()
                    controls.dynamicTypeSize(...DynamicTypeSize.accessibility1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                feed
                    .safeAreaInset(edge: .top, spacing: 0) { header }
                    .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { wide = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { fullHeight = $0 }
        .animation(.smooth, value: showLayers)
        .animation(.smooth, value: showHeard)
        #if !targetEnvironment(macCatalyst)
        .safeAreaInset(edge: .top, spacing: 0) {
            if spoken != nil {
                HStack {
                    Spacer()
                    ListenSettingsButton(identifier: "spoken.settings") { showsVoiceSettings = true }
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            }
        }
        .sheet(isPresented: $showsVoiceSettings) {
            if let spoken {
                LiveVoiceSettings(configuration: spoken.configuration, language: model.core.language,
                    preview: spoken.preview, canSample: !spoken.paused,
                    canPreviewPulse: !spoken.speaking && !spoken.hearing,
                    choose: { try spoken.chooseVoice($0) }, sample: { spoken.playSample() })
            }
        }
        #endif
    }

    private var feed: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 760 {
                // Mac and wide screens: the output is the page, with desktop
                // margins and a readable column; what was heard is a sidebar.
                HStack(alignment: .top, spacing: 0) {
                    OutputFeed(model: model, margin: 40)
                        .frame(maxWidth: CardMetrics.column + 80)  // the feed's margin is 40 on each side
                        .frame(maxWidth: .infinity)
                    if showHeard || (showLayers && !model.isDemo) {
                        VStack(spacing: 16) {
                            if showHeard { InputFeed(model: model, compact: false) }
                            if showLayers, !model.isDemo { LayerOverlay(model: model) }
                        }
                        .padding(20)
                        .frame(width: min(340, geometry.size.width * 0.32))
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 22))
                        .padding(.trailing, 24)
                        .padding(.vertical, 12)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            } else {
                VStack(spacing: 0) {
                    OutputFeed(model: model, margin: 20)
                    if showLayers, !model.isDemo {
                        LayerOverlay(model: model).padding(.horizontal, 16).padding(.bottom, 8)
                    }
                    // Spoken, the last words heard stand with the conversation above the cards.
                    if showHeard, spoken == nil {
                        InputFeed(model: model, compact: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 18))
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            if showsHeaderControls {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(core.forwardsAudio ? Color.red : Color.secondary)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    // Spoken, "Listening" would also stand here while Listen talks and does not hear.
                    if spoken == nil || core.phase != .listening {
                        Text(core.phase.title).font(.subheadline.weight(.semibold))
                    }
                    Text(elapsed).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                    if model.isRecording {
                        Text("REC").font(.caption2.weight(.bold)).foregroundStyle(.red)
                            .accessibilityLabel("This conversation is being recorded on this device")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .accessibilityElement(children: .combine)
                Spacer()
                // Spoken, only hearing and the voice are on the device; the answers come from the
                // providers of the chosen system, so "On device" would not be true of the whole.
                Text(model.isDemo ? "\(model.topicName) · Demo" : spoken != nil ? model.topicName : "\(model.topicName) · On device")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                // Spoken on a narrow screen there is no list of what was heard to show or hide.
                if spoken == nil || wide {
                    Button { showHeard.toggle() } label: {
                        Image(systemName: showHeard ? "ear.fill" : "ear")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(showHeard ? "Hide what was heard" : "Show what was heard")
                }
                if !model.isDemo {
                    Button { withAnimation(.smooth(duration: 0.3)) { model.showsTimeline.toggle() } } label: {
                        Image(systemName: "chart.bar.xaxis").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Timeline of this conversation")
                    Button { showLayers.toggle() } label: {
                        Image(systemName: showLayers ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(showLayers ? "Hide layers" : "Show layers")
                }
            }
            .dynamicTypeSize(...(spoken != nil ? DynamicTypeSize.accessibility1 : .accessibility5))
            }
            participants
                .dynamicTypeSize(...(spoken != nil ? DynamicTypeSize.accessibility1 : .accessibility5))
            // Messages are short notes, not bars: on a Mac they stay a narrow,
            // centred column instead of spanning the window.
            VStack(spacing: 8) {
                if case .interrupted(let reason) = core.phase {
                    Label("\(reason.explanation) Tap play to continue.", systemImage: "pause.circle.fill")
                        .foregroundStyle(.orange)
                        .glassBanner()
                }
                if let error = model.captureError {
                    Label(error, systemImage: "mic.slash.fill").foregroundStyle(.red).glassBanner()
                }
                if core.headphones {
                    Label("Headphones connected: the phone may not hear the other person.", systemImage: "headphones")
                        .foregroundStyle(.orange)
                        .glassBanner()
                }
                if model.isDemo, !core.automaticSuggestionsOn, core.lines.contains(where: \.isFinalSpeech) {
                    Label("Which voice is yours? Tap “This is me” under one of your own lines, then answers come by themselves.", systemImage: "person.wave.2.fill")
                        .glassBanner()
                }
                if let notice = core.notice {
                    Button { model.send(.dismissNotice) } label: {
                        Label(notice.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .glassBanner()
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses this message")
                }
            }
            .frame(maxWidth: 520)
            // A quarter of the screen at most for the words; they scroll inside it when they need more.
            if let spoken { SpokenHarnessBar(model: model, spoken: spoken, wordsLimit: max(88, fullHeight * 0.25)) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .animation(.smooth, value: core.phase)
    }

    /// Who is in the conversation, with the last speaker filled in.
    @ViewBuilder
    private var participants: some View {
        let people = model.participants
        if !people.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(people) { person in
                        // Tap a voice to say who it is: yourself, or someone by name.
                        Menu {
                            if person.label != .me {
                                Button("This is me", systemImage: "person.fill") { model.send(.thisIsMe(voice: person.id)) }
                            }
                            Button(person.name == nil ? "Give a name" : "Change name", systemImage: "pencil") {
                                draftName = person.name ?? ""
                                naming = person.id
                            }
                            if person.name != nil {
                                Button("Remove name", systemImage: "xmark") { model.name(person.id, "") }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if person.label == .me {
                                    SpeakerFigure(figure: .mine, style: .soft, size: 30)
                                } else {
                                    let animal = Figure.forVoice(person.id)
                                    SpeakerFigure(figure: animal.figure, style: .soft, size: 30, turn: animal.turn)
                                }
                                Text(person.title)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(person.isSpeaking ? Color(.systemBackground) : .primary)
                            .padding(.leading, 6)
                            .padding(.trailing, 12)
                            .padding(.vertical, 4)
                            .background(person.isSpeaking ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary), in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(person.isSpeaking ? "\(person.title), spoke last" : person.title)
                        .accessibilityHint("Says who this voice is")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .animation(.smooth(duration: 0.3), value: people)
            .alert("Who is this?", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
                TextField("Name", text: $draftName)
                Button("Save") {
                    if let naming { model.name(naming, draftName) }
                    naming = nil
                }
                Button("Cancel", role: .cancel) { naming = nil }
            } message: {
                Text("The name stays on this device and is gone when the conversation ends.")
            }
        } else if spoken == nil, !model.isDemo, core.lines.contains(where: \.isFinalSpeech) {
            Text(model.stageStatus.last ?? "Working out who is speaking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var elapsed: String {
        let seconds = model.capturedFrames / 10
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 6) {
            GlassEffectContainer(spacing: 30) {
                HStack(spacing: 30) {
                    Button {
                        model.send(isPaused ? .resume : .pause)
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(isPaused ? "Resume" : "Pause")

                    Button { model.send(.helpNow) } label: {
                        SessionOrb(model: model, speakers: model.speakerCount, isActive: !isPaused)
                        .frame(width: 150, height: 84)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Help now")
                    .accessibilityHint("Asks for an answer to what was just said")

                    Button(role: .destructive) {
                        model.send(.stop)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .tint(.red)
                    .accessibilityLabel("Stop")
                }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private extension SessionCore.Line {
    var isFinalSpeech: Bool {
        if case .speech(let segment) = content { segment.isFinal } else { false }
    }
}

// MARK: Output

/// What Listen shows. Cards arrive rarely, are meant to fit, and stay.
private struct OutputFeed: View {
    let model: SessionModel
    let margin: CGFloat
    private var core: SessionCore { model.core }
    @State private var viewport: CGRect = .zero
    @State private var followsUpdates = true
    @State private var pinnedToBottom = false
    /// The reader is at the end of the feed: coming to rest there attaches it again.
    @State private var atEnd = true
    @State private var contentHeight: CGFloat = 0
    @Environment(\.scenePhase) private var scenePhase

    private struct CardGeometry: Equatable {
        var card: UInt64
        var frame: CGRect
        var viewport: CGRect
        var hasBody: Bool
        var active: Bool
    }

    var body: some View {
        // One block per subject, in the order the subjects came up. A better version takes
        // the place of the card it replaces; the earlier ones lie under it as a stack.
        let blocks = CardBlocks.blocks(from: core.cards)
        let cards = blocks.map(\.current)
        let focus = CardBlocks.focused(in: blocks)
        return ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: with estimated heights the feed jumped whenever a block grew or changed page.
                VStack(alignment: .leading, spacing: 24) {
                    if model.spoken == nil {
                        SectionLabel(title: "Listen", note: "what fits the conversation, stays here", prominent: true)
                            .padding(.horizontal, CardMetrics.inset)
                    }
                    // Spoken: the voice and what answers scroll with the cards, not in the fixed header.
                    if let spoken = model.spoken {
                        SpokenHarnessDetails(model: model, spoken: spoken)
                    }
                    if cards.isEmpty, model.spoken != nil {
                        // What the conversation is doing is said above; here only what the cards are for.
                        Text("What Listen says also appears here as a card, with its sources.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.horizontal, CardMetrics.inset)
                    } else if cards.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Listening").font(.title2.weight(.semibold))
                            Text(model.hasAnswers
                                ? "What fits the conversation appears here."
                                : "Nothing can appear yet: no model is available. Connect OpenRouter in Account.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                        .padding(.horizontal, CardMetrics.inset)
                    }
                    ForEach(blocks) { block in
                        CardStack(block: block, highlightsUpdates: true) { card, isCurrent in
                            AnswerRow(model: model, card: card, showsActions: isCurrent && block.id == focus?.id)
                        }
                        .id(block.id)
                        .onGeometryChange(for: CardGeometry.self) {
                            CardGeometry(card: block.current.id, frame: $0.frame(in: .global), viewport: viewport,
                                         hasBody: block.current.text.split(separator: "\n").count >= 2,
                                         active: scenePhase == .active)
                        } action: { sample in
                            model.cardLaidOut(sample.card, frame: sample.frame, viewport: sample.viewport,
                                              hasBody: sample.hasBody, sceneActive: sample.active)
                        }
                    }
                    if !model.checking.isEmpty, !cards.contains(where: { $0.start.triggerSegment.map(model.checking.contains) ?? false }) {
                        // A card is on its way: its place is there already, shimmering until the text comes.
                        VStack(alignment: .leading, spacing: CardMetrics.groupGap) {
                            Label("Checking on the web", systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                            SkeletonBar(width: 200, height: 12)
                            SkeletonBar(width: 420, height: 16)
                            SkeletonBar(width: 320, height: 14)
                        }
                        .shimmering()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(CardMetrics.inset)
                        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 24))
                        .settlesIntoPlace()
                        .transition(.opacity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Checking on the web")
                    }
                    if cards.contains(where: { $0.status == .streaming }) {
                        WorkingRow(label: "Working out an answer").padding(.horizontal, CardMetrics.inset).transition(.opacity)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .coordinateSpace(.named(SettlesIntoPlace.space))
                .padding(.horizontal, margin)
                .padding(.top, margin > 20 ? 20 : 8)
                .animation(.smooth(duration: 0.3), value: model.checking.isEmpty)
            }
            .accessibilityIdentifier(model.spoken != nil ? "spoken.answers" : "listen.answers")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewport = $0 }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                contentHeight = height
            }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.containerSize.height >= $0.contentSize.height - 24 } action: { _, end in
                atEnd = end
            }
            .onScrollPhaseChange { old, phase in
                // Only a reader's vertical scroll detaches the feed. Programmatic
                // positioning and a growing answer must not turn following off.
                if phase == .interacting {
                    followsUpdates = false
                    pinnedToBottom = false
                }
                // Scrolled back to the end by hand: the feed follows the latest cards again.
                if phase == .idle, old != .idle, !followsUpdates, atEnd {
                    followsUpdates = true
                    pinnedToBottom = true
                }
            }
            .scrollIndicators(.hidden)
            // The feed grows downwards from the top. A short feed that sat at the bottom moved as a
            // whole with every new line; anchored to the top, what is being read stays where it is
            // and only what lies below moves (measured on recorded frames, 15 November 2026).
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(pinnedToBottom ? .bottom : .top, for: .sizeChanges)
            .onChange(of: focus?.id, initial: true) {
                // Follow a change of subject, not every version of the subject
                // already being read. Otherwise each addition snaps the same
                // card back to the top while the reader follows its bullets.
                guard followsUpdates, let focus else { return }
                if model.spoken != nil, !pinnedToBottom { return }
                withTransaction(.withoutAnyAnimation) {
                    if pinnedToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                    else { proxy.scrollTo(focus.id, anchor: .top) }
                }
            }
            .onChange(of: contentHeight) {
                guard followsUpdates, pinnedToBottom else { return }
                withTransaction(.withoutAnyAnimation) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                // Shown only while the reader has scrolled away, as the jump-to-latest control in
                // Messages: one tap goes to the end and follows the latest cards again. Scrolling to
                // the end does the same; following needs no control of its own.
                ZStack {
                    if !cards.isEmpty, !followsUpdates {
                        Button {
                            followsUpdates = true
                            pinnedToBottom = true
                            // Without an animated scroll: that could be read back as the reader's own scrolling.
                            withTransaction(.withoutAnyAnimation) { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .accessibilityLabel("Go to the latest cards and follow them")
                        .accessibilityIdentifier("feed.followLatest")
                        .help("Follows the latest cards again. Scrolling to the end does the same.")
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.bottom, 12)
                .animation(.smooth(duration: 0.25), value: followsUpdates)
            }
        }
    }
}

private struct SectionLabel: View {
    let title: String
    let note: String
    var prominent = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title.uppercased()).font(prominent ? .footnote.weight(.bold) : .caption2.weight(.bold))
            Text(note).font(prominent ? .footnote : .caption2)
        }
        .foregroundStyle(prominent ? .secondary : .tertiary)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Input

/// What was heard. Fast and plentiful; on a phone only the last lines show
/// and older ones fade, on a wide screen the whole transcript scrolls.
private struct InputFeed: View {
    let model: SessionModel
    let compact: Bool
    private var core: SessionCore { model.core }

    var body: some View {
        let lines = compact ? Array(core.lines.suffix(2)) : core.lines
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Heard", note: compact ? "passing by" : "everything that was said")
            if compact {
                rows(lines)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            rows(lines)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: core.lines.last) {
                        withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .animation(.smooth(duration: 0.25), value: lines.map(\.id))
    }

    @ViewBuilder
    private func rows(_ lines: [SessionCore.Line]) -> some View {
        if lines.isEmpty {
            Text("Nothing heard yet.").font(.footnote).foregroundStyle(.tertiary)
        }
        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
            Group {
                switch line.content {
                case .audioGap(let frames):
                    Label("About \(max(1, Int(frames) / 10)) s of audio were lost here", systemImage: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                case .speech(let segment):
                    HeardRow(model: model, segment: segment, offersMe: index == lines.count - 1 || !compact)
                }
            }
            // On a phone the older lines fade: input is passing, not for reading back.
            .opacity(compact && index < lines.count - 1 ? 0.5 : 1)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

/// One heard sentence: who, then what, small.
private struct HeardRow: View {
    let model: SessionModel
    let segment: TranscriptSegment
    let offersMe: Bool

    private var isMine: Bool { model.core.isMine(segment) }

    private var who: String {
        if isMine { return "You" }
        switch segment.speaker {
        case .speaker(let number): return "\(number)"
        case .overlap: return "+"
        default: return "?"
        }
    }

    /// The voice is the speaker model's first guess, or still to come: shown quietly until the
    /// next sentence's analysis settles it. After the conversation every voice stands as it is.
    private var tentative: Bool { segment.voicePending && model.core.phase != .review }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if isMine {
                    SpeakerFigure(figure: .mine, style: .pixel, size: 22)
                } else if let voice = segment.voice {
                    let animal = Figure.forVoice(voice)
                    SpeakerFigure(figure: animal.figure, style: .pixel, size: 22, turn: animal.turn)
                } else {
                    Text(tentative ? "…" : who)
                        .font(.caption2.weight(.bold))
                        .frame(width: 22, height: 22)
                        .background(.quaternary, in: .circle)
                }
            }
            .saturation(tentative ? 0 : 1)
            .opacity(tentative ? 0.45 : 1)
            .animation(.smooth(duration: 0.4), value: tentative)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
            .accessibilityElement()
            .accessibilityLabel(isMine ? "You" : segment.speaker.title)
            .accessibilityValue(tentative ? "Speaker not certain yet" : "")
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.text)
                    .font(.footnote)
                    .lineLimit(model.core.phase == .review ? nil : 3)
                    .italic(!segment.isFinal)
                    .foregroundStyle(segment.isFinal ? .primary : .secondary)
                    .contentTransition(.interpolate)
                    .animation(.smooth(duration: 0.3), value: segment.text)
                if offersMe, let voice = segment.voice, segment.isFinal, !isMine, !model.core.automaticSuggestionsOn {
                    Button("This is me") { model.send(.thisIsMe(voice: voice)) }
                        .font(.caption)
                        .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shown while something is being worked out: words still arriving, or an
/// answer being written.
private struct WorkingRow: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 3
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .frame(width: 7, height: 7)
                            .opacity(0.3 + 0.7 * max(0, sin(phase - Double(index) * 0.8)))
                    }
                }
            }
            .accessibilityHidden(true)
            Text(label).font(.subheadline)
        }
        .foregroundStyle(.secondary)
    }
}

/// The answer: plain, large text, like an assistant reply.
private struct AnswerRow: View {
    let model: SessionModel
    let card: SessionCore.Card
    let showsActions: Bool

    private var isBeingRead: Bool { model.core.phase == .speakingAloud(cardID: card.id) }
    /// An earlier version in the stack is shown in full; only a card that failed is dimmed.
    private var isStale: Bool { card.status == .cancelled || card.status == .failed }

    /// The answer of this card's moment is being checked on the web.
    private var isChecking: Bool { card.start.triggerSegment.map(model.checking.contains) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardEvidenceBadge(card: card)
                Spacer()
                if card.start.sourceCard != nil, card.status != .superseded {
                    Text("Updated").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if card.start.style != .answer {
                Text(card.start.style.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            CardBody(
                text: card.text, dimmed: isStale, isWriting: card.status == .streaming,
                isUpdating: isChecking && !isStale && card.status != .superseded, focusText: card.start.focusText)
                .equatable()
            if isChecking, !isStale, card.status != .superseded {
                Label("Checking on the web", systemImage: "globe")
                    .font(.caption).foregroundStyle(.secondary)
                    .shimmering()
                    .transition(.opacity)
            }
            if let badge = card.status.badge {
                Text(badge).font(.caption).foregroundStyle(.tertiary)
            }
            if showsActions, card.status != .streaming {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        if model.spoken == nil, isBeingRead {
                            Button("Stop reading", systemImage: "speaker.slash.fill") { model.send(.stopReadingAloud) }
                                .labelStyle(.iconOnly)
                        } else if model.spoken == nil {
                            Button("Read aloud", systemImage: "speaker.wave.2.fill") { model.send(.readAloud(cardID: card.id)) }
                                .labelStyle(.iconOnly)
                                .disabled(model.core.phase != .listening)
                        }
                        Button("Shorter") { model.send(.cardAction(card.id, .shorter)) }
                        Button("Explain") { model.send(.cardAction(card.id, .explain)) }
                        Button("Go deeper") { model.send(.cardAction(card.id, .technicalDetail)) }
                        Button("Dismiss", systemImage: "xmark") { model.send(.cardAction(card.id, .dismiss)) }
                            .labelStyle(.iconOnly)
                    }
                    .font(.subheadline)
                    .buttonStyle(.glass)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }
}


/// When something above a row takes more room or less, the row does not jump to
/// its new place: it glides there. The row notes where it lies in the feed; when
/// that changes it first stays where it was, then moves with a spring.
struct SettlesIntoPlace: ViewModifier {
    static let space = "feed"
    @State private var lies: CGFloat?
    @State private var behind: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: behind)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.space)).minY } action: { now in
                defer { lies = now }
                guard let before = lies, abs(now - before) > 1, !reduceMotion else { return }
                // Still where it was, then on its way: several changes in a row add up.
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { behind += before - now }
                withAnimation(.spring(duration: 0.4, bounce: 0.1)) { behind = 0 }
            }
    }
}

extension View {
    func settlesIntoPlace() -> some View { modifier(SettlesIntoPlace()) }
}
