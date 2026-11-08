import SwiftUI
import FormaCore
import FormaFeatures

// MARK: - Card

/// Surface container with a hairline border; the basic building block of every screen.
struct Card<Content: View>: View {
    var title: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if title != nil || accessory != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(Theme.Typeface.cardTitle)
                            .foregroundStyle(Theme.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Spacer(minLength: Theme.Space.xs)
                    if let accessory { accessory }
                }
            }
            content
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: Theme.hairline)
        )
    }
}

// MARK: - Status tag (measured / estimate / experimental)

struct StatusTag: View {
    let status: MetricStatus

    var body: some View {
        Text(label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .accessibilityLabel("\(label) value")
    }

    private var label: String {
        switch status {
        case .measured: return "Measured"
        case .estimate: return "Estimate"
        case .experimental: return "Experimental"
        }
    }

    private var foreground: Color {
        switch status {
        case .measured: return Theme.textSecondary
        case .estimate: return Theme.accent
        case .experimental: return Theme.caution
        }
    }

    private var background: Color {
        switch status {
        case .measured: return Theme.surfaceMuted
        case .estimate: return Theme.accentSoft
        case .experimental: return Theme.cautionSoft
        }
    }
}

// MARK: - Availability message

/// Renders a non-available `Availability` with an icon and plain-language reason (never an empty ring).
struct AvailabilityNote: View {
    let availability: Availability

    var body: some View {
        Label {
            Text(availability.explanation)
                .font(Theme.Typeface.label)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch availability {
        case .available: return "checkmark.circle"
        case .insufficientData: return "chart.bar.xaxis"
        case .calibrating: return "hourglass"
        case .unsupportedSensor: return "sensor"
        case .lowQuality: return "exclamationmark.triangle"
        case .notYetSynced: return "arrow.triangle.2.circlepath"
        case .disabled: return "slash.circle"
        }
    }

    private var tint: Color {
        switch availability {
        case .available: return Theme.accent
        case .lowQuality: return Theme.caution
        case .calibrating, .notYetSynced: return Theme.caution
        default: return Theme.textSecondary
        }
    }
}

// MARK: - Metric tile

/// One metric: value + unit when available, otherwise the reason. Always shows status class and,
/// when known, coverage and confidence.
struct MetricTile: View {
    let title: String
    let valueText: String?
    let unit: String
    let status: MetricStatus
    let availability: Availability
    var coverage: Double? = nil
    var confidence: Confidence = .none
    var footnote: String? = nil
    var onExplain: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.Typeface.label)
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: Theme.Space.xxs)
                StatusTag(status: status)
            }
            if let valueText, availability.isAvailable {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valueText)
                        .font(Theme.Typeface.metricValue)
                        .foregroundStyle(Theme.textPrimary)
                    Text(unit)
                        .font(Theme.Typeface.metricUnit)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(title): \(valueText) \(spokenUnit)")
                if coverage != nil || confidence != .none {
                    QualityLine(coverage: coverage, confidence: confidence)
                }
            } else {
                AvailabilityNote(availability: availability)
            }
            if let footnote {
                Text(footnote)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if let onExplain {
                Button("How this is calculated", action: onExplain)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var spokenUnit: String {
        switch unit {
        case "bpm": return "beats per minute"
        case "ms": return "milliseconds"
        case "h": return "hours"
        case "SD": return "standard deviations"
        default: return unit
        }
    }
}

/// "Coverage 86% · Confidence moderate".
struct QualityLine: View {
    let coverage: Double?
    let confidence: Confidence

    var body: some View {
        Text(text)
            .font(Theme.Typeface.caption)
            .foregroundStyle(Theme.textSecondary)
    }

    private var text: String {
        var parts: [String] = []
        if let coverage { parts.append("Coverage \(Int((coverage * 100).rounded()))%") }
        if confidence != .none { parts.append("Confidence \(confidence.rawValue)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Screen-level state messages

/// Full-width state message for empty/disconnected/error/unsupported situations.
struct StateMessage: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typeface.cardTitle)
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Theme.border, lineWidth: Theme.hairline))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Demo banner

/// Persistent, non-dismissable label shown on every screen while Demo mode is on.
struct DemoBanner: View {
    var body: some View {
        Label("Demo data: not from your band", systemImage: "theatermasks")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.demo)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.demoSoft)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("Demo mode. Showing generated demo data, not data from your band.")
    }
}

// MARK: - Connection control (toolbar)

struct ConnectionControl: View {
    let summary: ConnectionSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .symbolRenderingMode(.hierarchical)
                Text(summary.shortStatus)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
        }
        .accessibilityLabel("Band connection: \(summary.shortStatus)")
        .accessibilityHint("Opens device, sync and settings")
    }

    private var icon: String {
        if summary.isDemo { return "theatermasks" }
        switch summary.link {
        case .connected: return summary.liveStreaming ? "dot.radiowaves.left.and.right" : "checkmark.circle"
        case .searching, .connecting: return "antenna.radiowaves.left.and.right"
        case .disconnected: return "bolt.horizontal.circle"
        case .noDeviceSelected: return "plus.circle"
        case .bluetoothUnavailable: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch summary.severity {
        case .normal: return Theme.textPrimary
        case .active: return Theme.accent
        case .attention: return summary.isDemo ? Theme.demo : Theme.caution
        case .problem: return Theme.critical
        }
    }
}

// MARK: - Coverage bar

/// Horizontal bar showing which parts of a window are recorded, pending sync, or unavailable.
struct CoverageBar: View {
    struct Segment: Identifiable, Hashable {
        enum Kind: Hashable { case recorded, pendingSync, notRecorded }
        let id: Int
        let fractionStart: Double
        let fractionEnd: Double
        let kind: Kind
    }

    let segments: [Segment]
    let accessibilitySummary: String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceMuted)
                ForEach(segments) { s in
                    Rectangle()
                        .fill(color(s.kind))
                        .frame(width: max(1, geo.size.width * (s.fractionEnd - s.fractionStart)))
                        .offset(x: geo.size.width * s.fractionStart)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    private func color(_ kind: Segment.Kind) -> Color {
        switch kind {
        case .recorded: return Theme.accent
        case .pendingSync: return Theme.caution
        case .notRecorded: return Theme.border
        }
    }
}

// MARK: - Page scaffolding

/// Standard scrolling page with background, demo banner and spacing.
struct Page<Content: View>: View {
    let isDemo: Bool
    @ViewBuilder var content: Content

    init(isDemo: Bool, @ViewBuilder content: () -> Content) {
        self.isDemo = isDemo
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            if isDemo { DemoBanner() }
        }
    }
}
