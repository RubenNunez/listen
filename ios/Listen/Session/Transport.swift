import Foundation

enum TransportEvent {
    case connected
    case disconnected
    case envelope(Envelope)
}

/// The connection to the session backend. The only implementation so far is
/// `DemoTransport`; the WebSocket transport arrives with the backend server.
@MainActor
protocol Transport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func connect()
    func disconnect()
    func send(_ event: ClientEvent)
    func sendAudio(_ frame: AudioFrame)
    /// The speaker has paused: finish recognising what was said so far now, rather than
    /// after the recogniser's own long pause.
    func endUtterance()
    func setInputMuted(_ muted: Bool)
}

extension Transport {
    func endUtterance() {}
    func setInputMuted(_ muted: Bool) {}
}
