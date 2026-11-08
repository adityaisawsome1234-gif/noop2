# Build, sign and install Forma on your iPhone

Forma is a personal build that you install from your own Mac. It has **no app subscription and no server**. To run your own build on an iPhone, Apple requires **developer code signing**. You can sign with a free Apple Account (a "Personal Team") or with a paid Apple Developer Program membership. Either way, the signature expires and has to be renewed, so the app is not maintenance-free.

Sources for every rule below are listed in `docs/research/IOS_BLE_RULES.md` §6. They were checked on 2026-11-08.

## 1. Requirements

| Item | Requirement |
|---|---|
| Mac | macOS Tahoe 26.6 or later (required by Xcode 27) |
| Xcode | **Xcode 27.x** (27.2 is current; it includes Swift 6.4 and the iOS 27 SDK). Use 27.x for an iOS 27 iPhone. Whether Xcode 26.x can install to iOS 27 is unconfirmed. |
| iPhone | iPhone 16 Pro on iOS 27 with **Developer Mode** enabled (see §4) |
| Apple Account | A free account, or a paid Apple Developer Program membership (§3) |
| Internet | Needed **on the Mac** to download Xcode, sign and register the device. The iPhone may need internet on first launch so that **iOS itself** can verify the developer profile (§3). Forma makes no network requests. |

## 2. Build steps

1. Get the source onto your Mac (clone or copy the `Forma` folder).
2. Open the project:
   - **Preferred:** open `Forma.xcodeproj`. It references the local `FormaKit` package and the `App/Forma` folder. The project file was hand-written in Xcode 16+ "synchronized folder" format. It has not been opened in Xcode yet, because this build environment has no Mac.
   - **Fallback:** if Xcode reports a problem with the project file, regenerate it from the spec:
     ```bash
     brew install xcodegen
     ```
     ```bash
     xcodegen generate
     ```
     ```bash
     open Forma.xcodeproj
     ```
3. In Xcode, select the **Forma** target and open **Signing & Capabilities**:
   - Team: choose your Personal Team or your paid team.
   - Bundle Identifier: change `com.example.forma.app` to something unique, for example `com.<yourname>.forma`.
   - Leave **Automatically manage signing** on.
   - Background Modes is already declared in `Info.plist` (`bluetooth-central`), so you don't need to add a capability for it.
4. Connect the iPhone (USB or Xcode 27 Device Hub network pairing), select it as the run destination, and press **Run**.
5. Optional checks on the Mac before or after building:
   ```bash
   cd FormaKit && swift test
   ```
   ```bash
   Tools/audit-no-network.sh
   ```
   The first command runs the core test suite. The second is the static no-network audit.

The first build compiles the Swift package and the app. FormaKit (all parsing, storage and analytics) has been compiled and tested on Linux with Swift 6.4.2. **The SwiftUI and Core Bluetooth app target has not been compiled in this environment.** Expect to fix minor compile issues the first time you build it in Xcode. Please report them so they can be fixed in the source.

## 3. Signing routes compared

| | Free Personal Team | Paid Apple Developer Program |
|---|---|---|
| Cost | Free | 99 USD per membership year (Apple's price; local pricing may differ) |
| How long a build runs | **7 days.** Provisioning profiles expire 7 days after issue. After that the app won't launch, and **background collection stops**, until you rebuild and reinstall from Xcode. | A development profile is commonly valid for about a year, ending no later than the certificate or membership (not stated on the pages Apple publishes) |
| Limits | 10 App IDs per 7 days, 3 devices, 3 apps per device | 100 devices per product family per year |
| Capabilities Forma needs | Background modes and Data Protection are allowed for free accounts. Core Bluetooth needs only the Info.plist usage string. AccessorySetupKit needs only Info.plist keys (no entitlement is documented) | Same |
| First launch | iOS may ask you to trust the developer under **Settings → General → VPN & Device Management** (reported by users; not an Apple document) | For memberships created after June 6, 2021, development-signed apps **check in with Apple's PPQ service on first launch**, which needs internet. Offline profiles are valid for 7 days. This is iOS, not Forma. |
| TestFlight | Not available | Possible (builds expire after 90 days and need an App Store Connect upload). Not needed for a personal build |

**Recommendation.** Use a **paid membership** if you want uninterrupted background collection. A Personal Team build stops working every 7 days until you reinstall it. Reinstalling the same bundle ID is an update, so local data is expected to survive. This is unconfirmed, so **export a backup first** (Settings → Data → Export, import and delete → Export full backup).

Neither route is an app subscription. Forma has no in-app purchases, accounts or recurring charges.

## 3a. Without Xcode: GitHub build + Sideloadly

You don't need a Mac or Xcode. GitHub builds the app, and Sideloadly (Windows or macOS) signs it with your Apple ID and installs it over USB.

1. **Get the `.ipa`.**
   1. Open the repository on GitHub → **Actions** → **Build IPA**.
   2. Open the newest green run and download the **Forma-ipa** artifact. It's a zip containing `Forma.ipa`; unzip it.
   3. Every push to `main` builds a new one, and **Run workflow** builds one on demand.
2. **Install Sideloadly** from sideloadly.io.
   - On Windows, also install iTunes and iCloud from apple.com (not the Microsoft Store versions). Sideloadly needs their device drivers.
3. **Connect the iPhone** by USB, unlock it, and tap **Trust** when asked.
4. **In Sideloadly:**
   1. Drag `Forma.ipa` into the window.
   2. Pick your iPhone and enter your Apple ID. A free Apple ID works. Sideloadly asks Apple for a development certificate; it does not need your Apple ID for anything else, but use an account you're comfortable with.
   3. Under **Advanced options**, keep **Bundle ID** set to something unique. Sideloadly's default rewrites it to a unique ID, which a free account needs because `com.example.forma.app` belongs to no one.
   4. Click **Start**. If Apple asks for a two-factor code, enter it in Sideloadly.
5. **On the iPhone:**
   1. Settings → Privacy & Security → **Developer Mode** → On, then restart (§4).
   2. Settings → General → **VPN & Device Management** → your Apple ID → **Trust**.
   3. Open Forma.
6. **Every 7 days** (free Apple ID): the app stops opening. Before that happens, export a backup (Settings → Data), then repeat step 4 with the same `.ipa` and the **same bundle ID**. Reinstalling the same bundle ID is an update, so your data is expected to stay; the backup is there in case it doesn't. With a paid developer account the signature lasts much longer.

Limits of a free Apple ID: 3 sideloaded apps at a time, and 10 new bundle IDs per 7 days. Keeping the same bundle ID avoids burning through them.

## 4. Enable Developer Mode on the iPhone

1. Connect the iPhone to the Mac once (or pair it in Xcode's Device Hub). Developer Mode only appears in Settings after the iPhone has been paired with a Mac.
2. Go to **Settings → Privacy & Security → Developer Mode**, switch it on, and restart.
3. After the restart, confirm **Enable** and enter your passcode.

## 5. After installing

1. Open Forma and follow onboarding: privacy, Bluetooth permission, choose your band, history choice.
2. Open **Band → Compatibility test and diagnostics** and run the test with the band nearby.
3. Turn on **Record raw capture**, then use the band normally for a few minutes, including a short history sync if you enabled it. Then **Export capture…**. This file is the evidence needed to verify Forma against your exact firmware. `docs/HARDWARE_VALIDATION_HANDOFF.md` explains what to send back and how to replay it:
   ```bash
   cd FormaKit && swift run forma-replay <file>
   ```
4. Don't swipe Forma away in the app switcher. iOS won't relaunch a force-quit Bluetooth app (§6) until you open it again.

## 6. Optional: enable AccessorySetupKit (after your first capture)

On iOS 26 and later, only apps that set up the accessory through **AccessorySetupKit** (ASK) are relaunched after a user force-quit or a Control Center Bluetooth toggle (TN3115 note 5). Field reports on this are mixed. ASK and generic Core Bluetooth scanning are mutually exclusive in one app, and ASK needs the identifiers the band advertises. For those reasons Forma v1 uses plain Core Bluetooth. To switch on ASK:

1. Copy the **Advertisement** values from Diagnostics: advertised service UUIDs, company identifier and name.
2. Add these keys to `App/Forma/Resources/Info.plist`:
   - `NSAccessorySetupKitSupports` = `[Bluetooth]`
   - `NSAccessorySetupBluetoothServices` = the advertised service UUID(s)
   - `NSAccessorySetupBluetoothNames` = a name substring
   - `NSAccessorySetupBluetoothCompanyIdentifiers` = the company ID, if one is advertised
3. Rebuild. Forma detects the keys at launch and uses the system accessory picker instead of its own scan list. In this mode **only accessories chosen in that picker are visible** to the app.
   - **Migration is not implemented.** Apple's rule for an install that already used plain Core Bluetooth: activate the `ASAccessorySession` and migrate the band (`ASMigrationDisplayItem`) *before* creating the `CBCentralManager`; a central created first makes the picker fail (`docs/research/IOS_BLE_RULES.md` 3.8). This build has no migration step and creates its central at launch once Bluetooth permission was decided, so on an existing install the switch may fail. Until a migration step is added, enable ASK only on a fresh install (export a backup, delete Forma, install the ASK build, import the backup), and verify the picker on device.
4. Never use "remove accessory" for a band you share with the official app. ASK removal unpairs the band system-wide. Forma's "Forget band" doesn't call it.

## 7. Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| Forma doesn't relaunch in the background | Forma was force-quit, Bluetooth was toggled in Settings, or the phone rebooted and hasn't been unlocked yet. Open Forma once. |
| "Untrusted Developer" | Trust your developer profile in Settings → General → VPN & Device Management. |
| App won't launch after a week | A Personal Team profile expired (7 days). Rebuild and run from Xcode. |
| Band not found | Bring it close. If the official app is connected, the band may not advertise. Forma also lists bands already connected to the iPhone. Turn on "Show all nearby Bluetooth devices" in the picker. |
| A pairing prompt appears | The band requires an encrypted link. Accept it to let iOS manage the bond. Forma can't and won't bypass it. |
| Background writes fail after a reboot | Expected until the first unlock: the database uses "complete until first user authentication" protection. |
