import SwiftUI
import UIKit

struct LegalView: View {
    var body: some View {
        List {
            notice("Open-source license", resource: "LICENSE", extension: nil)
            notice("Project notices", resource: "NOTICE", extension: nil)
            notice("Third-party library licenses", resource: "ThirdPartyLicenses", extension: "txt")
            notice("Supertonic 3 model license (Open RAIL-M)", resource: "Supertonic3License", extension: "txt")
            notice("Libraries, models and connected services", resource: "THIRD_PARTY", extension: "md")
        }
        .navigationTitle("Licenses and notices")
    }
    private func notice(_ title: String, resource: String, extension ext: String?) -> some View {
        NavigationLink(title) {
            LicenseText(text: Bundle.main.url(forResource: resource, withExtension: ext)
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "This notice is unavailable in this build.")
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// UIKit lays out large license texts without a single oversized SwiftUI Text tree.
private struct LicenseText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false; view.isSelectable = true
        view.font = .preferredFont(forTextStyle: .footnote)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .init(top: 20, left: 16, bottom: 20, right: 16)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
}
