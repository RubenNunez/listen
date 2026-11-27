import SwiftUI

/// The orb, fed by the session's sound. The level and the signal change ten times a second,
/// and a view that reads them is evaluated again every time. Reading them here, and only
/// here, means the screen around the orb is not rebuilt with every frame of sound, which
/// on the main thread is time the orb's own frames would otherwise wait for.
struct SessionOrb: View {
    let model: SessionModel
    var speakers = 1
    var isActive = true
    var isVisible = true

    var body: some View {
        FluidOrb(morph: model.isSpeechLikely ? 1 : 0, level: model.level, waveform: model.waveform,
                 speakers: speakers, isActive: isActive, isVisible: isVisible)
    }
}
