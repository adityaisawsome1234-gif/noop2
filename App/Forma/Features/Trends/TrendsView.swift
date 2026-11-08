import SwiftUI
import FormaCore
import FormaFeatures

struct TrendsView: View {
    @Environment(AppModel.self) private var model
    @State private var showTable = false
    @State private var explainedMetricID: String?

    var body: some View {
        NavigationStack {
            Page(isDemo: model.isDemo) {
                controls
                if let state = model.trends {
                    content(state)
                } else {
                    ProgressView("Loading").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .navigationTitle("Trends")
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

    private var controls: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker("Metric", selection: Binding(get: { model.trendMetric }, set: { m in Task { await model.setTrend(metric: m) } })) {
                ForEach(TrendMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.accent)
            Picker("Period", selection: Binding(get: { model.trendPeriod }, set: { p in Task { await model.setTrend(period: p) } })) {
                ForEach(TrendPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private func content(_ state: TrendsState) -> some View {
        Card(state.metric.title) {
            Text("\(state.daysWithData) of \(state.period.rawValue) days have a value")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.textSecondary)
            if state.daysWithData == 0 {
                AvailabilityNote(availability: .insufficientData(detail: "No days with a value in this period yet"))
            } else if showTable {
                TrendTable(values: state.daily, unit: state.metric.unit, calendar: model.calendar)
            } else {
                DailyChart(values: state.daily, unit: state.metric.unit)
            }
            Toggle("Show as table", isOn: $showTable)
                .font(Theme.Typeface.label)
                .tint(Theme.accent)
        }
        Card("Summary") {
            if state.availability.isAvailable {
                ForEach(state.summary) { row in
                    LabeledContent(row.label) {
                        Text(row.value).monospacedDigit()
                    }
                    .font(Theme.Typeface.label)
                }
            } else {
                AvailabilityNote(availability: state.availability)
            }
            if let comparison = state.comparison {
                Text(comparison)
                    .font(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Descriptive statistics only. Changes over time can have many causes.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(Theme.textSecondary)
            Button("How these values are calculated") { explainedMetricID = model.specID(for: state.metric) }
                .font(Theme.Typeface.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
        }
    }
}

/// Accessible table alternative to the chart. Missing days are listed explicitly.
struct TrendTable: View {
    let values: [DailyValue]
    let unit: String
    let calendar: Calendar

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(values.reversed().enumerated()), id: \.element.id) { index, row in
                HStack {
                    Text(DisplayFormat.dayLabel(row.day, calendar: calendar))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(row.value == nil ? "No value" : "\(row.valueText) \(unit)")
                        .monospacedDigit()
                        .foregroundStyle(row.value == nil ? Theme.textSecondary : Theme.textPrimary)
                }
                .font(Theme.Typeface.label)
                .padding(.vertical, 6)
                .padding(.horizontal, Theme.Space.xs)
                .background(index.isMultiple(of: 2) ? Color.clear : Theme.surfaceMuted)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
