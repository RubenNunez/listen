import SwiftUI
import Testing
@testable import Listen

/// Renders the orb as a picture, for the icon of .listen files (`Tools/document-icon`). Runs only
/// when `ORB_OUT` names a folder; `LISTEN_ORB_FORM=sphere` and `LISTEN_ORB_TIME` hold its form.
@MainActor @Suite struct OrbPicture {
    @Test func rendersTheOrb() throws {
        guard let out = ProcessInfo.processInfo.environment["ORB_OUT"] else { return }
        let view = FluidOrb(morph: 0, level: 0, isActive: true)
            .frame(width: 340, height: 340)
            .padding(120)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        try #require(image.pngData()).write(to: URL(fileURLWithPath: out).appending(path: "orb-dark.png"))
    }
}
