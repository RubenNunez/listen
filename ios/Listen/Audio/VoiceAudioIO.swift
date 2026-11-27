import AVFoundation

/// The active conversation's voice-processing graph. Native reply buffers use this same
/// output, so the microphone's echo canceller has the actual playback reference. Owning
/// capture still belongs to AudioCapture; merely creating a speaker opens no input.
@MainActor enum VoiceAudioIO {
    private(set) static weak var engine: AVAudioEngine?
    private static var retired: [AVAudioNode] = []

    static func began(_ engine: AVAudioEngine) { self.engine = engine }
    static func ended(_ engine: AVAudioEngine) {
        if self.engine === engine {
            // The capture owner stops rendering first. Reconfiguring a live VPIO
            // graph during voice replacement raised RemoveNode on Catalyst.
            for node in retired where node.engine === engine { engine.detach(node) }
            retired.removeAll()
            self.engine = nil
        }
    }

    static func reuse(_ node: AVAudioNode) {
        var kept: [AVAudioNode] = []
        for candidate in retired where candidate !== node { kept.append(candidate) }
        retired = kept
    }

    static func retire(_ node: AVAudioNode, from owner: AVAudioEngine) {
        guard node.engine === owner else { return }
        if owner === engine, owner.isRunning {
            for candidate in retired where candidate === node { return }
            retired.append(node)
        } else {
            owner.stop()
            owner.detach(node)
        }
    }
}
