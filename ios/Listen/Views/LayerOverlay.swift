import SwiftUI

/// Debug overlay: for each sentence, what every listening layer did and how
/// long it took. All numbers are measured in this session on this device.
struct LayerOverlay: View {
    let model: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                Text("\(model.traces.count) sentences").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let status = model.stageStatus.last {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if model.traces.isEmpty {
                Text("Nothing heard yet.").font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.traces) { trace in row(trace).id(trace.id) }
                    }
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.traces.last) { _, last in
                    if let last { withAnimation(.smooth) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: 300)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Layers")
    }

    private func row(_ trace: LayerTrace) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(trace.text)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            ForEach(Array(trace.steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.changed ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(step.name).font(.caption2.weight(.semibold)).frame(width: 118, alignment: .leading)
                    Text(step.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let seconds = step.seconds {
                        Text(String(format: "%.2f s", seconds)).font(.caption2.monospacedDigit())
                    }
                }
            }
            Text(String(format: "%.1f s of sound", trace.audioSeconds))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}
