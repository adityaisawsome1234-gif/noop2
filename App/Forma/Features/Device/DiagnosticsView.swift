import SwiftUI
import UniformTypeIdentifiers
import FormaCore
import FormaFeatures

/// Compatibility test and raw protocol diagnostics. This is the Phase B success screen: it shows
/// whether a real capture from the band exists and lets the user export it for replay.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var exportDocument: CaptureDocument?
    @State private var exportError: String?

    var body: some View {
        let state = model.diagnostics
        List {
            Section {
                Button {
                    Task { await model.runCompatibilityTest() }
                } label: {
                    Label(model.isRunningCompatibilityTest ? "Test running…" : "Run compatibility test", systemImage: "checklist")
                }
                .disabled(model.isRunningCompatibilityTest || model.selectedDevice == nil || model.isDemo)
                ForEach(state.checks) { check in
                    CheckRow(check: check)
                }
            } header: {
                Text("Compatibility test")
            } footer: {
                Text("The test only reads data and sends read-only or stream on/off requests. It never resets, updates or reconfigures the band.")
            }

            Section("Band") {
                LabeledContent("Adapter", value: state.adapterID ?? "—")
                LabeledContent("Parser version", value: state.parserVersion ?? "—")
                LabeledContent("Firmware", value: state.firmware ?? "not read")
            }

            Section("Counters") {
                LabeledContent("Valid frames", value: "\(state.counters.framesValid)")
                LabeledContent("Malformed frames", value: "\(state.counters.framesMalformed)")
                LabeledContent("Bytes discarded", value: "\(state.counters.bytesDiscarded)")
                LabeledContent("Unknown packet types", value: "\(state.counters.unknownPackets)")
                LabeledContent("Standard HR notifications", value: "\(state.counters.standardHRNotifications)")
                LabeledContent("…with beat intervals", value: "\(state.counters.standardHRWithRR)")
                LabeledContent("History records", value: "\(state.counters.historyRecords)")
                LabeledContent("Commands sent", value: "\(state.counters.commandsSent)")
            }
            .font(.subheadline.monospacedDigit())

            if !state.services.isEmpty {
                Section("Services and characteristics") {
                    ForEach(state.services) { service in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(service.name).font(.subheadline.weight(.semibold))
                            Text(service.uuid).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
                            ForEach(service.characteristics) { c in
                                Text("• \(c.name) \(c.uuid.suffix(8)) [\(c.properties.joined(separator: ", "))]\(c.notifying ? " notifying" : "")")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }

            if !state.advertisement.isEmpty {
                Section {
                    ForEach(state.advertisement.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: state.advertisement[key] ?? "")
                            .font(.caption.monospaced())
                    }
                } header: {
                    Text("Advertisement")
                } footer: {
                    Text("These values are needed to enable AccessorySetupKit (see the build guide).")
                }
            }

            Section {
                Toggle("Record raw capture", isOn: Binding(get: { model.diagnostics.captureEnabled },
                                                           set: { v in model.setCaptureEnabled(v) }))
                    .tint(Theme.accent)
                LabeledContent("Captured entries", value: "\(state.capturedEntries)")
                Button("Export capture…") {
                    do { exportDocument = CaptureDocument(data: try model.makeCaptureData()) } catch { exportError = error.localizedDescription }
                }
                .disabled(state.capturedEntries == 0)
                Button("Clear capture", role: .destructive) { model.clearCapture() }
                    .disabled(state.capturedEntries == 0)
            } header: {
                Text("Raw capture")
            } footer: {
                Text("A capture contains raw bytes from your band (health data). It stays on this iPhone unless you export it, and is limited in size. Exported captures can be replayed with the forma-replay tool to check the parser.")
            }

            if !state.recentFrames.isEmpty {
                Section("Recent frames") {
                    ForEach(state.recentFrames) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(line.direction) \(line.characteristic) · \(line.summary)")
                                .font(.caption.weight(.medium))
                            Text(line.hexPreview)
                                .font(.caption2.monospaced())
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: "forma-capture.jsonl") { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
            exportDocument = nil
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }
}

struct CheckRow: View {
    let check: CompatibilityCheck

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(.subheadline.weight(.medium))
                Text(check.detail).font(.caption).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch check.status {
        case .pending: return "circle"
        case .running: return "hourglass"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .unverified: return "questionmark.circle"
        case .notApplicable: return "minus.circle"
        }
    }

    private var label: String {
        switch check.status {
        case .pending: return "Not run"
        case .running: return "Running"
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .unverified: return "Unverified"
        case .notApplicable: return "N/A"
        }
    }

    private var tint: Color {
        switch check.status {
        case .passed: return Theme.accent
        case .failed: return Theme.critical
        case .unverified, .running: return Theme.caution
        case .pending, .notApplicable: return Theme.textSecondary
        }
    }
}

/// A file document wrapping exported bytes (captures, backups, CSV bundles).
struct CaptureDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .plainText, .commaSeparatedText, .data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
