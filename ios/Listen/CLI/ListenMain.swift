import Foundation

/// Both interfaces run the same application binary, stores, signing identity and engine.
/// The terminal branch uses a windowless lifecycle and never enters the SwiftUI scene.
@main enum ListenMain {
    @MainActor static func main() {
        #if targetEnvironment(macCatalyst)
        if ProcessInfo.processInfo.arguments.contains("-cli") {
            ListenCLI.run()
            return
        }
        #endif
        ListenApp.main()
    }
}
