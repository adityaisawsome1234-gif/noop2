import SwiftUI
import FormaCore
import FormaFeatures

/// First run: privacy → what Forma is → Bluetooth → choose band → history choice → calibration → done.
/// No account is created at any step.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var showPicker = false

    private let lastStep = 5

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ProgressView(value: Double(step), total: Double(lastStep))
                    .tint(Theme.accent)
                    .accessibilityLabel("Step \(step + 1) of \(lastStep + 1)")
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.m) {
                        page
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                controls
            }
            .padding(Theme.Space.l)
            .background(Theme.background.ignoresSafeArea())
            .sheet(isPresented: $showPicker) {
                NavigationStack { DevicePickerView() }
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0:
            heading("Your data stays on this iPhone", icon: "lock.shield")
            paragraph("Forma reads your band directly over Bluetooth, stores everything locally and calculates its summaries on this iPhone. There is no account, no server and no tracking.")
            paragraph("You can export or delete your data at any time. By default it is not included in iCloud or computer backups; if you delete Forma, unexported history is gone.")
        case 1:
            heading("Measurements first, estimates labelled", icon: "ruler")
            paragraph("Heart rate comes from your band. Resting heart rate, HRV, sleep windows and Forma Load are Forma's own estimates with published methods, shown with coverage and confidence.")
            paragraph("Forma is independent and not affiliated with WHOOP. Its numbers are not WHOOP Recovery, Strain or Sleep scores and are not medical measurements.")
        case 2:
            heading("Bluetooth", icon: "dot.radiowaves.left.and.right")
            paragraph("Forma needs Bluetooth permission to talk to your band. iOS will ask once.")
            if let message = model.bluetoothProblemMessage {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.critical)
            }
            Button("Allow Bluetooth") { model.requestBluetooth() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        case 3:
            heading("Choose your band", icon: "sensor.tag.radiowaves.forward")
            paragraph("Keep the band close to your iPhone. Forma lists matching bands nearby and bands already connected to this iPhone.")
            if let device = model.selectedDevice {
                Label("Selected: \(device.name)", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                paragraph("Forma will run a short compatibility test after setup. It only reads data and never changes the band.")
            }
            Button(model.selectedDevice == nil ? "Find band" : "Choose a different band") { showPicker = true }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            Button("Skip and explore demo data") {
                Task {
                    await model.enterDemo()
                    model.completeOnboarding()
                }
            }
            .tint(Theme.demo)
        case 4:
            heading("Band history", icon: "clock.arrow.circlepath")
            paragraph("Your band stores data while your iPhone is away. Forma can download it and fill the gaps.")
            ForEach(HistorySyncMode.allCases) { mode in
                Button {
                    Task { await model.setHistorySyncMode(mode) }
                } label: {
                    HStack(alignment: .top) {
                        Image(systemName: model.historySyncMode == mode ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).foregroundStyle(Theme.textPrimary)
                            Text(mode.explanation).font(.footnote).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.historySyncMode == mode ? .isSelected : [])
            }
        default:
            heading("Calibration takes time", icon: "hourglass")
            paragraph("Measured values appear right away. Baseline-relative values, such as the experimental readiness index, need at least 14 eligible nights of overnight data before Forma shows them.")
            paragraph("HRV appears only if your band provides real beat-to-beat intervals. Sleep windows can always be entered by hand.")
            paragraph("Tip: swiping Forma away in the app switcher stops background collection until you open it again.")
        }
    }

    private var controls: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < lastStep {
                Button("Continue") { step += 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            } else {
                Button("Start using Forma") { model.completeOnboarding() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }

    private func heading(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.title2.weight(.semibold))
            .foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
