import SwiftUI
import Charts
import Accessibility
import FormaCore
import FormaFeatures

/// Heart-rate (or any) time series. Gaps stay visible: each `segment` is drawn as its own line, so
/// the chart never interpolates across missing data.
struct SeriesChart: View {
    let series: SeriesDisplay
    /// What the series shows, for VoiceOver and the audio graph.
    var title: String = "Heart rate"
    var highlight: [TimeRange] = []
    /// Name of one highlighted range ("wake bout"), used in the caption and the audio-graph summary.
    var highlightLabel: String = ""
    var height: CGFloat = 180

    /// Points with a unique identity: two points can share a time when a gap splits a time bucket.
    private var indexedPoints: [(offset: Int, element: ChartPoint)] {
        Array(series.points.enumerated())
    }

    /// Points alone in their segment (e.g. one sample between two gaps). A line needs two points, so
    /// these are drawn as dots; otherwise they would silently disappear.
    private var isolatedPoints: [(offset: Int, element: ChartPoint)] {
        var counts: [Int: Int] = [:]
        for p in series.points { counts[p.segment, default: 0] += 1 }
        return Array(series.points.filter { counts[$0.segment] == 1 }.enumerated())
    }

    private var gapCaption: String {
        series.gapCount == 1
            ? "1 gap in this window is shown as a break in the line"
            : "\(series.gapCount) gaps in this window are shown as breaks in the line"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if series.points.isEmpty {
                Text("No samples in this window")
                    .font(Theme.Typeface.label)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: height / 2, alignment: .center)
            } else {
                Chart {
                    ForEach(highlight, id: \.start) { r in
                        RectangleMark(
                            xStart: .value("Start", r.start.date),
                            xEnd: .value("End", r.end.date)
                        )
                        .foregroundStyle(Theme.cautionSoft)
                    }
                    ForEach(indexedPoints, id: \.offset) { item in
                        LineMark(
                            x: .value("Time", item.element.t.date),
                            y: .value(series.unit, item.element.value),
                            series: .value("Segment", item.element.segment)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                    ForEach(isolatedPoints, id: \.offset) { item in
                        PointMark(
                            x: .value("Time", item.element.t.date),
                            y: .value(series.unit, item.element.value)
                        )
                        .foregroundStyle(Theme.accent)
                        .symbolSize(18)
                    }
                }
                .chartXScale(domain: series.window.start.date ... series.window.end.date)
                .chartYAxisLabel { Text(series.unit) }
                .frame(height: height)
                .accessibilityChartDescriptor(SeriesChartDescriptor(series: series, title: title, highlightCount: highlight.count,
                                                                    highlightLabel: highlightLabel))
            }
            if !highlight.isEmpty, !highlightLabel.isEmpty {
                Label("Shaded: \(countedPhrase(highlight.count, highlightLabel))", systemImage: "square.fill")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if series.gapCount > 0 {
                Label(gapCaption, systemImage: "line.diagonal")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// "1 wake bout", "3 wake bouts".
private func countedPhrase(_ n: Int, _ singular: String) -> String {
    "\(n) \(singular.lowercased())\(n == 1 ? "" : "s")"
}

/// Audio-graph / VoiceOver description for `SeriesChart`.
struct SeriesChartDescriptor: AXChartDescriptorRepresentable {
    let series: SeriesDisplay
    var title: String = "Heart rate"
    var highlightCount: Int = 0
    var highlightLabel: String = ""

    func makeChartDescriptor() -> AXChartDescriptor {
        let start = series.window.start.date
        let end = series.window.end.date
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: start.timeIntervalSince1970 ... max(end.timeIntervalSince1970, start.timeIntervalSince1970 + 1),
            gridlinePositions: []
        ) { value in
            Date(timeIntervalSince1970: value).formatted(date: .omitted, time: .shortened)
        }
        let minV = series.minValue ?? 0
        let maxV = max(series.maxValue ?? 1, minV + 1)
        let yAxis = AXNumericDataAxisDescriptor(title: series.unit, range: minV ... maxV, gridlinePositions: []) { value in
            "\(Int(value.rounded())) \(series.unit)"
        }
        let points = series.points.map { AXDataPoint(x: $0.t.date.timeIntervalSince1970, y: $0.value) }
        let dataSeries = AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: points)
        var notes: [String] = []
        if series.gapCount > 0 {
            notes.append(series.gapCount == 1 ? "Contains 1 gap without data." : "Contains \(series.gapCount) gaps without data.")
        }
        if highlightCount > 0, !highlightLabel.isEmpty {
            notes.append("\(countedPhrase(highlightCount, highlightLabel)) shaded.")
        }
        return AXChartDescriptor(
            title: title,
            summary: notes.isEmpty ? nil : notes.joined(separator: " "),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [dataSeries]
        )
    }
}

/// Daily values (trends). Missing days are simply absent — never drawn as zero — and the time axis
/// always spans the whole period, so a few values are not stretched across it.
struct DailyChart: View {
    let values: [DailyValue]
    let unit: String
    /// The metric shown, for VoiceOver and the audio graph.
    var title: String = "Daily values"
    var height: CGFloat = 200

    var body: some View {
        Chart {
            ForEach(values.filter { $0.value != nil }) { d in
                PointMark(
                    x: .value("Day", d.dayStart.date, unit: .day),
                    y: .value(unit, d.value ?? 0)
                )
                .foregroundStyle(Theme.accent)
                .symbolSize(28)
            }
        }
        .chartXScale(domain: domain)
        .chartYAxisLabel { Text(unit) }
        .frame(height: height)
        .accessibilityChartDescriptor(DailyChartDescriptor(values: values, unit: unit, title: title))
    }

    /// From the start of the first day to the end of the last day of the period.
    private var domain: ClosedRange<Date> {
        let starts = values.map(\.dayStart)
        guard let first = starts.min(), let last = starts.max() else {
            let now = Date()
            return now ... now.addingTimeInterval(86_400)
        }
        return first.date ... (last + EpochMillis.millisPerDay).date
    }
}

/// Audio-graph / VoiceOver description for `DailyChart`.
struct DailyChartDescriptor: AXChartDescriptorRepresentable {
    let values: [DailyValue]
    let unit: String
    let title: String

    func makeChartDescriptor() -> AXChartDescriptor {
        let present = values.filter { $0.value != nil }
        let starts = values.map { $0.dayStart.date.timeIntervalSince1970 }
        let first = starts.min() ?? 0
        let last = max(starts.max() ?? 0, first + 86_400)
        let xAxis = AXNumericDataAxisDescriptor(title: "Day", range: first ... last, gridlinePositions: []) { value in
            Date(timeIntervalSince1970: value).formatted(date: .abbreviated, time: .omitted)
        }
        let numbers = present.compactMap(\.value)
        let minV = numbers.min() ?? 0
        let maxV = max(numbers.max() ?? 1, minV + 1)
        let yAxis = AXNumericDataAxisDescriptor(title: unit, range: minV ... maxV, gridlinePositions: []) { value in
            "\(DisplayFormat.number(value, digits: 1)) \(unit)"
        }
        let points = present.map { AXDataPoint(x: $0.dayStart.date.timeIntervalSince1970, y: $0.value) }
        let missing = values.count - present.count
        return AXChartDescriptor(
            title: title,
            summary: "\(present.count) of \(values.count) days have a value." + (missing > 0 ? " Days without a value are left out." : ""),
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [AXDataSeriesDescriptor(name: title, isContinuous: false, dataPoints: points)]
        )
    }
}

/// Horizontal time-in-zone bars, each labelled with zone number, range and minutes (not color-only).
struct ZoneBars: View {
    let zones: [ZoneTimeDisplay]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(zones) { z in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(z.label)
                            .font(Theme.Typeface.label)
                            .foregroundStyle(Theme.textPrimary)
                        Text(z.rangeText)
                            .font(Theme.Typeface.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(minutesText(z.millis))
                            .font(Theme.Typeface.label.monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.surfaceMuted)
                            Capsule()
                                .fill(color(for: z.zone))
                                .frame(width: max(2, geo.size.width * min(1, max(0, z.fraction))))
                        }
                    }
                    .frame(height: 6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(z.label), \(z.rangeText), \(minutesText(z.millis))")
            }
        }
    }

    private func color(for zone: Int) -> Color {
        let idx = min(max(zone - 1, 0), Theme.zoneColors.count - 1)
        return zone <= 0 ? Theme.border : Theme.zoneColors[idx]
    }

    private func minutesText(_ ms: Int64) -> String {
        let minutes = Int((Double(ms) / 60_000).rounded())
        return "\(minutes) min"
    }
}
