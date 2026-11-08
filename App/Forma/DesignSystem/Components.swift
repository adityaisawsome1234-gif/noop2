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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            // At accessibility text sizes the title gets the full width and the tag goes below it, so
            // neither wraps mid-word in narrow tiles.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    titleText
                    StatusTag(status: status)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    titleText
                    Spacer(minLength: Theme.Space.xxs)
                    StatusTag(status: status)
                }
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
                ExplainButton(subject: title, action: onExplain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.Typeface.label)
            .foregroundStyle(Theme.textSecondary)
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
                    .buttonStyle(.formaProminent)
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

extension BluetoothUnavailableReason {
    /// Plain-language status line ("Bluetooth is off"), instead of the raw state name.
    var statusLine: String {
        switch self {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission is off for Forma"
        case .unsupported: return "This iPhone does not support Bluetooth Low Energy"
        default: return "Bluetooth is starting"
        }
    }
}

extension ConnectionSummary {
    /// The model's three status lines (link, last device sample, last sync), with the Bluetooth state in
    /// plain language.
    func displayLines(now: EpochMillis, calendar: Calendar) -> [String] {
        var lines = detailLines(now: now, formatter: RelativeTimeFormatter(calendar: calendar))
        if case .bluetoothUnavailable(let reason) = link, !lines.isEmpty {
            lines[0] = reason.statusLine
        }
        return lines
    }
}

// MARK: - Coverage bar

/// Horizontal bar showing which parts of a window are recorded, saved but awaiting validation, pending
/// sync, or unavailable.
///
/// Colour is never the only signal: the four states also differ in shape (full bar, outlined full bar,
/// half bar, thin line), which survives grayscale and colour-blindness, and every mark is ≥ 5:1 against
/// the card.
struct CoverageBar: View {
    struct Segment: Identifiable, Hashable {
        enum Kind: Hashable { case recorded, awaitingValidation, pendingSync, notRecorded }
        let id: Int
        let fractionStart: Double
        let fractionEnd: Double
        let kind: Kind
    }

    let segments: [Segment]
    let accessibilitySummary: String

    static let height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                ForEach(segments) { s in
                    Self.mark(s.kind)
                        .frame(width: max(1, geo.size.width * (s.fractionEnd - s.fractionStart)), height: Self.markHeight(s.kind))
                        .offset(x: geo.size.width * s.fractionStart)
                }
            }
            .frame(width: geo.size.width, height: Self.height, alignment: .leading)
        }
        .frame(height: Self.height)
        .accessibilityElement()
        .accessibilityLabel(accessibilitySummary)
    }

    /// The mark of one state: filled, except "awaiting validation", which is outlined (data that is stored
    /// but not used yet).
    @ViewBuilder
    static func mark(_ kind: Segment.Kind) -> some View {
        switch kind {
        case .awaitingValidation:
            Rectangle().strokeBorder(color(kind), lineWidth: 2)
        case .recorded, .pendingSync, .notRecorded:
            Rectangle().fill(color(kind))
        }
    }

    static func markHeight(_ kind: Segment.Kind) -> CGFloat {
        switch kind {
        case .recorded, .awaitingValidation: return height
        case .pendingSync: return height / 2
        case .notRecorded: return 2
        }
    }

    static func color(_ kind: Segment.Kind) -> Color {
        switch kind {
        case .recorded, .awaitingValidation: return Theme.accent
        case .pendingSync: return Theme.caution
        case .notRecorded: return Theme.textSecondary
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

// MARK: - Buttons

/// Filled accent button for a screen's primary action. The label uses `Theme.onAccent`, which stays
/// ≥ 5.9:1 on the accent fill in light, dark and increased-contrast modes (`.borderedProminent` draws a
/// white label, which is only 2.2:1 on the light dark-mode accent).
struct FormaProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs)
            .frame(minHeight: 44)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == FormaProminentButtonStyle {
    /// Forma's filled primary-action style (see `FormaProminentButtonStyle`).
    static var formaProminent: FormaProminentButtonStyle { FormaProminentButtonStyle() }
}

/// A small text-only action (footnote size) whose tap area is still at least 44 pt tall.
struct InlineButton: View {
    let title: String
    var accessibilityTitle: String? = nil
    var tint: Color = Theme.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typeface.caption)
                .foregroundStyle(tint)
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(accessibilityTitle ?? title)
    }
}

/// "How this is calculated", named after the metric for VoiceOver (a screen has many of these).
struct ExplainButton: View {
    var title = "How this is calculated"
    let subject: String
    let action: () -> Void

    var body: some View {
        InlineButton(title: title, accessibilityTitle: "How \(subject) is calculated", action: action)
    }
}

// MARK: - Loading and problems

/// Placeholder while a screen's data is computed. If nothing has arrived after a while (a load that
/// failed or a database that could not be opened), it says so and offers a retry instead of spinning
/// forever.
struct LoadingPlaceholder: View {
    let retry: () async -> Void
    @State private var slow = false

    var body: some View {
        Group {
            if slow {
                StateMessage(systemImage: "exclamationmark.triangle",
                             title: "Your data has not loaded",
                             message: "Loading is taking much longer than usual, or it failed; if Forma reported a problem, the reason was shown in a message. Try again. If this keeps happening, close Forma in the app switcher and open it again.",
                             actionTitle: "Try again",
                             action: { Task { await retry() } })
            } else {
                ProgressView("Loading")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task {
            // Cancelled (and never marked slow) when the data arrives and this placeholder goes away.
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
                slow = true
            } catch {}
        }
    }
}

/// Explains why Bluetooth cannot be used and what to do about it.
struct BluetoothProblemMessage: View {
    let reason: BluetoothUnavailableReason

    var body: some View {
        StateMessage(systemImage: "exclamationmark.triangle", title: title, message: message)
    }

    private var title: String {
        switch reason {
        case .poweredOff: return "Bluetooth is off"
        case .unauthorized: return "Bluetooth permission is off"
        case .unsupported: return "Bluetooth is not supported"
        default: return "Bluetooth is not ready"
        }
    }

    private var message: String {
        switch reason {
        case .poweredOff:
            return "Turn on Bluetooth in Control Center or Settings. Forma reconnects to your band once Bluetooth is back on."
        case .unauthorized:
            return "Forma needs Bluetooth permission to read your band. Turn it on in Settings → Privacy & Security → Bluetooth → Forma."
        case .unsupported:
            return "This iPhone cannot connect to Bluetooth Low Energy devices."
        default:
            return "iOS is still starting Bluetooth. This usually takes a moment."
        }
    }
}

// MARK: - Alerts

extension View {
    /// Presents the app model's messages (errors and guidance) from this presentation. SwiftUI shows an
    /// alert only from the presentation on top, so every sheet root attaches its own, and the root's is
    /// inactive while a sheet is up — otherwise a message raised inside a sheet (pairing guidance, a failed
    /// save) would not appear until the sheet closed.
    func modelAlert(_ model: AppModel, isActive: Bool = true) -> some View {
        alert("Forma", isPresented: Binding(get: { isActive && model.alertMessage != nil },
                                            set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    /// Lists and forms use Forma's warm page background instead of the system grouped background.
    func formaListBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}
