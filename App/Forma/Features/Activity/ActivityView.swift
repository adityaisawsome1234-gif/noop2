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
                    ProgressView("Loading").frame(maxWidth: .infinity, minHeight: 200)
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
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(model.isDemo)
            }
        }
        if case .available = state.zonesAvailability {
            EmptyView()
        } else {
            Card("Heart-rate zones") {
                AvailabilityNote(availability: state.zonesAvailability)
                Button("Set max heart rate or birth year") { model.showSettings = true }
                    .font(Theme.Typeface.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
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

    var body: some View {
        Card("Workout in progress", accessory: AnyView(StatusTag(status: .measured))) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Elapsed").font(Theme.Typeface.label).foregroundStyle(Theme.textSecondary)
                    Text(DisplayFormat.timer(millis: live.elapsedMillis))
                        .font(Theme.Typeface.metricValue)
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
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
                .accessibilityElement(children: .combine)
            }
            if let source = live.sourceLabel {
                Text("Source: \(source)").font(Theme.Typeface.caption).foregroundStyle(Theme.textSecondary)
            }
            SeriesChart(series: live.heartRate, height: 140)
            if !live.zones.isEmpty {
                ZoneBars(zones: live.zones)
            }
            Button(role: .destructive, action: onStop) {
                Label("Finish", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

struct WorkoutCard: View {
    let workout: WorkoutState
    let calendar: Calendar
    let onExplain: (String) -> Void
    @State private var expanded = false

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
            Grid(alignment: .leading, horizontalSpacing: Theme.Space.m, verticalSpacing: Theme.Space.s) {
                GridRow {
                    MetricTile(title: "Average HR", valueText: DisplayFormat.metric(workout.averageHR, digits: 0), unit: "bpm",
                               status: .measured, availability: workout.averageHR.availability)
                    MetricTile(title: "Max HR", valueText: DisplayFormat.metric(workout.maxHR, digits: 0), unit: "bpm",
                               status: .measured, availability: workout.maxHR.availability)
                }
            }
            MetricTile(title: "Forma Load (Edwards TRIMP)", valueText: DisplayFormat.metric(workout.load, digits: 0), unit: "TRIMP",
                       status: .estimate, availability: workout.load.availability, coverage: workout.load.coverage,
                       confidence: workout.load.confidence, onExplain: { onExplain(workout.load.specID) })
            DisclosureGroup("Heart rate and zones", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    SeriesChart(series: workout.heartRate, height: 140)
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
}
