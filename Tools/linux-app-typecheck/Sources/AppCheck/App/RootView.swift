import SwiftUI
import FormaCore
import FormaFeatures

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var appLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.onboardingComplete {
                OnboardingView()
            } else {
                TabView(selection: $model.selectedTab) {
                    Tab("Today", systemImage: "sun.max", value: AppTab.today) { TodayView() }
                    Tab("Sleep", systemImage: "bed.double", value: AppTab.sleep) { SleepView() }
                    Tab("Activity", systemImage: "figure.run", value: AppTab.activity) { ActivityView() }
                    Tab("Trends", systemImage: "chart.xyaxis.line", value: AppTab.trends) { TrendsView() }
                }
                .tint(Theme.accent)
                .sheet(isPresented: $model.showDeviceHub) { DeviceHubView() }
                .sheet(isPresented: $model.showSettings) {
                    NavigationStack { SettingsView() }
                }
            }
        }
        .preferredColorScheme(model.appearance.colorScheme)
        .overlay {
            if appLock.isLocked {
                LockScreen()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.alertMessage != nil },
                                                           set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task { await model.sceneBecameActive() }
            case .background:
                appLock.lockIfEnabled()
                model.sceneEnteredBackground()
            default:
                break
            }
        }
    }
}

/// Privacy screen shown while App Lock is engaged.
struct LockScreen: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                Text("Forma is locked")
                    .font(.title2.weight(.semibold))
                if let error = appLock.lastError {
                    Text(error).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                Button("Unlock") { Task { await appLock.unlock() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            .padding(Theme.Space.xl)
        }
        .task { await appLock.unlock() }
    }
}
