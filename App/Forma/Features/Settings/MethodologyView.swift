import SwiftUI
import FormaCore
import FormaFeatures

/// Lists every metric specification. Rendered directly from the analytics catalog, so the
/// documentation shown here is the same object the code uses.
struct MethodologyListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(model.metricSpecs) { spec in
            NavigationLink {
                MethodologyDetailView(spec: spec)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name)
                    Text("\(statusText(spec.status)) · version \(spec.version)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .navigationTitle("Methodology")
    }
}

/// Sheet wrapper used by "How this is calculated" buttons.
struct MethodologyDetailSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let specID: String

    var body: some View {
        NavigationStack {
            Group {
                if let spec = model.metricSpecs.first(where: { $0.id == specID }) {
                    MethodologyDetailView(spec: spec)
                } else {
                    Text("No methodology entry for \(specID).").padding()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct MethodologyDetailView: View {
    let spec: MetricSpec

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: statusText(spec.status))
                LabeledContent("Unit", value: spec.unit)
                LabeledContent("Version", value: "\(spec.version)")
                LabeledContent("Identifier", value: spec.id)
                    .font(.caption.monospaced())
            }
            Section("Method") { Text(spec.method) }
            Section("Window") { Text(spec.windowing) }
            if let baseline = spec.baseline {
                Section("Baseline") { Text(baseline) }
            }
            Section("Required inputs") { ForEach(spec.requiredInputs, id: \.self) { Text($0) } }
            Section("Quality gates") { ForEach(spec.qualityGates, id: \.self) { Text($0) } }
            Section("Limitations") { ForEach(spec.limitations, id: \.self) { Text($0) } }
            if !spec.references.isEmpty {
                Section("References") { ForEach(spec.references, id: \.self) { Text($0).font(.footnote) } }
            }
        }
        .navigationTitle(spec.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

func statusText(_ status: MetricStatus) -> String {
    switch status {
    case .measured: return "Measured by the band"
    case .estimate: return "Forma estimate (documented method)"
    case .experimental: return "Experimental (Forma-defined)"
    }
}
