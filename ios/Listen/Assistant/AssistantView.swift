import SwiftUI

/// The talk screen: the orb, what it is doing, and the reply. Nothing to type and no
/// buttons to manage the session: tap the orb to interrupt it or to carry on after a pause,
/// and the cross ends the conversation and goes back.
struct AssistantView: View {
    let model: SessionModel
    let assistant: VoiceAssistantSession
    @State private var orbOnScreen = true
    /// The height the content fills at least, so the orb stays centred above a short reply.
    @State private var viewport: CGFloat = 0
    /// The reply is on screen: it fades in with its voice and out again after it.
    @State private var replyShown = false
    @State private var revealClock = ReplyRevealClock()
    @State private var showsVoiceSettings = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A question is out and its answer cannot be heard yet: the thinking sound plays, unless
    /// the person is speaking again.
    private var waiting: Bool {
        !ended && !assistant.paused && assistant.configuration.speakReplies && !assistant.hearing
            && !assistant.audible
            && (assistant.thinking || (assistant.speaking && !assistant.audible))
            // "Ich schaue das nach." is heard instead of the sound, not over it.
            && !(assistant.acknowledging && assistant.audible)
    }
    private var ended: Bool { model.core.phase == .review }
    /// A session that ended with a problem stays on screen, so the problem can be read.
    private var problem: String? { model.captureError ?? assistant.failure }
    private var status: String {
        if ended { return "Conversation ended" }
        if model.core.phase == .starting { return "Preparing microphone and speech recognition" }
        if model.core.phase == .reconnecting { return "Reconnecting speech recognition" }
        if case .interrupted = model.core.phase { return "Audio interrupted · tap the orb to go on" }
        if assistant.paused { return "Paused · tap the orb to go on" }
        if !assistant.ready { return "Preparing conversation" }
        if !assistant.pending.isEmpty { return assistant.language == .de ? "Bestätigung nötig" : "Confirmation needed" }
        // Said only on the provider's report of a search; the reply itself is not out yet.
        if assistant.researching { return "Searching the web · tap the orb to cancel" }
        if assistant.acknowledging { return "Preparing an answer · tap the orb to interrupt" }
        if assistant.speaking {
            return assistant.listensWhileSpeaking ? "Listening · speak to interrupt" : assistant.audible ? "Speaking · tap the orb to interrupt" : "Preparing the voice"
        }
        if assistant.settling && !assistant.listensWhileSpeaking { return "Listening in a moment" }
        if assistant.thinking { return "Thinking" }
        return "Listening"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 24)
                Button(action: tapOrb) {
                    SessionOrb(model: model, isActive: !ended && !assistant.paused, isVisible: orbOnScreen)
                        .frame(width: 240, height: 240)
                        .onScrollVisibilityChange(threshold: 0.05) { orbOnScreen = $0 }
                }
                    .buttonStyle(.plain)
                    .contentShape(.circle)
                    .accessibilityLabel(status)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("assistant.orb")
                Text(status)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .accessibilityIdentifier("assistant.status")
                    .padding(.top, 18)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.3), value: status)
                Spacer(minLength: 32)
                VStack(alignment: .leading, spacing: 16) {
                    if replyShown, !assistant.lastReply.isEmpty {
                        if reduceMotion {
                            Text(assistant.lastReply).font(.title3).textSelection(.enabled)
                                .accessibilityIdentifier("assistant.reply")
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: assistant.replyWasInterrupted)) { _ in
                                Text(assistant.lastReply).font(.title3).textSelection(.enabled)
                                    .accessibilityIdentifier("assistant.reply")
                                    .textRenderer(ReplyReveal(revealed: revealClock.position(at: ProcessInfo.processInfo.systemUptime),
                                                              length: Double(assistant.lastReply.count), wordStarts: revealClock.wordStarts,
                                                              limit: assistant.replyPlaybackEnded ? nil : assistant.replySpeechCharacters.map(Double.init)))
                            }
                            .transition(.opacity)
                        }
                    }
                    ForEach(assistant.pending, id: \.id) { request in permission(request) }
                    ForEach(assistant.localSequences) { sequence in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(assistant.language == .de ? "Befehlsfolge läuft" : "Sequence running", systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Button(assistant.language == .de ? "Abbrechen" : "Cancel") { assistant.cancelLocalSequence(sequence.id) }
                                    .buttonStyle(.bordered)
                            }
                            Text(sequence.request).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            if let end = sequence.waitingUntil {
                                Text(timerInterval: min(Date(), end)...end, countsDown: true)
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .accessibilityLabel(assistant.language == .de ? "Wartezeit" : "Waiting")
                            }
                            Text(assistant.language == .de ? "Nur während dieses Gesprächs. Ein neuer Gerätebefehl, Pause oder Gesprächsende beendet die Folge." : "During this conversation only. A new device command, pause or ending the conversation stops the sequence.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityIdentifier("assistant.localSequence")
                    }
                    sources
                    if let detail = assistant.lastToolDetail {
                        DisclosureGroup(assistant.language == .de ? "Technische Details" : "Technical details") {
                            Text(Self.formatted(detail)).font(.caption.monospaced())
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 8)
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("assistant.tool.details")
                        .id(assistant.lastReplyID)
                    }
                    notices
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: assistant.pending.map(\.id))
                if model.isRecording {
                    Label("Recording on this device", systemImage: "record.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
            .frame(maxWidth: 600, minHeight: viewport)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        #if targetEnvironment(macCatalyst)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                AssistantVoiceMenu(current: assistant.voice, language: assistant.language, preview: assistant.preview,
                                   canSample: !assistant.paused,
                                   canPreviewPulse: !assistant.speaking && !assistant.hearing,
                                   choose: { try assistant.chooseVoice($0) }, sample: { assistant.playSample() })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(ended || !assistant.ready || model.core.phase == .starting || model.core.phase == .reconnecting)
                Button("End conversation", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                    .accessibilityIdentifier("assistant.close")
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            .background(.bar)
        }
        #else
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
            Button("End conversation", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
                .frame(width: 44, height: 44)
                .accessibilityIdentifier("assistant.close")
            Spacer()
            ListenSettingsButton(identifier: "assistant.settings") { showsVoiceSettings = true }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
        }
        .sheet(isPresented: $showsVoiceSettings) {
            LiveVoiceSettings(configuration: assistant.configuration, language: assistant.language,
                preview: assistant.preview, canSample: !assistant.paused,
                canPreviewPulse: !assistant.speaking && !assistant.hearing,
                choose: { try assistant.chooseVoice($0) }, sample: { assistant.playSample() })
        }
        #endif
        .task(id: ReplyMoment(response: assistant.lastReplyID, text: assistant.lastReply, speaking: assistant.speaking, audible: assistant.audible, flowing: assistant.voiceFlowing, interrupted: assistant.replyWasInterrupted, speechCharacters: assistant.replySpeechCharacters, playbackEnded: assistant.replyPlaybackEnded)) {
            await fadeReply()
        }
        .thinkingCue(while: waiting)
        .onChange(of: ended) { _, ended in
            // Ended by the cross, or by saying stop: back to where the conversation began.
            if ended, problem == nil { model.send(.done) }
        }
    }

    /// What the provider reported for the last reply: the pages it cited, to open, and
    /// whether it searched at all. They stay until the next reply begins; the voice never
    /// reads them. A reply without a reported search shows nothing here.
    @ViewBuilder private var sources: some View {
        if !assistant.lastSources.isEmpty || assistant.lastWebSearches > 0 {
            VStack(alignment: .leading, spacing: 6) {
                Text(assistant.lastSources.isEmpty ? "Searched the web · no page cited" : "Sources")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(assistant.lastSources, id: \.self) { source in
                    Link(destination: source) {
                        Label(source.host() ?? source.absoluteString, systemImage: "link").lineLimit(1)
                    }
                    .font(.footnote)
                    .accessibilityHint(source.absoluteString)
                }
            }
            .accessibilityIdentifier("assistant.sources")
        }
    }

    @ViewBuilder private var notices: some View {
        if let problem { Text(problem).foregroundStyle(.orange) }
        if let permissionFailure = assistant.permissionFailure { Text(permissionFailure).foregroundStyle(.orange) }
        if assistant.parallelOpeningUnavailable {
            Text(assistant.language == .de ? "Paralleler Einstieg nicht verfügbar: Verbinde JEV und wähle ein anderes schnelles Modell in den Systemeinstellungen."
                 : "Parallel opening unavailable: connect JEV and select a different fast model in system settings.")
                .font(.caption).foregroundStyle(.orange)
        }
        if assistant.webSearchUnavailable {
            Text("Web search is switched on for this system, but its model's connection cannot search. Replies come without it.")
                .font(.caption).foregroundStyle(.orange)
        }
        LocalVoiceNotice(configuration: assistant.configuration, compact: true)
        if case .server(.speechProvider) = model.core.notice {
            Text("Speech recognition is unavailable. Check the device's speech model and try again.").foregroundStyle(.orange)
        }
        if !assistant.missing.isEmpty {
            Text("Unavailable tools: " + assistant.missing.joined(separator: ", ")).font(.caption).foregroundStyle(.orange)
        }
    }

    private func permission(_ request: ConversationOperationRequest) -> some View {
        AssistantPermissionCard(request: request,
            toolName: assistant.tools.first { $0.capability == request.capability }?.descriptor.name,
            language: assistant.language,
            allow: { remember in assistant.decide(request, allow: true, alwaysAllow: remember) }, deny: { assistant.decide(request, allow: false) })
    }

    private static func formatted(_ raw: String) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: Data(raw.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return raw }
        return text
    }

    /// Shows the reply while its voice plays, flowing in at the pace of speech, and fades it
    /// out two seconds after. While the voice is still getting ready the reply waits; a reply
    /// that is never heard comes in quickly and stays long enough to be read.
    private func fadeReply() async {
        let text = assistant.lastReply
        guard !text.isEmpty else { show(false); revealClock = ReplyRevealClock(); return }
        // Don't run a silent animation during initial voice loading. Once speech has begun,
        // pauses between streamed sentences keep the same visible text and clock.
        if assistant.speaking && !assistant.audible && assistant.lastReplyID != revealClock.response {
            show(false)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        revealClock.update(text: text, response: assistant.lastReplyID, audible: assistant.audible,
                           running: !assistant.speaking || assistant.voiceFlowing, interrupted: assistant.replyWasInterrupted,
                           speechCharacters: assistant.replySpeechCharacters, playbackEnded: assistant.replyPlaybackEnded, at: now)
        // Cut off before any of it was revealed (the voice was still getting ready): the
        // frozen prefix is empty. Showing it would only keep an invisible block on screen
        // whose unheard text VoiceOver could still read.
        if assistant.replyWasInterrupted && revealClock.position(at: now) <= 0 {
            show(false)
            return
        }
        show(true)
        guard !assistant.speaking else { return }
        let hold = revealClock.heard ? 2 : max(4, Double(text.count) / 15)
        try? await Task.sleep(for: .seconds(max(0, revealClock.endsAt - now) + hold))
        if !Task.isCancelled { show(false) }
    }

    private func show(_ shown: Bool) {
        guard replyShown != shown else { return }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.5)) { replyShown = shown }
    }

    /// Interrupts the reply, or carries on after a pause or an interruption.
    private func tapOrb() {
        guard !ended else { return }
        if assistant.paused { model.send(.resume) } else { assistant.interrupt() }
    }

    /// Stops and saves; once stopped, the session leaves by itself (`onChange(of: ended)`).
    private func close() {
        if ended { model.send(.done) } else { model.stopAndSave() }
    }
}

private struct AssistantPermissionCard: View {
    let request: ConversationOperationRequest
    let toolName: String?
    let language: Language
    let allow: (Bool) -> Void
    let deny: () -> Void
    @State private var expanded = false
    @State private var alwaysAllow = false

    private var german: Bool { language == .de }
    private var light: Bool {
        ["HassTurnOn", "HassTurnOff"].contains(toolName ?? "") && request.arguments["domain"] == .array([.string("light")])
            && Set(request.arguments.keys).isSubset(of: ["name", "area", "floor", "domain", "device_class"])
    }
    private var turningOff: Bool { toolName == "HassTurnOff" }
    private var title: String {
        guard light else { return german ? "Aktion ausführen?" : "Allow this action?" }
        return turningOff ? (german ? "Lichter ausschalten?" : "Switch off the lights?")
            : (german ? "Lichter einschalten?" : "Switch on the lights?")
    }
    private var target: String {
        let names = ["name", "area", "floor", "device_class"]
        let named = names.compactMap { key -> String? in
            guard let value = request.arguments[key] else { return nil }
            let label: String
            switch key {
            case "name": label = german ? "Licht" : "Light"
            case "area": label = german ? "Bereich" : "Area"
            case "floor": label = german ? "Etage" : "Floor"
            default: label = german ? "Geräteklasse" : "Device class"
            }
            return "\(label): \(Self.label(value))"
        }
        if !named.isEmpty { return named.joined(separator: " · ") }
        return light ? (german ? "Alle Lichter" : "All lights") : request.capability.rawValue
    }
    private static func label(_ value: ConversationValue) -> String {
        switch value {
        case .string(let text): return text
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        case .array(let values): return values.map(label).joined(separator: ", ")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: light ? (turningOff ? "lightbulb.slash" : "lightbulb") : "checkmark.shield")
                    .font(.system(size: 21, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(.primary.opacity(0.06), in: .rect(cornerRadius: 15))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(german ? "BESTÄTIGUNG" : "CONFIRMATION")
                        .font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
                    Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(target).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !light {
                ForEach(request.arguments.keys.sorted(), id: \.self) { key in
                    if let value = request.arguments[key] {
                        Text("\(key): \(Self.label(value))").font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(request.capability.rawValue).fontWeight(.medium)
                    Text(String(decoding: (try? JSONEncoder().encode(request.arguments.mapValues(\.harness))) ?? Data(), as: UTF8.self))
                }
                .font(.caption.monospaced()).textSelection(.enabled).padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text(german ? "Details zur Aktion" : "Action details")
            }
            .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Toggle(german ? "Für dieses Werkzeug immer erlauben" : "Always allow this tool", isOn: $alwaysAllow)
                    .font(.subheadline).toggleStyle(.switch)
                    .accessibilityIdentifier("assistant.action.alwaysAllow")
                if alwaysAllow {
                    Text(german
                         ? "Gilt für alle Ziele von \(request.capability.rawValue) auf diesem Gerät. Änderbar unter Einstellungen → Connections."
                         : "Applies to every target of \(request.capability.rawValue) on this device. Change it in Settings → Connections.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().opacity(0.5)
            HStack(spacing: 12) {
                Button(role: .cancel, action: deny) {
                    Text(german ? "Abbrechen" : "Cancel").frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.bordered).accessibilityIdentifier("assistant.action.deny")
                Button { allow(alwaysAllow) } label: {
                    Text(light ? (turningOff ? (german ? "Ausschalten" : "Switch off") : (german ? "Einschalten" : "Switch on"))
                         : (german ? "Bestätigen" : "Confirm"))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .listenPrimaryAction().accessibilityIdentifier("assistant.action.allow")
            }
            .controlSize(.large).buttonBorderShape(.capsule)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
        .accessibilityIdentifier("assistant.action.card")
    }
}

/// What decides whether the reply is on screen.
private struct ReplyMoment: Hashable {
    var response: ConversationResponseID?
    var text: String
    var speaking: Bool
    var audible: Bool
    var flowing: Bool
    var interrupted: Bool
    var speechCharacters: Int?
    var playbackEnded: Bool
}
