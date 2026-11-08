import SwiftUI
import FormaCore
import FormaFeatures

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var explainedMetricID: String?

    private var gridColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 160), spacing: Theme.Space.m)]
    }

    var body: some View {
        NavigationStack {
            Page(isDemo: model.isDemo) {
                if let state = model.today {
                    content(state)
                } else {
                    LoadingPlaceholder { await model.refreshNow() }
                }
            }
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ConnectionControl(summary: model.connection) { model.showDeviceHub = true }
                }
            }
            // Pulling to refresh downloads band history only in "Automatically" mode; with "When I tap
            // Sync" the download (and what it may do on the band) stays behind the explicit Sync now button.
            .refreshable { await model.refresh(requestSync: model.historySyncMode == .automatic) }
            .sheet(item: Binding(get: { explainedMetricID.map(IdentifiedString.init) },
                                 set: { explainedMetricID = $0?.value })) { item in
                MethodologyDetailSheet(specID: item.value)
            }
        }
    }

    @ViewBuilder
    private func content(_ state: TodayState) -> some View {
        if !model.isDemo, case .bluetoothUnavailable(let reason) = model.connection.link {
            BluetoothProblemMessage(reason: reason)
        }
        // Live heart rate can arrive before the first full refresh has stored anything.
        if !state.hasAnyData && state.latestHeartRate == nil {
            StateMessage(
                systemImage: "sensor.tag.radiowaves.forward",
                title: model.connection.link == .noDeviceSelected ? "Connect your band" : "No data yet",
                message: model.connection.link == .noDeviceSelected
                    ? "Forma reads your band directly over Bluetooth. Nothing is uploaded. You can also explore with clearly labelled demo data."
                    : "Forma will show measurements here as soon as your band sends them. Keep the band nearby and the app open for the first sync.",
                actionTitle: model.connection.link == .noDeviceSelected ? "Choose band" : nil,
                action: model.connection.link == .noDeviceSelected ? { model.showDeviceHub = true } : nil
            )
            if model.connection.link == .noDeviceSelected && !model.isDemo {
                if model.isPreparingDemo {
                    ProgressView("Preparing demo data…")
                } else {
                    Button("Explore demo data") { Task { await model.enterDemo() } }
                        .buttonStyle(.bordered)
                        .tint(Theme.demo)
                }
            }
        } else {
            latestHeartRateCard(state.latestHeartRate, historyAwaitingValidation: state.historyAwaitingValidation)
            if let pending = state.pendingSleepReview {
                sleepReviewCard(pending)
            }
            if let readiness = state.readiness {
                ReadinessCard(state: readiness) { explainedMetricID = readiness.metric.specID }
            }
            if let calibration = state.calibration, !calibration.isComplete {
                Card("Calibrating") {
                    ProgressView(value: Double(calibration.eligibleNights), total: Double(max(1, calibration.requiredNights)))
                        .tint(Theme.accent)
                    Text("\(calibration.eligibleNights) of \(calibration.requiredNights) eligible nights")
                        .font(Theme.Typeface.label.monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                    Text(calibration.explanation)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            LazyVGrid(columns: gridColumns, spacing: Theme.Space.m) {
                ForEach(state.cards) { card in
                    Card {
                        MetricTile(title: card.title, valueText: card.valueText, unit: card.unit, status: card.status,
                                   availability: card.metric.availability, coverage: card.metric.coverage,
                                   confidence: card.metric.confidence, footnote: card.footnote,
                                   onExplain: { explainedMetricID = card.metric.specID })
                    }
                }
            }
            Card("Last 24 hours") {
                CoverageBar(segments: CoverageSegments.make(state.coverage24h),
                            accessibilitySummary: state.coverage24h.accessibilitySummary)
                Text(state.coverage24h.accessibilitySummary)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
                CoverageLegend()
            }
        }
        StatusFooter(summary: model.connection, now: model.now, calendar: model.calendar)
    }

    @ViewBuilder
    private func latestHeartRateCard(_ latest: LatestHeartRate?, historyAwaitingValidation: Bool) -> some View {
        Card("Heart rate", accessory: AnyView(StatusTag(status: .measured))) {
            if let latest {
                // "Live"/"Current" only while samples are arriving and this one is recent; the model
                // re-evaluates `isStale` on every tick, so a value that stops updating turns into "Last".
                let isLive = !latest.isStale && model.connection.liveStreaming
                let ago = RelativeTimeFormatter(calendar: model.calendar).string(from: latest.at, now: model.now)
                let spoken: String = isLive
                    ? "Current heart rate \(latest.bpm) beats per minute"
                    : "Last heart rate \(latest.bpm) beats per minute, measured \(ago)"
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(latest.bpm)")
                        .font(Theme.Typeface.metricValueLarge)
                        .foregroundStyle(latest.isStale ? Theme.textSecondary : Theme.textPrimary)
                    Text("bpm")
                        .font(Theme.Typeface.metricUnit)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    if isLive {
                        Label("Live", systemImage: "dot.radiowaves.left.and.right")
                            .font(Theme.Typeface.label)
                            .foregroundStyle(Theme.accent)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spoken)
                Text("\(latest.isStale ? "Last sample" : "Sample") \(ago) · \(latest.sourceLabel)")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            } else if historyAwaitingValidation {
                AvailabilityNote(availability: .disabled(reason: TodayState.historyAwaitingValidationNote))
            } else {
                AvailabilityNote(availability: .insufficientData(detail: "No heart-rate samples yet"))
            }
        }
    }

    private func sleepReviewCard(_ session: Session) -> some View {
        Card("Review last night") {
            Text("Forma found a possible sleep window \(DisplayFormat.range(session.range, calendar: model.calendar)). It is not used in totals until you confirm or adjust it.")
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Review in Sleep") { model.selectedTab = .sleep }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
        }
    }
}

/// Experimental readiness card: composite in SD units, band label, and every input with its weight.
struct ReadinessCard: View {
    let state: ReadinessCardState
    let onExplain: () -> Void
    @State private var showInputs = false

    var body: some View {
        Card("Readiness index", accessory: AnyView(StatusTag(status: .experimental))) {
            if let value = state.metric.value, state.metric.availability.isAvailable {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(DisplayFormat.signed(value, digits: 1))
                        .font(Theme.Typeface.metricValue)
                        .foregroundStyle(Theme.textPrimary)
                    Text("SD vs your baseline")
                        .font(Theme.Typeface.metricUnit)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Readiness index \(DisplayFormat.signed(value, digits: 1)) standard deviations versus your baseline")
                if let band = state.bandText {
                    Text(band)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                }
                DisclosureGroup("Inputs and weights", isExpanded: $showInputs) {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        ForEach(state.components) { row in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name).font(Theme.Typeface.label).foregroundStyle(Theme.textPrimary)
                                Text("\(row.valueText) · baseline \(row.baselineText) · z \(row.zText) · weight \(row.weightText)")
                                    .font(Theme.Typeface.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    .padding(.top, Theme.Space.xs)
                }
                .tint(Theme.accent)
                Text("Forma's own experimental composite. It is not a medical measure and not any other company's score.")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                AvailabilityNote(availability: state.metric.availability)
            }
            ExplainButton(subject: "the readiness index", action: onExplain)
        }
    }
}

/// Link / last device sample / last sync — always shown as separate lines.
struct StatusFooter: View {
    let summary: ConnectionSummary
    let now: EpochMillis
    var calendar: Calendar = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(summary.displayLines(now: now, calendar: calendar).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Space.xs)
        .accessibilityElement(children: .combine)
    }
}

struct CoverageLegend: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) { items }
            } else {
                HStack(spacing: Theme.Space.m) { items }
            }
        }
        .font(Theme.Typeface.caption)
        .foregroundStyle(Theme.textSecondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var items: some View {
        legend(.recorded, "Recorded")
        legend(.awaitingValidation, "Saved, not validated")
        legend(.pendingSync, "Pending sync")
        legend(.notRecorded, "Not recorded")
    }

    /// Same mark as in the bar: full bar, outlined bar, half height or a thin line.
    private func legend(_ kind: CoverageBar.Segment.Kind, _ text: String) -> some View {
        HStack(spacing: 4) {
            CoverageBar.mark(kind)
                .frame(width: 12, height: CoverageBar.markHeight(kind))
                .frame(width: 12, height: CoverageBar.height)
            Text(text)
        }
    }
}

enum CoverageSegments {
    static func make(_ timeline: CoverageTimeline) -> [CoverageBar.Segment] {
        let total = Double(max(1, timeline.window.durationMillis))
        return timeline.spans.enumerated().map { index, span in
            let kind: CoverageBar.Segment.Kind
            switch span.state {
            case .recorded: kind = .recorded
            case .awaitingValidation: kind = .awaitingValidation
            case .pendingSync: kind = .pendingSync
            case .notRecorded: kind = .notRecorded
            }
            return CoverageBar.Segment(
                id: index,
                fractionStart: Double(span.range.start - timeline.window.start) / total,
                fractionEnd: Double(span.range.end - timeline.window.start) / total,
                kind: kind
            )
        }
    }
}

/// Identifiable wrapper for String-driven sheets.
struct IdentifiedString: Identifiable, Hashable {
    let value: String
    var id: String { value }
}
