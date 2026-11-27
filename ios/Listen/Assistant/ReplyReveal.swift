import SwiftUI

/// Draws a reply from its first character on: each character rises a little out of a blur
/// as the reveal passes it, so the text flows in with the voice instead of appearing at once.
/// Characters the reveal has not reached are not drawn.
struct ReplyReveal: TextRenderer {
    /// How many characters are shown, fractional while it moves.
    var revealed: Double
    var length: Double
    /// How many characters a character takes to arrive.
    var spread = 8.0
    var wordStarts: [Double] = []
    var limit: Double?

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // A layout slice is not a String.Character (ligatures, emoji and combining marks).
        // Map the actual slices onto the clock's text units, including the final slice.
        let count = layout.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        var index = 0
        for line in layout {
            for run in line {
                for glyph in run {
                    defer { index += 1 }
                    let position = Double(index) / Double(max(1, count - 1)) * max(0, length - 1)
                    let arrived = Self.arrival(revealed: revealed, position: position, spread: spread, limit: limit)
                    guard arrived > 0 else { continue }
                    if arrived == 1 { context.draw(glyph); continue }
                    var copy = context
                    let eased = arrived * arrived * (3 - 2 * arrived)
                    copy.opacity = eased
                    copy.translateBy(x: 0, y: (1 - eased) * 2)
                    copy.addFilter(.blur(radius: (1 - eased) * 0.8))
                    copy.draw(glyph)
                }
            }
        }
    }

    static func arrival(revealed: Double, position: Double, spread: Double = 8, limit: Double? = nil) -> Double {
        if let limit, position >= limit { return 0 }
        return min(max((revealed - position) / spread, 0), 1)
    }

    static func end(length: Int) -> Double { Double(length) + 8 }

    /// Fallback when the voice has no sentence cues. Keep text a little ahead of
    /// conversational voices instead of assuming every synthesizer speaks at 15 cps.
    static let spokenRate = 32.0
    /// Characters a second for a reply nobody hears: quick, but still a movement.
    static let silentRate = 90.0
}

/// The presentation position, computed from elapsed time rather than SwiftUI's animation
/// target. Appended sentences continue from what is actually visible, and the fade waits
/// until the final blur has cleared. A new response resets even if its words are identical.
struct ReplyRevealClock {
    private(set) var response: ConversationResponseID?
    private(set) var text = ""
    private(set) var heard = false
    private(set) var endsAt = 0.0
    private(set) var wordStarts: [Double] = []
    private var began = 0.0
    private var from = 0.0
    private var target = 0.0
    private var rate = ReplyReveal.silentRate
    private var interrupted = false

    func position(at time: Double) -> Double {
        min(target, from + max(0, time - began) * rate)
    }

    mutating func update(text: String, response: ConversationResponseID?, audible: Bool, running: Bool = true, interrupted: Bool = false,
                         speechCharacters: Int? = nil, playbackEnded: Bool = false, at time: Double) {
        if self.response != response || !text.hasPrefix(self.text) || self.text.isEmpty {
            self = Self()
            self.response = response
        }
        heard = heard || audible
        if interrupted || self.interrupted {
            from = position(at: time)
            began = time
            target = from
            rate = 0
            endsAt = time
            self.interrupted = true
            self.text = text
            return
        }
        let visible = position(at: time)
        let length = heard && !playbackEnded ? speechCharacters.map { min(text.count, max(0, $0)) } ?? text.count : text.count
        let nextTarget = max(visible, ReplyReveal.end(length: length))
        let nextRate: Double
        if interrupted { nextRate = 0 }
        else if playbackEnded { nextRate = max(ReplyReveal.silentRate, (nextTarget - visible) / 0.18) }
        else if heard && !running { nextRate = 0 }
        else if heard && speechCharacters != nil {
            // Reveal the current spoken sentence smoothly and promptly. Queued future
            // sentences wait for their actual start; no guessed word timestamps.
            nextRate = max(ReplyReveal.spokenRate, (nextTarget - visible) / 0.45)
        } else { nextRate = heard ? ReplyReveal.spokenRate : ReplyReveal.silentRate }
        if nextTarget != target || nextRate != rate {
            from = visible
            began = time
            rate = nextRate
            target = nextTarget
            endsAt = rate > 0 ? time + max(0, target - from) / rate : time
        }
        if text != self.text {
            wordStarts = []
            var space = true
            for (offset, character) in text.enumerated() {
                if space && !character.isWhitespace { wordStarts.append(Double(offset)) }
                space = character.isWhitespace
            }
        }
        self.text = text
    }
}
