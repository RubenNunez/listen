import Foundation

/// Structured terminal events preserve transcript revisions and card/block identity. All model
/// text stays data. Human output strips terminal control codes; JSON encodes them as text.
enum CLIOutput {
    static func speaker(_ label: SpeakerLabel) -> [String: Any] {
        switch label {
        case .me: ["kind": "me"]
        case .speaker(let number): ["kind": "speaker", "n": number]
        case .unknown: ["kind": "unknown"]
        case .overlap: ["kind": "overlap"]
        }
    }
    static func safe(_ text: String) -> String {
        String(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
    }

    static func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    static func event(_ event: ServerEvent) -> [String: Any] {
        func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
        switch event {
        case .state(let state, let reason): return ["type": "state", "state": state.rawValue, "reason": optional(reason?.rawValue)]
        case .transcript(let line):
            return ["type": "transcript", "id": line.segmentID, "revision": line.revision, "final": line.isFinal,
                    "voice": optional(line.voice), "speaker": speaker(line.speaker), "pending": line.voicePending,
                    "text": line.text, "start_ms": line.startMs, "end_ms": line.endMs]
        case .speakerMapping(let version, let me): return ["type": "speaker_mapping", "version": version, "me_voice": optional(me)]
        case .audioGap(let first, let frames): return ["type": "audio_gap", "first": first, "frames": frames]
        case .cardStarted(let card):
            return ["type": "card_started", "id": card.generationID, "block": card.blockID ?? card.generationID,
                    "kind": card.kind.rawValue, "style": card.style.rawValue, "source": optional(card.sourceCard),
                    "trigger": optional(card.triggerSegment), "meeting": card.meeting ?? false]
        case .cardDelta(let id, let text): return ["type": "card_delta", "id": id, "text": text]
        case .cardFinished(let id): return ["type": "card_finished", "id": id]
        case .cardSuperseded(let id, let by): return ["type": "card_superseded", "id": id, "by": by]
        case .cardCancelled(let id): return ["type": "card_cancelled", "id": id]
        case .cardError(let id, let code): return ["type": "card_error", "id": id, "code": code.rawValue]
        case .budget(let spent, let limit, let exhausted):
            return ["type": "budget", "spent_nanousd": spent, "limit_nanousd": limit, "exhausted": exhausted]
        case .error(let code): return ["type": "error", "code": code.rawValue]
        }
    }
}
