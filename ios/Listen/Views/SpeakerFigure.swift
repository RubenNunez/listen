import SwiftUI

/// The little animal that stands for one voice. Eight animals in three drawn
/// styles, each with its place: pixel beside text, soft 3D where people are
/// shown, sticker in menus. Generated artwork; sources and prompts are in
/// `design/figures/animals`.
enum Figure: String, CaseIterable, Identifiable {
    case fox, whale, snail, hedgehog, owl, octopus, bat, frog

    enum Style: String {
        /// Inside running text.
        case pixel
        /// Where the people of a conversation are shown.
        case soft
        /// Menus and settings.
        case sticker
    }

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The figure the user chose for themselves.
    static var mine: Figure {
        Figure(rawValue: UserDefaults.standard.string(forKey: "myFigure") ?? "") ?? .fox
    }

    /// The animal for a voice number, and how far its colour is turned. The
    /// user's own animal is left out; from the eighth other voice on, the
    /// animals come round again in a new colour.
    static func forVoice(_ voice: UInt32, mine: Figure = .mine) -> (figure: Figure, turn: Double) {
        let others = allCases.filter { $0 != mine }
        let index = Int(max(voice, 1)) - 1
        return (others[index % others.count], Double(index / others.count) * 70)
    }
}

struct SpeakerFigure: View {
    let figure: Figure
    let style: Figure.Style
    var size: CGFloat = 28
    /// Degrees the colours are turned, to tell a reused animal apart.
    var turn = 0.0

    var body: some View {
        Image("figure-\(style.rawValue)-\(figure.rawValue)")
            .resizable()
            .interpolation(style == .pixel ? .none : .high)
            .scaledToFit()
            .frame(width: size, height: size)
            .hueRotation(.degrees(turn))
            .accessibilityHidden(true)
    }
}
