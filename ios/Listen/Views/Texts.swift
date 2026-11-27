import Foundation

extension SpeakerLabel {
    var title: String {
        switch self {
        case .me: "Me"
        case .speaker(let n): "Speaker \(n)"
        case .unknown: "Unknown"
        case .overlap: "Overlap"
        }
    }

    /// Unknown and overlapping speech is shown dimmed: the attribution is not reliable.
    var isUncertain: Bool { self == .unknown || self == .overlap }
}

extension SessionCore.InterruptionReason {
    var explanation: String {
        switch self {
        case .audioSession: "Another app or a call took the microphone."
        case .routeChange: "The audio device changed."
        case .mediaReset: "The system audio service restarted."
        case .leftForeground: "Listen left the foreground or the screen locked."
        case .connectionLost: "The connection to the backend was lost."
        case .captureFailed: "The microphone could not be started."
        }
    }
}

extension SessionCore.Phase {
    var title: String {
        switch self {
        case .idle: "Ready"
        case .starting: "Starting…"
        case .listening: "Listening"
        case .pausedByUser: "Paused"
        case .interrupted: "Interrupted"
        case .reconnecting: "Reconnecting…"
        case .speakingAloud: "Reading aloud"
        case .review: "Review"
        }
    }
}

extension SessionCore.Notice {
    var message: String {
        switch self {
        case .microphoneDenied: "Microphone access is off. Allow it for Listen in Settings."
        case .notConnected: "Not connected to the backend."
        case .budgetExhausted: "The session budget is used up. The transcript continues without suggestions."
        case .replayGap: "Some events were lost while disconnected. The transcript may have a hole."
        case .server(.modelProvider): "No answer this time: no model is attached, or it had nothing to add. Models are attached in Account."
        case .server(.speechProvider): "Transcription failed on this device."
        case .server(let code): "The backend reported: \(code.rawValue)."
        }
    }
}

extension CardStyle {
    var title: String {
        switch self {
        case .answer: "Suggestion"
        case .shorter: "Shorter"
        case .explain: "Explanation"
        case .technicalDetail: "Technical detail"
        }
    }
}

extension SessionCore.Card.Status {
    var badge: String? {
        switch self {
        case .streaming: "Writing…"
        case .finished: nil
        case .superseded: "Superseded by a newer question"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }
}
