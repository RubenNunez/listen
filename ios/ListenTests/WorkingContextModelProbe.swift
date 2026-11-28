import Foundation
import Testing
@testable import Listen

/// Explicit opt-in: typed synthetic tasks through the existing signed-in model adapter.
/// No microphone, synthesis, tools, private topic, real document or device is used.
@MainActor @Suite struct WorkingContextModelProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LISTEN_WORKING_CONTEXT_PROBE"] == "1"), .timeLimit(.minutes(3)))
    func retainedContextComparedWithRecentHistoryOnly() async throws {
        try #require(AudioCapture.physicalInputDisabled && TalkBack.muted)
        let output = try #require(ProcessInfo.processInfo.environment["LISTEN_WORKING_CONTEXT_OUT"])
        try #require(output.contains("/runs/"))
        let client = AssistantDeadlineClient(base: ResponsesClient(), timeout: .seconds(30))
        let configuration = VoiceAssistantConfiguration(enabled: true)
        let cases: [(name: String, constraint: String, notes: String, latest: String)] = [
            ("writing", "Schreibe für Dana eine kurze Nachricht auf Deutsch in genau zwei Sätzen, ohne Ausrufezeichen. Sage, dass sich die Lieferung verzögert, aber verspreche kein Datum.", "A synthetic writing exercise, no real recipient or sending tool.", "Formuliere die besprochene Nachricht jetzt."),
            ("choice", "Option Pine kenne ich schon; die bitte ausschließen. Heute möchte ich etwas Ruhiges unter 15 Minuten. Nur Vorschläge, nichts starten.", "Synthetic catalog: Option Copper is loud, 30 minutes. Option Pine is quiet, 14 minutes. Option Cedar is quiet, 12 minutes. These are fictitious options, no external availability is known.", "Welche Option passt dann am besten?")
        ]
        var measurements: [[String: Any]] = []
        for item in cases {
            var messages: [HarnessValue] = [.object(["role": .string("user"), "text": .string(item.constraint)])]
            for index in 0..<20 {
                messages += [.object(["role": .string("user"), "text": .string("Synthetic unrelated detail \(index).")]),
                             .object(["role": .string("assistant"), "text": .string("Understood.")])]
            }
            messages.append(.object(["role": .string("user"), "text": .string(item.latest)]))
            for includeRetained in [false, true] {
                var fields: [String: HarnessValue] = ["topic": .object(["name": .string("Synthetic general assistant"), "notes": .string(item.notes), "language": .string("de")]),
                    "messages": .array(Array(messages.suffix(16))), "tools": .array([]), "recent_actions": .array([])]
                if includeRetained { fields["working_context"] = AssistantWorkingContext.payload(messages: messages, request: item.latest) }
                let input = String(decoding: try JSONEncoder().encode(HarnessValue.object(fields)), as: UTF8.self)
                let began = ProcessInfo.processInfo.systemUptime
                var firstText: Double?, raw = "", usage: TokenUsage?
                for try await chunk in client.stream(model: "chatgpt/gpt-6.1-sol",
                    system: configuration.replyInstructions(hasTools: false), user: input, maxTokens: 300) {
                    switch chunk {
                    case .text(let text):
                        if firstText == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { firstText = ProcessInfo.processInfo.systemUptime - began }
                        raw += text
                    case .usage(let value): usage = value
                    default: break
                    }
                }
                let response = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = response.lowercased()
                let passes: Bool
                if item.name == "writing" {
                    let sentences = response.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    passes = sentences.count == 2 && !response.contains("!") && lower.contains("dana")
                        && (lower.contains("liefer") || lower.contains("verzöger"))
                } else {
                    passes = lower.contains("cedar") && !lower.contains("ich starte") && !lower.contains("habe gestartet")
                }
                var result: [String: Any] = ["case": item.name, "retained_context": includeRetained,
                    "input_bytes": input.utf8.count, "response": response, "passes_task_rubric": passes,
                    "first_text_s": firstText as Any? ?? NSNull(), "completed_s": ProcessInfo.processInfo.systemUptime - began]
                if let usage { result["usage"] = usage.fields }
                measurements.append(result)
                if includeRetained { #expect(passes, "The new context must carry the stated task constraint") }
            }
        }
        let receipt: [String: Any] = ["measurement": "Four typed synthetic model calls; recent-history baseline versus retained quotation context. Tiny task-specific rubric, not voice latency, broad intelligence or a realtime-voice comparison.", "cases": measurements]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
