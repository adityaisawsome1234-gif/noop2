import SwiftUI
import FormaCore
import FormaFeatures

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var explainedMetricID: String?
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Page(isDemo: model.isDemo) {
                if let state = model.activity {
                    content(state)
                } else {
                    LoadingPlaceholder { await model.refreshNow() }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionControl(summary: model.connection) { model.showDeviceHub = true }
                }
            }
            .sheet(item: Binding(get: { explainedMetricID.map(IdentifiedString.init) },
                                 set: { explainedMetricID = $0?.value })) { item in
                MethodologyDetailSheet(specID: item.value)
            }
        }
    }

    @ViewBuilder
    private func content(_ state: ActivityState) -> some View {
        if let live = state.live {
            LiveWorkoutCard(live: live, calendar: model.calendar) { confirmStop = true }
                .confirmationDialog("Finish workout?", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Finish and save") { Task { await model.stopWorkout(save: true) } }
                    Button("Discard", role: .destructive) { Task { await model.stopWorkout(save: false) } }
                    Button("Keep recording", role: .cancel) {}
                } message: {
                    Text(finishMessage(live))
                }
        } else {
            Card("Record a workout") {
                Text(startHint)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await model.startWorkout() }
                } label: {
                    Label("Start workout", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.formaProminent)
                .disabled(model.isDemo)
            }
        }
        if case .available = state.zonesAvailability {
            EmptyView()
        } else {
            Card("Heart-rate zones") {
                AvailabilityNote(availability: state.zonesAvailability)
                InlineButton(title: "Set max heart rate or birth year") { model.showSettings = true }
            }
        }
        if state.workouts.isEmpty {
            StateMessage(systemImage: "figure.run",
                         title: "No workouts yet",
                         message: "Workouts you record appear here with duration, average and maximum heart rate, time in zones and Forma Load.")
        } else {
            Text("History")
                .font(Theme.Typeface.cardTitle)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(state.workouts) { workout in
                WorkoutCard(workout: workout, calendar: model.calendar) { explainedMetricID = $0 }
            }
        }
    }

    /// Forma does not save workouts shorter than a minute; say so before the user loses one.
    private func finishMessage(_ live: LiveWorkoutState) -> String {
        live.elapsedMillis < 60_000
            ? "Workouts shorter than 1 minute are not saved."
            : "Saving keeps the workout with its heart rate, zones and Forma Load."
    }

    private var startHint: String {
        if model.isDemo { return "Workout recording is disabled in Demo mode." }
        switch model.connection.link {
        case .connected:
            return "Forma records your band's heart rate on this phone. Keep the phone within Bluetooth range; gaps are shown, never filled in."
        default:
            return "You can start now; heart rate appears once the band connects. Time without samples is shown as a gap."
        }
    }
}

struct LiveWorkoutCard: View {
    let live: LiveWorkoutState
    let calendar: Calendar
    let onStop: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card("Workout in progress", accessory: AnyView(StatusTag(status: .measured))) {
            // Side by side normally; stacked at accessibility text sizes so the timer and heart rate never wrap.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    elapsed
                    heartRate(alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    elapsed
                    Spacer()
                    heartRate(alignment: .trailing)
                }
            }
            if let source = live.sourceLabel {
                Text("Source: \(source)").font(Theme.Typeface.caption).foregroundStyle(Theme.textSecondary)
            }
            SeriesChart(series: live.heartRate, title: "Workout heart rate", height: 140)
            if !live.zones.isEmpty {
                ZoneBars(zones: live.zones)
            }
            Button(role: .destructive, action: onStop) {
                Label("Finish", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var elapsed: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Elapsed").font(Theme.Typeface.label).foregroundStyle(Theme.textSecondary)
            Text(DisplayFormat.timer(millis: live.elapsedMillis))
                .font(Theme.Typeface.metricValue)
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elapsed \(Self.spokenDuration(live.elapsedMillis))")
    }

    private func heartRate(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text("Heart rate").font(Theme.Typeface.label).foregroundStyle(Theme.textSecondary)
            if let hr = live.currentHR, !live.signalStale {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(hr)").font(Theme.Typeface.metricValueLarge).foregroundStyle(Theme.textPrimary)
                    Text("bpm").font(Theme.Typeface.metricUnit).foregroundStyle(Theme.textSecondary)
                }
                if let zone = live.currentZone, zone > 0 {
                    Text("Zone \(zone)").font(Theme.Typeface.label).foregroundStyle(Theme.accent)
                }
            } else {
                Label("No signal", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.caution)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heartRateLabel)
    }

    private var heartRateLabel: String {
        guard let hr = live.currentHR, !live.signalStale else { return "Heart rate: no signal" }
        if let zone = live.currentZone, zone > 0 { return "Heart rate \(hr) beats per minute, zone \(zone)" }
        return "Heart rate \(hr) beats per minute"
    }

    /// "12 minutes 34 seconds" (a timer read as "12:34" would be spoken as a clock time).
    static func spokenDuration(_ millis: Int64) -> String {
        let total = max(0, millis / 1_000)
        let h = total / 3_600
        let m = (total % 3_600) / 60
        let s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
        if h > 0 || m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
        parts.append("\(s) second\(s == 1 ? "" : "s")")
        return parts.joined(separator: " ")
    }
}

struct WorkoutCard: View {
    let workout: WorkoutState
    let calendar: Calendar
    let onExplain: (String) -> Void
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Card((workout.session.label ?? "Workout") + " · " + DisplayFormat.dayLabel(LocalDay(workout.session.range.start, calendar: calendar), calendar: calendar)) {
            Text("\(DisplayFormat.range(workout.session.range, calendar: calendar)) · \(DisplayFormat.duration(millis: workout.session.range.durationMillis))")
                .font(.body.monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            if let coverage = workout.coverage {
                Text("Heart-rate coverage \(DisplayFormat.percent(coverage))")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    averageTile
                    maxTile
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                    GridRow {
                        averageTile
                        maxTile
                    }
                }
            }
            MetricTile(title: "Forma Load (Edwards TRIMP)", valueText: DisplayFormat.metric(workout.load, digits: 0), unit: "TRIMP",
                       status: .estimate, availability: workout.load.availability, coverage: workout.load.coverage,
                       confidence: workout.load.confidence, onExplain: { onExplain(workout.load.specID) })
            DisclosureGroup("Heart rate and zones", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SeriesChart(series: workout.heartRate, title: "Workout heart rate", height: 140)
                    if workout.zones.isEmpty {
                        AvailabilityNote(availability: workout.zonesAvailability)
                    } else {
                        ZoneBars(zones: workout.zones)
                    }
                }
                .padding(.top, Theme.Space.xs)
            }
            .tint(Theme.accent)
        }
    }

    private var averageTile: some View {
        MetricTile(title: "Average HR", valueText: DisplayFormat.metric(workout.averageHR, digits: 0), unit: "bpm",
                   status: .measured, availability: workout.averageHR.availability)
    }

    private var maxTile: some View {
        MetricTile(title: "Max HR", valueText: DisplayFormat.metric(workout.maxHR, digits: 0), unit: "bpm",
                   status: .measured, availability: workout.maxHR.availability)
    }
}
