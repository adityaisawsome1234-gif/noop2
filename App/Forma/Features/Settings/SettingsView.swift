import SwiftUI
import UniformTypeIdentifiers
import LocalAuthentication
import FormaCore
import FormaFeatures

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var appLock

    var body: some View {
        Form {
            if model.isDemo {
                Section {
                    DemoModeNote(text: "Demo mode is on: Forma's screens show generated demo data, not data from your band.")
                }
            }
            ProfileSection()
            Section {
                Picker("Zone method", selection: Binding(get: { model.zoneMethod }, set: { m in Task { await model.setZoneMethod(m) } })) {
                    ForEach(ZoneMethodChoice.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
            } header: {
                Text("Heart-rate zones")
            } footer: {
                Text(model.zoneMethod.explanation)
            }
            Section {
                Toggle("Show experimental readiness index", isOn: Binding(get: { model.showExperimentalReadiness },
                                                                          set: { v in Task { await model.setShowExperimentalReadiness(v) } }))
                    .tint(Theme.accent)
            } header: {
                Text("Experimental")
            } footer: {
                Text("A Forma-defined composite of your HRV, resting heart rate and sleep duration relative to your own baseline. It is not a medical measure and does not reproduce any other company's score.")
            }
            Section("Appearance") {
                Picker("Theme", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    ForEach(AppearancePreference.allCases) { pref in
                        Text(pref.title).tag(pref)
                    }
                }
            }
            Section {
                Toggle("Require Face ID or passcode", isOn: Binding(get: { appLock.isEnabled }, set: { on in
                    if on { appLock.setEnabled(true) } else { Task { await turnOffAppLock() } }
                }))
                    .tint(Theme.accent)
            } header: {
                Text("Privacy")
            } footer: {
                Text("Hides Forma behind Face ID or your passcode when you return to it. Your data is also protected by iOS file encryption.")
            }
            Section("Data") {
                NavigationLink("Export, import and delete") { DataManagementView() }
                NavigationLink("Methodology") { MethodologyListView() }
            }
            Section("About") {
                NavigationLink("About Forma") { AboutView() }
            }
        }
        .formaListBackground()
        .navigationTitle("Settings")
    }

    /// Turning App Lock off needs the same Face ID or passcode it protects, so a phone left unlocked with
    /// Forma open cannot be used to switch the lock off quietly. Without a device passcode there is nothing
    /// to authenticate against, and the lock is simply turned off.
    private func turnOffAppLock() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            appLock.setEnabled(false)
            return
        }
        let confirmed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                           localizedReason: "Turn off App Lock for Forma.")) ?? false
        if confirmed { appLock.setEnabled(false) }
    }
}

/// Row stating that Demo mode is on (screens outside the four tabs have no demo banner).
struct DemoModeNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "theatermasks")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.demo)
    }
}

struct ProfileSection: View {
    @Environment(AppModel.self) private var model
    @State private var birthYearText = ""
    @State private var maxHRText = ""
    @State private var restingHRText = ""
    @State private var loaded = false

    var body: some View {
        Section {
            numberField("Birth year", text: $birthYearText, unit: nil, spokenUnit: nil)
            Picker("Sex (optional)", selection: Binding(get: { model.profile.sex }, set: { s in
                var p = model.profile
                p.sex = s
                Task { await model.setProfile(p) }
            })) {
                Text("Not specified").tag(UserProfile.Sex.unspecified)
                Text("Female").tag(UserProfile.Sex.female)
                Text("Male").tag(UserProfile.Sex.male)
            }
            numberField("Max heart rate", text: $maxHRText, unit: "bpm", spokenUnit: "beats per minute")
            numberField("Resting heart rate", text: $restingHRText, unit: "bpm", spokenUnit: "beats per minute")
            Button("Save profile") { save() }
                .disabled(!isValid || !hasUnsavedChanges)
        } header: {
            Text("Profile")
        } footer: {
            Text(validationMessage ?? ((hasUnsavedChanges ? "Not saved yet: tap Save profile to use these values. " : "")
                + "Used only for heart-rate zones and Forma Load. A max heart rate you enter is preferred over the age-based estimate (208 − 0.7 × age). Sex is used only by the optional Banister load and is never assumed."))
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            birthYearText = model.profile.birthYear.map(String.init) ?? ""
            maxHRText = model.profile.maxHeartRateOverride.map(String.init) ?? ""
            restingHRText = model.profile.restingHeartRateOverride.map(String.init) ?? ""
        }
    }

    /// A labelled number field: the label stays visible after a value is entered (a bare text field shows
    /// its title only as a placeholder).
    private func numberField(_ title: String, text: Binding<String>, unit: String?, spokenUnit: String?) -> some View {
        LabeledContent(title) {
            HStack(spacing: Theme.Space.xxs) {
                TextField("Optional", text: text)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(spokenUnit.map { "\(title) in \($0)" } ?? title)
                if let unit {
                    Text(unit)
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        guard loaded else { return false }
        return parse(birthYearText, range: 1900...currentYear).value != model.profile.birthYear
            || parse(maxHRText, range: 100...230).value != model.profile.maxHeartRateOverride
            || parse(restingHRText, range: 25...120).value != model.profile.restingHeartRateOverride
    }

    private func parse(_ text: String, range: ClosedRange<Int>) -> (ok: Bool, value: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (true, nil) }
        guard let v = Int(trimmed), range.contains(v) else { return (false, nil) }
        return (true, v)
    }

    private var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    private var validationMessage: String? {
        if !parse(birthYearText, range: 1900...currentYear).ok { return "Birth year must be between 1900 and \(currentYear)." }
        if !parse(maxHRText, range: 100...230).ok { return "Max heart rate must be between 100 and 230 bpm." }
        if !parse(restingHRText, range: 25...120).ok { return "Resting heart rate must be between 25 and 120 bpm." }
        return nil
    }

    private var isValid: Bool { validationMessage == nil }

    private func save() {
        var p = model.profile
        p.birthYear = parse(birthYearText, range: 1900...currentYear).value
        p.maxHeartRateOverride = parse(maxHRText, range: 100...230).value
        p.restingHeartRateOverride = parse(restingHRText, range: 25...120).value
        Task { await model.setProfile(p) }
    }
}

struct DataManagementView: View {
    @Environment(AppModel.self) private var model
    @State private var exportDocument: CaptureDocument?
    @State private var exportName = "forma-export"
    @State private var exportType: UTType = .json
    @State private var importing = false
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var working = false

    var body: some View {
        Form {
            if model.isDemo {
                Section {
                    DemoModeNote(text: "Demo mode is on. Export and import below use your own band data only: demo data is never exported or imported. Delete all data also removes the demo data and turns Demo mode off.")
                }
            }
            Section {
                Button("Export CSV files…") { run { (try await model.exportCSVArchive(), "forma-csv.zip", .zip) } }
                Button("Export full backup…") { run { (try await model.exportBackup(), "forma-backup.formabackup.jsonl", .json) } }
                Button("Import backup…") { importing = true }
            } header: {
                Text("Export and import")
            } footer: {
                Text("You choose where exported files go. Exports contain your own band data, never demo data. A backup can be imported on this or another iPhone; duplicates are skipped, a file containing demo data is refused, and summaries are recalculated.")
            }
            Section {
                Toggle("Include in iCloud and computer backups", isOn: Binding(get: { model.includeInDeviceBackups },
                                                                                set: { v in model.setIncludeInDeviceBackups(v) }))
                    .tint(Theme.accent)
            } header: {
                Text("Device backups")
            } footer: {
                Text("Off by default: your health data stays only on this iPhone and is not copied into iCloud Backup or computer backups. If it stays off, deleting Forma or replacing your iPhone loses any history you have not exported.")
            }
            Section {
                Picker("Keep raw captures for", selection: Binding(get: { model.rawRetentionDays }, set: { model.setRawRetentionDays($0) })) {
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
            } header: {
                Text("Diagnostics retention")
            } footer: {
                Text("Raw captures are only recorded while enabled in Diagnostics and are also limited in total size.")
            }
            Section {
                Button("Delete all data", role: .destructive) { confirmDelete = true }
            } footer: {
                Text("Erases every measurement, session, setting and capture stored by Forma on this iPhone, including demo data. This cannot be undone.")
            }
            if let message {
                Section { Text(message).font(.subheadline) }
            }
        }
        .formaListBackground()
        .navigationTitle("Your data")
        .disabled(working)
        .overlay { if working { ProgressView() } }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: exportType, defaultFilename: exportName) { result in
            switch result {
            case .success: message = "Export saved."
            case .failure(let error): message = "Export failed: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            switch result {
            case .success(let url):
                working = true
                Task {
                    message = await model.importBackup(from: url)
                    working = false
                }
            case .failure(let error):
                message = "Import failed: \(error.localizedDescription)"
            }
        }
        .confirmationDialog("Delete all Forma data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) {
                working = true
                Task {
                    message = await model.deleteAllData()
                    working = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Consider exporting a backup first.")
        }
    }

    private func run(_ make: @escaping () async throws -> (Data, String, UTType)) {
        working = true
        Task {
            do {
                let (data, name, type) = try await make()
                exportName = name
                exportType = type
                exportDocument = CaptureDocument(data: data)
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
            working = false
        }
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Text("Forma")
                    .font(.largeTitle.weight(.semibold))
                Text("A local-first wellness app that reads your own band over Bluetooth and keeps everything on this iPhone. No account, no server, no tracking.")
                Text("Independence")
                    .font(.headline)
                Text("Forma is not affiliated with, endorsed by, or connected to WHOOP, Inc. \"WHOOP\" is used only to identify the hardware Forma can read. Forma's metrics are its own documented estimates; they are not WHOOP Recovery, Strain, Sleep or any other proprietary score.")
                Text("Not a medical device")
                    .font(.headline)
                Text("Forma does not diagnose, treat or prevent any condition. Optical heart-rate data can be inaccurate, especially during movement.")
                Text("Open-source notices")
                    .font(.headline)
                Text(ThirdPartyNotices.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .navigationTitle("About")
    }
}
