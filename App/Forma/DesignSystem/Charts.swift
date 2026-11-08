import SwiftUI
import Charts
import Accessibility
import FormaCore
import FormaFeatures

/// Heart-rate (or any) time series. Gaps stay visible: each `segment` is drawn as its own line, so
/// the chart never interpolates across missing data.
struct SeriesChart: View {
    let series: SeriesDisplay
    var highlight: [TimeRange] = []
    var highlightLabel: String = ""
    var height: CGFloat = 180

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
                    ForEach(series.points) { p in
                        LineMark(
                            x: .value("Time", p.t.date),
                            y: .value(series.unit, p.value),
                            series: .value("Segment", p.segment)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                    }
                }
                .chartXScale(domain: series.window.start.date ... series.window.end.date)
                .chartYAxisLabel { Text(series.unit) }
                .frame(height: height)
                .accessibilityChartDescriptor(SeriesChartDescriptor(series: series))
            }
            if series.gapCount > 0 {
                Label("\(series.gapCount) gap\(series.gapCount == 1 ? "" : "s") in this window are shown as breaks in the line",
                      systemImage: "line.diagonal")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// Audio-graph / VoiceOver description for `SeriesChart`.
struct SeriesChartDescriptor: AXChartDescriptorRepresentable {
    let series: SeriesDisplay

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
        let dataSeries = AXDataSeriesDescriptor(name: series.unit, isContinuous: false, dataPoints: points)
        return AXChartDescriptor(
            title: "Time series",
            summary: series.gapCount > 0 ? "Contains \(series.gapCount) gaps without data." : nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [dataSeries]
        )
    }
}

/// Daily values (trends). Missing days are simply absent — never drawn as zero.
struct DailyChart: View {
    let values: [DailyValue]
    let unit: String
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
        .chartYAxisLabel { Text(unit) }
        .frame(height: height)
        .accessibilityLabel("Daily values. Days without data are omitted.")
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
