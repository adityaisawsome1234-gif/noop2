import SwiftUI
import UIKit
import FormaCore
import FormaFeatures

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var appLock
    @Environment(\.scenePhase) private var scenePhase
    /// Shows the lock screen in its own window, above every sheet and alert.
    @State private var lockWindow = LockWindowController()
    /// Face ID is requested automatically once each time Forma comes to the foreground locked (at launch or
    /// back from the background) — not again after the user cancels the prompt.
    @State private var autoUnlockPending = true
    @State private var unlocking = false

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
                        .modelAlert(model)
                }
            }
        }
        // While locked, nothing behind the lock screen is reachable with VoiceOver either.
        .accessibilityHidden(appLock.isLocked)
        .preferredColorScheme(model.appearance.colorScheme)
        .overlay {
            // Normally covered by the lock window; it still hides the content if that window cannot be shown.
            if appLock.isLocked {
                LockScreen(onUnlock: requestUnlock)
            }
        }
        // A sheet shows the model's messages itself; the root shows them only while no sheet is up.
        .modelAlert(model, isActive: model.onboardingComplete && !model.showDeviceHub && !model.showSettings)
        .onAppear {
            updateLockWindow()
            if scenePhase == .active { autoUnlockIfPending() }
        }
        .onChange(of: appLock.isLocked) { _, _ in updateLockWindow() }
        .onChange(of: model.appearance) { _, _ in updateLockWindow() }
        // `initial: true`: the phase at launch is reported too, so a user launch counts as active and a
        // Bluetooth relaunch in the background never runs foreground work.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                Task { await model.sceneBecameActive() }
                autoUnlockIfPending()
            case .background:
                appLock.lockIfEnabled()
                // Cover everything now, before iOS takes the app-switcher snapshot.
                updateLockWindow()
                autoUnlockPending = true
                model.sceneEnteredBackground()
            default:
                break
            }
        }
    }

    private func updateLockWindow() {
        if appLock.isLocked {
            lockWindow.show(LockScreen(onUnlock: requestUnlock).environment(appLock),
                            style: model.appearance.userInterfaceStyle)
        } else {
            lockWindow.hide()
        }
    }

    private func autoUnlockIfPending() {
        guard autoUnlockPending else { return }
        autoUnlockPending = false
        requestUnlock()
    }

    /// Asks for Face ID or the passcode. Only called while Forma is in the foreground: a request started in
    /// the background would be cancelled by the system and leave the lock screen with an error.
    private func requestUnlock() {
        guard appLock.isLocked, !unlocking else { return }
        unlocking = true
        Task {
            await appLock.unlock()
            unlocking = false
        }
    }
}

/// Privacy screen shown while App Lock is engaged.
struct LockScreen: View {
    @Environment(AppLock.self) private var appLock
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "lock.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Forma is locked")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let error = appLock.lastError {
                    Text(error).font(.footnote).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                Button("Unlock", action: onUnlock)
                    .buttonStyle(.formaProminent)
            }
            .padding(Theme.Space.xl)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// Shows the lock screen in its own window above every sheet, alert, confirmation dialog and file
/// picker. An overlay on the root view would sit *below* those presentations, so whatever was open when
/// Forma locked (Settings, an export, Diagnostics) would stay visible and usable on return.
@MainActor
final class LockWindowController {
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    func show<Content: View>(_ content: Content, style: UIUserInterfaceStyle) {
        if let window {
            window.overrideUserInterfaceStyle = style
            return
        }
        guard let scene = Self.windowScene() else { return }
        // Dismiss the keyboard of a field being edited underneath (it lives in a window of its own).
        for existing in scene.windows { existing.endEditing(true) }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: content)
        // VoiceOver stays inside the lock screen instead of reaching the windows below.
        window.accessibilityViewIsModal = true
        previousKeyWindow = scene.keyWindow
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide() {
        guard let window else { return }
        let scene = window.windowScene
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        // Hand key status back to the app's own window (also when none was key when the lock appeared).
        let next = previousKeyWindow ?? scene?.windows.first { $0 !== window && !$0.isHidden }
        next?.makeKey()
        previousKeyWindow = nil
    }

    private static func windowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive }
            ?? scenes.first
    }
}
