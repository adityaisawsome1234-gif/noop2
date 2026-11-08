import SwiftUI
import FormaCore
import FormaFeatures

struct SleepView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditTarget?
    @State private var explainedMetricID: String?

    enum EditTarget: Identifiable {
        case new
        case existing(Session)

        var id: String {
            switch self {
            case .new: return "new"
            case .existing(let s): return "s\(s.id ?? s.range.start)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Page(isDemo: model.isDemo) {
                if let state = model.sleep {
                    content(state)
                } else {
                    ProgressView("Loading").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .navigationTitle("Sleep")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { editing = .new } label: { Label("Add sleep window", systemImage: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionControl(summary: model.connection) { model.showDeviceHub = true }
                }
            }
            .sheet(item: $editing) { target in
                switch target {
                case .new:
                    SleepWindowEditor(title: "Add sleep window", initial: model.suggestedNewSleepWindow(), calendar: model.calendar) { range in
                        Task { await model.addManualSleep(range: range) }
                    }
                case .existing(let session):
                    SleepWindowEditor(title: "Adjust sleep window", initial: session.range, calendar: model.calendar) { range in
                        Task { await model.updateSleep(session, range: range) }
                    }
                }
            }
            .sheet(item: Binding(get: { explainedMetricID.map(IdentifiedString.init) },
                                 set: { explainedMetricID = $0?.value })) { item in
                MethodologyDetailSheet(specID: item.value)
            }
        }
    }

    @ViewBuilder
    private func content(_ state: SleepState) -> some View {
        if case .available = state.motionAvailability {
            EmptyView()
        } else {
            Card {
                AvailabilityNote(availability: state.motionAvailability)
                Text("Forma only proposes sleep windows when the band provides motion data. You can always add or edit windows yourself. Sleep stages are not estimated.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if state.nights.isEmpty {
            StateMessage(systemImage: "bed.double",
                         title: "No sleep windows yet",
                         message: "Add the time you went to bed and got up, or wait for a detected window to review. Overnight heart rate and HRV appear once a window exists.",
                         actionTitle: "Add sleep window",
                         action: { editing = .new })
        } else {
            ForEach(state.nights) { night in
                NightCard(night: night, calendar: model.calendar, now: model.now,
                          onConfirm: { Task { await model.confirmSleep(night.session) } },
                          onAdjust: { editing = .existing(night.session) },
                          onReject: { Task { await model.rejectSleep(night.session) } },
                          onExplain: { explainedMetricID = $0 })
            }
        }
    }
}

struct NightCard: View {
    let night: NightState
    let calendar: Calendar
    let now: EpochMillis
    let onConfirm: () -> Void
    let onAdjust: () -> Void
    let onReject: () -> Void
    let onExplain: (String) -> Void

    var body: some View {
        Card(DisplayFormat.dayLabel(LocalDay(night.session.range.end, calendar: calendar), calendar: calendar),
             accessory: AnyView(originTag)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayFormat.range(night.session.range, calendar: calendar))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                Text("Time in window \(DisplayFormat.duration(millis: night.session.range.durationMillis))")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if night.isCandidate {
                Text("Detected candidate\(night.session.confidence.map { " (confidence \(DisplayFormat.percent($0)))" } ?? ""). Not counted until you confirm it.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Confirm", action: onConfirm).buttonStyle(.borderedProminent).tint(Theme.accent)
                    Button("Adjust", action: onAdjust).buttonStyle(.bordered).tint(Theme.accent)
                    Button("Not sleep", role: .destructive, action: onReject).buttonStyle(.bordered)
                }
            } else {
                Button("Adjust window", action: onAdjust)
                    .font(Theme.Typeface.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
            }
            SeriesChart(series: night.heartRate, highlight: night.wakeBouts, highlightLabel: "Wake bout", height: 140)
            CoverageBar(segments: CoverageSegments.make(night.coverage), accessibilitySummary: night.coverage.accessibilitySummary)
            Text(night.coverage.accessibilitySummary)
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.textSecondary)
            Divider().overlay(Theme.border)
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                GridRow {
                    metric("Sleep estimate", night.sleepEstimate, unit: "h", digits: 1, status: .estimate)
                    metric("Continuity", night.continuity, unit: "%", digits: 0, status: .estimate, asPercent: true)
                }
                GridRow {
                    metric("Resting HR", night.restingHR, unit: "bpm", digits: 0, status: .estimate)
                    metric("HRV (RMSSD)", night.hrv, unit: "ms", digits: 0, status: .estimate)
                }
            }
        }
    }

    private var originTag: some View {
        let text: String
        switch night.session.origin {
        case .manual: text = "Manual"
        case .detectedCandidate: text = "Candidate"
        case .userConfirmed: text = "Confirmed"
        case .userEdited: text = "Edited"
        case .imported: text = "Imported"
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(night.isCandidate ? Theme.caution : Theme.textSecondary)
            .background(night.isCandidate ? Theme.cautionSoft : Theme.surfaceMuted, in: Capsule())
    }

    private func metric(_ title: String, _ value: MetricValue<Double>, unit: String, digits: Int,
                        status: MetricStatus, asPercent: Bool = false) -> some View {
        let text: String?
        if asPercent, let v = value.value, value.availability.isAvailable {
            text = DisplayFormat.number(v * 100, digits: digits)
        } else {
            text = DisplayFormat.metric(value, digits: digits)
        }
        return MetricTile(title: title, valueText: text, unit: unit, status: status,
                          availability: value.availability, coverage: value.coverage, confidence: value.confidence,
                          onExplain: { onExplain(value.specID) })
    }
}

/// Start/end editor for a sleep window. Validates ordering and a sane maximum length.
struct SleepWindowEditor: View {
    let title: String
    let calendar: Calendar
    let onSave: (TimeRange) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: Date
    @State private var end: Date

    init(title: String, initial: TimeRange, calendar: Calendar, onSave: @escaping (TimeRange) -> Void) {
        self.title = title
        self.calendar = calendar
        self.onSave = onSave
        _start = State(initialValue: initial.start.date)
        _end = State(initialValue: initial.end.date)
    }

    private var validationMessage: String? {
        let length = end.timeIntervalSince(start)
        if length <= 0 { return "The end must be after the start." }
        if length > 16 * 3_600 { return "A sleep window can be at most 16 hours." }
        if end > Date().addingTimeInterval(60) { return "The window cannot end in the future." }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("End", selection: $end, displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(Theme.critical)
                    } else {
                        Text("Length \(DisplayFormat.duration(millis: Int64(end.timeIntervalSince(start) * 1_000))). Overnight metrics are recalculated after saving.")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(TimeRange(start: EpochMillis(date: start), end: EpochMillis(date: end)))
                        dismiss()
                    }
                    .disabled(validationMessage != nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
