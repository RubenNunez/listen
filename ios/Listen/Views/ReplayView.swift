import AVFoundation
import SwiftUI

/// A recorded conversation gone through again: above, the table as it lay at the
/// chosen moment; below, the timeline with a line where that moment is. Play it
/// (Space plays and pauses), drag the slider or the playhead's handle through it,
/// click anywhere on the strip, and from any moment carry on:
/// the conversation starts again with the blocks that were on the table then.
struct ReplayView: View {
    let folder: URL
    /// Starts a conversation in the run's topic with these blocks on the table.
    let carryOn: (_ topic: String, _ blocks: [[String]]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = ReplayController()
    @State private var projection = ReplayProjection()
    @State private var loaded = false
    @State private var observer: UUID?
    @State private var voiceHistory = AssistantHistory()

    private func clock(_ seconds: Double) -> String { "\(Int(seconds) / 60):" + String(format: "%02d", Int(seconds) % 60) }

    var body: some View {
        // A run exported out of Listen, or never written completely: say so, instead of an
        // empty table and an empty strip.
        if FileManager.default.fileExists(atPath: folder.appending(path: "events.jsonl").path) {
            replay
        } else {
            ContentUnavailableView {
                Label("This conversation is not here any more", systemImage: "shippingbox")
            } description: {
                Text("Its recording was moved, for example exported out of Listen (runs/exports), or it was never written completely.")
            } actions: {
                Button("Close") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var replay: some View {
        VStack(spacing: 0) {
            if !voiceHistory.entries.isEmpty {
                AssistantReplayView(history: voiceHistory, controller: controller)
            } else {
                ReplayTable(controller: controller, projection: projection)
            }
            ReplayControls(controller: controller, carryOn: {
                let blocks = projection.timeline.blocks(at: controller.moment).map { $0.versions.map(\.text).filter { !$0.isEmpty } }
                dismiss()
                carryOn(projection.timeline.topic, blocks)
            })
            TimelinePanel(share: 0.42) {
                if loaded {
                    RunTimelineView(initial: folder, live: nil, onClose: { dismiss() },
                                    replay: controller, snapshot: projection.timeline)
                } else {
                    ProgressView("Loading recording…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: folder) {
            loaded = false
            controller.stop()
            if let observer { controller.removeTimeObserver(observer) }
            let (reading, history) = await Task.detached(priority: .userInitiated) {
                (RunTimeline(folder: folder), AssistantHistory(folder: folder))
            }.value
            guard !Task.isCancelled else { return }
            projection.configure(reading)
            voiceHistory = history
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            let audio = try? AVAudioPlayer(contentsOf: folder.appending(path: "audio.wav"))
            audio?.prepareToPlay()
            controller.configure(length: reading.length, soundBegins: reading.soundBegins, audio: audio)
            let projection = projection
            observer = controller.observeTime { [weak projection] time, manual in projection?.move(to: time, manual: manual) }
            loaded = true
        }
        // This observes the current phase. The async loader must not restore the
        // phase it captured before awaiting disk I/O (often still inactive at launch).
        .onChange(of: scenePhase, initial: true) { _, phase in controller.setActive(phase == .active) }
        .onDisappear {
            controller.stop()
            if let observer { controller.removeTimeObserver(observer) }
            observer = nil
        }
    }
}

private struct ReplayTable: View {
    let controller: ReplayController
    let projection: ReplayProjection
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(spacing: 0) {
                    cards
                    DisclosureGroup("Heard") {
                        ScrollView { transcript }.frame(maxHeight: 120)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    cards
                    ScrollView { transcript }
                        .defaultScrollAnchor(.bottom)
                        .frame(width: 300)
                        .background(.quaternary.opacity(0.35))
                }
            }
        }
        .frame(maxHeight: .infinity)
        .transaction { transaction in
            guard controller.seeking else { return }
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private var cards: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if projection.blocks.isEmpty {
                            Text("Nothing on the table yet at the selected moment.").foregroundStyle(.secondary).padding(CardMetrics.inset)
                        }
                        ForEach(projection.blocks) { block in
                            // A moment chosen by hand turns every block to its newest version of
                            // that moment; playing on leaves a page the reader turned to alone.
                            CardStack(block: block, seeks: controller.seekGeneration) { card, _ in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        CardEvidenceBadge(card: card)
                                        Spacer()
                                        if card.start.sourceCard != nil, card.status != .superseded {
                                            Text("Updated").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    CardBody(text: card.text, focusText: card.start.focusText).equatable()
                                }
                            }.settlesIntoPlace()
                        }
                    }
                    .coordinateSpace(.named(SettlesIntoPlace.space))
                    .frame(maxWidth: CardMetrics.column, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .animation(.smooth(duration: 0.3), value: projection.blocks.count)
                }
                .defaultScrollAnchor(.top)
    }

    private var transcript: some View {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("HEARD").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(projection.heard.suffix(14)) { sentence in
                            Text((sentence.voice.map { "[\($0)] " } ?? "") + sentence.text).font(.footnote).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)

    }
}

private struct ReplayControls: View {
    let controller: ReplayController
    let carryOn: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .compact {
                VStack(spacing: 8) {
                    HStack(spacing: 12) { play; ReplayPositionSlider(controller: controller) }
                    HStack(spacing: 12) {
                        follow
                        sound
                        speed
                        Menu { Button("Carry on from here", systemImage: "arrow.turn.down.right", action: carryOn) }
                            label: { Label("Replay actions", systemImage: "ellipsis.circle") }
                            .labelStyle(.iconOnly)
                    }
                }
            } else {
                HStack(spacing: 14) {
                    play
                    ReplayPositionSlider(controller: controller)
                    follow
                    sound
                    speed
                    Button("Carry on from here", systemImage: "arrow.turn.down.right", action: carryOn)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var play: some View {
        Button(controller.playing ? "Pause" : "Play", systemImage: controller.playing ? "pause.fill" : "play.fill", action: controller.togglePlayback)
            .labelStyle(.iconOnly)
            .listenPrimaryAction()
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("replay.play")
            .help(controller.playing ? "Pause (Space)" : "Play (Space)")
            .disabled(controller.length <= 0)
    }

    private var follow: some View {
        Button("Follow", systemImage: controller.follows ? "location.fill" : "location", action: controller.toggleFollow)
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .tint(controller.follows ? .accentColor : nil)
            .accessibilityIdentifier("replay.follow")
            .accessibilityValue(controller.follows ? "Following" : "Detached")
            .disabled(controller.scrubbing)
            .help(controller.follows ? "The timeline moves along with the moment" : "Follow the moment again")
    }

    private var sound: some View {
        Button(controller.sound ? "Sound on" : "Sound off", systemImage: controller.sound && controller.speed <= 2 ? "speaker.wave.2.fill" : "speaker.slash.fill") {
            controller.setSound(!controller.sound)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .disabled(controller.speed > 2)
        .help(controller.speed > 2 ? "At five times the speed the replay is silent" : "Plays the recording along with the replay")
    }

    private var speed: some View {
        Picker("Speed", selection: Binding(get: { controller.speed }, set: controller.setSpeed)) {
            Text("1×").tag(1.0)
            Text("2×").tag(2.0)
            Text("5×").tag(5.0)
        }
        .pickerStyle(.segmented)
        .frame(width: 140)
    }
}

private struct ReplayPositionSlider: View {
    let controller: ReplayController
    private func clock(_ seconds: Double) -> String { "\(Int(seconds) / 60):" + String(format: "%02d", Int(seconds) % 60) }
    var body: some View {
        HStack(spacing: 8) {
            Text(clock(controller.moment)).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
            Slider(value: Binding(get: { controller.moment }, set: {
                if controller.scrubbing { controller.preview($0, source: .slider) }
                else { controller.seek(to: $0) }
            }), in: 0...max(0.001, controller.length), onEditingChanged: { editing in
                if editing { controller.beginScrub(.slider) } else { controller.endScrub(.slider) }
            })
            .accessibilityLabel("Replay position")
            .accessibilityIdentifier("replay.slider")
            .disabled(controller.length <= 0)
            Text(clock(controller.length)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
