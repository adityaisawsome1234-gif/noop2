# iOS rules for Forma: BLE background, restoration, AccessorySetupKit, bonding, storage, install, power

Research date: 2026-11-08. Target: iPhone 16 Pro, iOS 27.x, own WHOOP 5.0 band (vendor GATT service, maybe 0x180D), no server.
Current versions found: iOS 27.2 released, iOS 27.3 beta; Xcode 27.2 released, Xcode 27.3 beta.

How the sources were checked:
- developer.apple.com/documentation pages were read on 2026-11-08 through Apple's markdown mirror
  (`https://developer.apple.com/tutorials/data/documentation/<path>.md`). These pages carry no visible date, so the
  "Context" lines below give the API availability metadata instead.
- TN3115 was fetched again live and is byte-identical to the earlier copy (revision 2025-09-15).
- Forum quotes come only from posts with Apple Staff, Engineer or DTS badges. The forum pages show month and year only.
- The Accessory Design Guidelines PDF is R32 Update 1. Its page footer is dated 2026-10-30 and the file's Last-Modified header is 2026-11-01.
- Tags: **UNCONFIRMED** means no Apple primary source was found, or Apple sources conflict.
  **INFERRED** means the point follows from Apple statements but Apple doesn't say it directly.
- Raw copies of the fetched pages were kept in the research workspace (`research/raw/` from the earlier run, `research/raw2/` from this one; forum fetches not saved). They are not part of this repository; the quotes and URLs above are the record.

---------------------------------------------------------------------------------------------------

## 1. `bluetooth-central` background mode

**1.1 What wakes the app in the background**
- Rule: "While your app is in the background you can still discover and connect to peripherals, and explore and
  interact with peripheral data. In addition, the system wakes up your app when any of the CBCentralManagerDelegate or
  CBPeripheralDelegate delegate methods are invoked, allowing your app to handle important central role events, such as
  when a connection is established or torn down, when a peripheral sends updated characteristic values, and when a
  central manager's state changes."
- URL: https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
- Context: This is the archived Core Bluetooth Programming Guide, last updated 2013-09-18. Apple DTS still cited it as authoritative in Aug 2026 (forum thread 840468).
- Forma: Subscribed notifications from the band wake a suspended Forma. This works for the vendor stream characteristic or 0x2A37. Disconnect and reconnect also wake it. This is how continuous collection works.

**1.2 Declaring the mode and the usage string**
- Rule: "Uses Bluetooth LE accessories | `bluetooth-central` | The app communicates with a Bluetooth accessory while in
  the background." Separately: "Your app will crash if its `Info.plist` doesn't include usage description keys ... To
  access Core Bluetooth APIs on apps linked on or after iOS 13, include the ... NSBluetoothAlwaysUsageDescription key."
- URL: https://developer.apple.com/documentation/xcode/configuring-background-execution-modes ;
  https://developer.apple.com/documentation/corebluetooth
- Context: Current documentation pages.
- Forma: Set `UIBackgroundModes=[bluetooth-central]` and `NSBluetoothAlwaysUsageDescription`. Whether the usage string can be dropped when the app uses AccessorySetupKit (ASK) is UNCONFIRMED, so keep it.

**1.3 A pending connect never times out**
- Rule: "Attempts to connect to a peripheral don't time out. To explicitly cancel a pending connection to a peripheral,
  call the cancelPeripheralConnection(_:) method. Deallocating `peripheral` also implicitly calls
  cancelPeripheralConnection(_:)." The programming guide adds: "because connection requests do not time out, the iOS device will
  reconnect when the user returns home."
- URL: https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/connect(_:options:) ; the guide URL from 1.1
- Context: iOS 5 and later. Still current.
- Forma: Call `connect()` again immediately on every disconnect and keep a strong reference to the `CBPeripheral`. This is the main reconnection mechanism. Store the peripheral UUID and use `retrievePeripherals(withIdentifiers:)` at launch.
- Related: `CBConnectPeripheralOptionEnableAutoReconnect` (iOS 17 and later) says: "After a peripheral device connects, this setting enables
  the system to initiate a connection to the peer device automatically when the link drops."
  (https://developer.apple.com/documentation/corebluetooth/cbconnectperipheraloptionenableautoreconnect). How this option interacts with state restoration is UNCONFIRMED.

**1.4 Background scanning needs a service UUID, and duplicate reporting is ignored**
- Rule: "Your app can scan for Bluetooth devices in the background by specifying the `bluetooth-central` background
  mode. To do this, your app must explicitly scan for one or more services by specifying them in the `serviceUUIDs`
  parameter. The CBCentralManager scan option has no effect while scanning in the background."
  The guide says: "The CBCentralManagerScanOptionAllowDuplicatesKey scan option key is ignored, and multiple discoveries of an
  advertising peripheral are coalesced into a single discovery event." and "If all apps that are scanning for
  peripherals are in the background, the interval at which your central device scans for advertising packets
  increases."
  An Apple Engineer added in Apr 2026 (thread 824822): "If the services parameter is nil, the scan will not work when the app goes to
  the background." and "both these rates will further slow down when the phone screen goes off, and even further down
  after a while when the phone goes to sleep mode."
  An Apple Engineer added in Feb 2026 (thread 815189): background scanning "will not read secondary advertisement packets (SCAN_RSP) unless
  the app is in the foreground and in use."
- URL: https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/scanforperipherals(withservices:options:) ;
  https://developer.apple.com/forums/thread/824822 ; https://developer.apple.com/forums/thread/815189
- Context: Current documentation and 2026 Apple Engineer replies.
- Forma: For background rediscovery, filter the scan on a UUID that WHOOP 5.0 puts in its primary advertising PDU, not in the scan response. Which UUID that is remains UNCONFIRMED and needs a hardware check. Prefer a pending `connect()` on the known identifier over scanning.

**1.5 Processing time per wake-up**
- Rule: "Upon being woken up, an app has around 10 seconds to complete a task. Ideally, it should complete the task as
  fast as possible and allow itself to be suspended again. Apps that spend too much time executing in the background
  can be throttled back by the system or killed." (programming guide, 1.1 URL).
  Argun Tekant (DTS) wrote in Jun 2025 (thread 786399): "When woken up with the BLE notification the app will be given about 10
  seconds to finish its work." He also wrote: "States restoration is good, but you still have the 10 second limitation, so you will
  want the app startup in response to restoration to be as quick and efficient as possible." He also wrote: "Silent push
  notifications will not help in this situation." and "the only viable way to implement such a system in a
  deterministic fashion is to control everything from the peripheral ... Once disconnected the peripheral should start
  advertising as fast as it can."
- URL: https://developer.apple.com/forums/thread/786399
- Context: The ~10 s budget is stated in Apple guidance from 2013 and again in 2025.
- Forma: On each notification, parse the frame, append it in a short SQLite transaction, then return. Don't run analytics or heavy work on a background wake. Defer that to the foreground or a `BGProcessingTask`.
- Guideline from the same guide: "Apps should be session based and provide an interface that allows the user to decide when to start
  and stop the delivery of Bluetooth-related events." Forma should have an explicit Start/Stop collection toggle.

**1.6 Live Activities give Core Bluetooth foreground-level privileges, but only while the screen is on**
- Rule: "In iOS 26 and later, your app can continue certain activities in the background if the app starts a Live
  Activity before it goes to the background. If your app has an instantiated CBManager and starts a Live Activity, it
  can use the same privileges while in the background that it uses when it is in the foreground. This means activities
  like scanning without providing service UUID's and scanning with duplicates filter disabled will be allowed while in
  the background."
  An Apple Engineer added in Feb 2026 (thread 815189, accepted answer): "on a locked screen which is turned off even the Live
  Activity is no longer sufficiently in use, so the scanning behavior will change. There are no supported workarounds
  for this limitation."
  ActivityKit says: "A Live Activity can be active for up to eight hours ... a Live Activity remains on the Lock Screen for a
  maximum of 12 hours." and "In general, your app needs to be in the foreground to start a Live Activity."
- URL: https://developer.apple.com/documentation/corebluetooth ; https://developer.apple.com/forums/thread/815189 ;
  https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Context: iOS 26 and later.
- Forma: This can support an optional "live session" or workout mode that lasts 8 hours or less. It does not solve 24/7 collection. Notifications on an existing connection don't need it.

**1.7 Background reads, writes and pairing need the background entitlement**
- Rule: "Pairing and Characteristic Value reads/writes may fail if the application owning the service is not in the
  foreground and is not entitled to run in the background." (Accessory Design Guidelines §57.14)
- URL: https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf
- Context: Accessory Design Guidelines (ADG) R32 Update 1, 2026-10-30.
- Forma: Any command or acknowledgement writes in the WHOOP sync protocol depend on `bluetooth-central`.

**1.8 Notification-rate limit**
- `CBError.Code.leGattExceededBackgroundNotificationLimit` and `leGattNearBackgroundNotificationLimit` exist only on
  watchOS 9 and later (availability metadata). No iOS background notification cap is documented. Whether iOS has one is UNCONFIRMED.

## 2. State preservation and restoration, and the TN3115 relaunch rules

**2.1 Opt-in and a constant identifier. Launch options are nil in scene-based apps (which includes SwiftUI)**
- Rule: "The system uses this UID to identify a specific CBCentralManager, so the UID must be identical across
  executions of the app. In scene-based apps that adopt UISceneDelegate, `launchOptions` is always `nil` on launch, so
  `UIApplicationLaunchOptionsBluetoothCentralsKey` is not available to deliver identifiers. Persist the UID yourself
  (for example, in UserDefaults) and pass it to init(delegate:queue:options:) on every launch."
- `UIApplication.LaunchOptionsKey.bluetoothCentrals` availability is "iOS 7.0-26.0", so it is deprecated in 26.0.
- The iOS 27 release notes (UIKit deprecations) say: "Apps built with the latest SDK must adopt the scene-based life cycle or they fail to
  launch."
- URL: https://developer.apple.com/documentation/corebluetooth/cbcentralmanageroptionrestoreidentifierkey ;
  https://developer.apple.com/documentation/corebluetooth/central-manager-state-restoration-options ;
  https://developer.apple.com/documentation/uikit/uiapplication/launchoptionskey/bluetoothcentrals ;
  https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes
- Context: iOS 26 and 27. This matters with the Xcode 27 / iOS 27 SDK.
- Forma: Create the single `CBCentralManager` at process start, before any UI, with a hard-coded restore ID. Never base it on launch options.
- Kevin Elliott (DTS) wrote in Aug 2026 (thread 840468): "A non-constant value can end up generating the problem you're seeing, as
  you end up trying to restore a different central than your original one."

**2.2 What the system preserves, and the delegate order**
- Rule: The system preserves "The services the central manager was scanning for (and any scan options specified when the scan started)",
  "The peripherals the central manager was trying to connect to or had already connected to" and "The characteristics the central manager was
  subscribed to".
  `willRestoreState` is described this way: "The system invokes this method when relaunching your app to service active or pending
  connections and scans that were in progress when your app stopped ... If the system calls this method but the
  parameters are missing ..., your app is responsible for restoring its previous state."
  The guide adds: "these are the first methods (centralManager:willRestoreState: ...) invoked when your app is relaunched".
- URL: https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager(_:willrestorestate:) and the guide URL from 1.1
- Forma: In `willRestoreState`, set the peripheral delegates again. Check which services and characteristics are already discovered and notifying before discovering again.

**2.3 The TN3115 relaunch table, quoted exactly**
- URL: https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules
- Revision history: "2025-09-15 Updated for iOS 26 and iPadOS 26." / "2022-02-08 Republished as TN3115." /
  "2017-09-08 First published as QA1962." The live page was rechecked on 2026-11-08 and is unchanged.

  | App or Device State | Will the app be relaunched? |
  |---|---|
  | App suspended in memory | (see note 1) |
  | App removed from memory | **Yes** |
  | App crashed | **Yes** |
  | App Force Quit by the user | **No** (see note 5) |
  | Bluetooth power toggled | **No** (see note 2) |
  | Control Center Bluetooth button toggled | **Yes** (see note 5) |
  | Airplane Mode toggled | **Yes** (see note 3) |
  | Device restarted | **Yes** (see note 4) |

  Notes, quoted exactly:
  1. "App will be activated without needing a relaunch."
  2. "Users may toggle Bluetooth power through Settings"
  3. "Only if Bluetooth is not toggled with Airplane Mode. Users may configure the Airplane Mode switch to not toggle Bluetooth. Also, see note 5."
  4. "If the device requires a passcode to unlock, apps will not be relaunched until the device is unlocked for the first time after a restart."
  5. "Starting in iOS 26 and iPadOS 26, only apps that use AccessorySetupKit to setup Bluetooth accessories will be relaunched."

  It also says: "your app will be relaunched and restored **if and only if** it's waiting for a specific Bluetooth event or
  action (like scanning, connecting, or a subscribed notification characteristic, and for peripheral apps, actively
  advertising), and the corresponding Bluetooth event has occurred."
- An Apple Engineer added in Jun 2026 (thread 836150): "your app must be pending on an event at the time of termination for it to be
  relaunched - for example must be scanning or waiting to connect when the peripheral restarts advertising - and same
  for I/O".

**2.4 How Apple explains note 5 (force quit)**
- An Apple Engineer wrote in Nov 2025 (thread 806013): "Note 5, only pertains to the specific cases where Note 5 is referred to, namely: if the
  app Force Quit by the user; Control Center Bluetooth button toggled. An app that was force quit was never able to be
  relaunched before. iOS 26 actually adds the capability for such apps to be launched if they opt in to use
  AccessorySetupKit. So, this is not a case of apps losing the capability to relaunch".
- Richard Yeh (DTS) wrote in Sep 2026 (thread 844477): "Force quitting will not cause Bluetooth State Restoration to relaunch an app
  unless your app uses AccessorySetupKit and is running on iOS 26 and above."
- Kevin Elliott (DTS) wrote in Aug 2026 (thread 840468): "The default behavior of CoreBluetooth is that it would not relaunch apps that have
  been force-quit." He also wrote: "My understanding, per TN3115, is that AccessorySetupKit will relaunch force-quit apps."
  In the same thread, a developer reports no relaunch after force quit on iOS 26.5 with ASK. That thread is unresolved, so real-world behavior is **UNCONFIRMED**.
- URLs: https://developer.apple.com/forums/thread/806013 ; https://developer.apple.com/forums/thread/844477 ;
  https://developer.apple.com/forums/thread/840468 ; https://developer.apple.com/forums/thread/836150

**2.5 Scenarios Forma asked about**

| Scenario | Rule | Source |
|---|---|---|
| User force-quit | Plain Core Bluetooth: **No**. With ASK on iOS 26 and later: **Yes** per the docs, but field reports are mixed | TN3115 notes 5 and 2.4 |
| Reboot, before first unlock | Not relaunched until the first unlock (when a passcode is set) | TN3115 note 4 |
| Reboot, after first unlock | **Yes**, if the app was pending on an event | TN3115 |
| Bluetooth toggled in Settings | **No** | TN3115 note 2 |
| Bluetooth toggled in Control Center | **Yes** (note 5). Whether non-ASK apps still relaunch on iOS 26 and later is **UNCONFIRMED**: the TN3115 wording and the Apple Engineer's reading conflict | TN3115 and 806013 |
| Airplane Mode | **Yes**, only if Bluetooth isn't switched off with it | TN3115 note 3 |
| Low Power Mode | Not covered by TN3115, and no Apple statement found. **UNCONFIRMED**; see 7.1 | none |
| App update | Not covered by TN3115. Argun Tekant (DTS) wrote in Sep 2024 (thread 764113): "We believe you might be running into an edge case where restoration fails" (FB15332799). **UNCONFIRMED / not supported** | https://developer.apple.com/forums/thread/764113 |
| Bluetooth permission revoked | Not covered. `CBManagerState.unauthorized`: "A state that indicates the application isn't authorized to use the Bluetooth low energy role." **UNCONFIRMED** | https://developer.apple.com/documentation/corebluetooth/cbmanagerstate/unauthorized |
| Memory-pressure kill or crash | **Yes** | TN3115 |

- Forma:
  - Always keep a pending `connect()` or an active subscription, so the app has something to be relaunched for.
  - Tell users not to swipe the app away unless ASK is used.
  - After an app update, show a prompt to open the app.
  - Handle `.unauthorized` and `.poweredOff` on every launch.
- Testing tip from Kevin Elliott (DTS), Aug 2026: "In the 'Developer' settings, there's an option you can enable called 'Fast
  App Termination', which specifically exits apps shortly after they background (instead of just suspending them). Its
  primary purpose is to simplify testing state restoration". He also suggests posting a local notification early in launch to prove the relaunch happened.

## 3. AccessorySetupKit (ASK): iOS 18 and later, with changes in 26

**3.1 Purpose and per-accessory authorization**
- Rule: "Use AccessorySetupKit to discover and configure Bluetooth or Wi-Fi accessories with images and names provided
  by the app. Allow seamless, privacy-preserving user consent and control for Bluetooth, Wi-Fi, and Local Network
  permissions."
  WWDC24 10203 adds: "Since we declared AccessorySetupKit support in our Info.plist, unlike previous versions of iOS, people will not
  be asked for permission to use Bluetooth." and "People can modify the accessory name, toggle the access of its paired
  apps, or remove it from the system."
- URL: https://developer.apple.com/documentation/accessorysetupkit ; https://developer.apple.com/videos/play/wwdc2024/10203/
- Context: iOS 18.0 and later (availability metadata). WWDC session from June 2024.

**3.2 Info.plist keys**
- `NSAccessorySetupKitSupports`: "An array of strings that indicates the wireless technologies AccessorySetupKit uses"
  (`Bluetooth`, `WiFi`). If the array includes `Bluetooth`, three more keys are needed:
  - `NSAccessorySetupBluetoothServices`: "Each value is a 16- or 128-bit UUID that represents either a Bluetooth
    Special Interest Group (SIG)-registered service or a custom service."
  - `NSAccessorySetupBluetoothNames`: "Each entry is a full or partial name which the accessory advertises".
  - `NSAccessorySetupBluetoothCompanyIdentifiers`: "Each identifier is a two-byte UUID that represents a company
    identifier as registered on the Bluetooth SIG website".
- Rule: "If your app tries to discover Bluetooth accessories during setup without supplying these keys and values, or
  uses identifiers, names, or services that it doesn't include in its information property list, the app crashes. This
  only affects use of AccessorySetupKit discovery and selection; you can use other services and properties on the
  accessory after the person using the app selects it."
- URL: https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories ;
  https://developer.apple.com/documentation/bundleresources/information-property-list/nsaccessorysetupkitsupports ,
  then the same path with `.../nsaccessorysetupbluetoothservices`, `.../nsaccessorysetupbluetoothnames` and
  `.../nsaccessorysetupbluetoothcompanyidentifiers`.
- Forma: Put the WHOOP 5.0 advertised service UUID and/or company ID, plus a name substring, in Info.plist. The exact values come from hardware captures.

**3.3 `ASDiscoveryDescriptor`**
- Rule: "Each display item's descriptor ... needs to have a bluetoothCompanyIdentifier or bluetoothServiceUUID, and at
  least one of the following accessory identifiers: bluetoothNameSubstring; A bluetoothManufacturerDataBlob and
  bluetoothManufacturerDataMask set to the same length; A bluetoothServiceDataBlob and bluetoothServiceDataMask ...;
  Either ssid or ssidPrefix".
  The class reference table instead lists the name substring as "Optional". Because Apple's docs conflict, include a name substring anyway. Which rule is enforced is **UNCONFIRMED**.
  "set its value to ASDiscoveryDescriptor.Range.immediate to limit discovery of Bluetooth accessories to those within the
  immediate proximity".
- URL: https://developer.apple.com/documentation/accessorysetupkit/asdiscoverydescriptor
- A developer report from 2024 (thread 758624) says a 0x180D-only descriptor didn't show nearby heart-rate straps unless they were already connected in Settings (FB14078940). There was no Apple reply, so this is **UNCONFIRMED**.

**3.4 `ASAccessorySession` lifecycle**
- The sequence is `activate(on:eventHandler:)`, then `.activated`, then `session.accessories` ("An array of previously-selected accessories for this
  application"), then `showPicker(for:)`, which produces `.accessoryAdded` followed by `.pickerDidDismiss`. Later events are `.accessoryChanged` and `.accessoryRemoved`, and the session ends with `invalidate()`.
- Accessory states are `unauthorized`, `awaitingAuthorization` and `authorized`.
- `ASError.Code.pickerRestricted`: "The picker can't be used because the app is in the background."
- Setup options: `confirmAuthorization`: "If the accessory supports bluetoothPairingLE, then the app needs to start pairing by
  accessing a protected GATT characteristic."
- iOS 26 and 26.1 additions, all from availability metadata:
  - `ASPickerDisplaySettings` (26.0): "discoveryTimeout ... Default is 30 seconds".
  - `updateAuthorization(for:descriptor:)` (26.0, for Wi-Fi Aware).
  - `ASDiscoveredAccessory`, `updatePicker(showing:)` and `finishPickerDiscovery` (26.1): custom filtering of discovery results.
  - watchOS 26 companion apps can use accessories set up through ASK.
- iOS 27: there are no ASK entries in the iOS 27, 27.2 or 27.3-beta release notes (checked).
- URL: https://developer.apple.com/documentation/accessorysetupkit/asaccessorysession ; .../aserror/code ;
  .../aspickerdisplaysettings ; .../asdiscoveredaccessory

**3.5 How ASK interacts with `CBCentralManager`**
- WWDC24 10203:
  - "AccessorySetupKit takes care of discovery and authorization, while the communication is still handled with CoreBluetooth".
  - "The CBCentralManager state will only become poweredOn when your app has paired accessories."
  - "Only accessories paired with your app will be returned in the scan results."
- The guide says: "Because the app discovered the device with AccessorySetupKit, connecting to the device won't invoke the TCC or
  other alerts".
- An Apple Engineer wrote in Jan 2026 (thread 811101): "AccessorySetupKit and original CoreBluetooth actions are mutually exclusive.
  ... If ASK is involved CBCentralManager will only work with accessories discovered that way."
- Argun Tekant (DTS) wrote in the same thread: a `CBCentralManager` dropping to poweredOff after a second picker was "a known issue with iOS 18,
  but has since been fixed in iOS 26". Developers report it still happens on 26.2 and 26.3, so the fix is **UNCONFIRMED**.
- Connecting, subscribing and restoration still go through Core Bluetooth, using `ASAccessory.bluetoothIdentifier` with `retrievePeripherals`.
- URL: https://developer.apple.com/forums/thread/811101
- Forma: Choose ASK or plain Core Bluetooth for each build. An ASK build can't scan generically for 0x180D straps. Each device must go through the picker.

**3.6 Entitlement**
- None is documented. Only Info.plist keys appear in the ASK overview, the guide and WWDC24, and ASK has no entry in the iOS capabilities table. So no entitlement or capability appears to be needed. This is **INFERRED**.

**3.7 Relaunch and background differences**
- ASK apps on iOS 26 and later can be relaunched after a force quit or a Control Center Bluetooth toggle. See TN3115 note 5 and 2.4.
- The picker only works in the foreground.

**3.8 Migration**
- Rule: You can migrate a previously used peripheral with `ASMigrationDisplayItem.peripheralIdentifier`. "Don't initialize a CBCentralManager before migration is complete. If you
  do, your callback handler receives an error and the picker fails to appear."
  WWDC24 adds: "If the showPicker call contained only migration items, an informational page is shown on top of your app".
  The Apple Engineer in thread 811101 (Jan 2026) said: "Apps can one-time migrate all accessories using the migration flow".
- URL: https://developer.apple.com/documentation/accessorysetupkit/asmigrationdisplayitem
- Forma: If v1 ships with plain Core Bluetooth, a later ASK build must activate the `ASAccessorySession` and finish migration before it creates the central manager.

**3.9 Removal is system-wide**
- Argun Tekant (DTS) wrote in Jan 2025 (thread 772102): "Yes, removeAccessory() will remove it from the system and for all apps. This
  is by design ... If the accessory is shared by multiple apps, the removal is not automatic, and the user will be
  prompted and they will be notified that if they go ahead the device will be gone from the system."
- URL: https://developer.apple.com/forums/thread/772102
- Forma: Never call `removeAccessory` as an ordinary "forget". It could unpair the band from the official WHOOP app as well.

**3.10 Using ASK from a third-party app for another company's band that the official app already uses**
- ASK needs the accessory to advertise a company identifier or service UUID. The Apple Engineer in thread 811101 described unsupported accessories as ones that "do not advertise a company identifier or service UUID".
- The picker shows "the hardware name the accessory advertises over the air" (WWDC24).
- These points are **UNCONFIRMED** and need hardware tests:
  1. Whether WHOOP 5.0 keeps advertising while it is connected to the official app. The picker can only list devices that are advertising.
  2. How the picker behaves if the official app used ASK. A third-party report (Punch Through) says the picker offers to "share" the accessory. No Apple source confirms it.
  3. Whether ASK pairing changes the band's existing bond.
- App Review and intellectual-property policy were not researched, because this is a personal build and won't be distributed.

## 4. Bonding and encryption on iOS

**4.1 Pairing is triggered by an encrypted characteristic**
- ADG §57.10 says: "The accessory should not request pairing until an ATT request is rejected using the Insufficient
  Authentication error code ... If, for security reasons, the accessory requires a bonded relationship with the Central,
  the Peripheral should reject the ATT request using the Insufficient Authentication error code, as appropriate. As a
  result, the device may proceed with the necessary security procedures."
- ADG §57.9 says: "The accessory should not require special permissions, such as pairing, authentication, or
  encryption, to discover services and characteristics."
- Argun Tekant (DTS) wrote in Aug 2025 (thread 798665): "If you tried to access the encrypted characteristic right after connection, if
  the device are not paired, that will trigger the pairing procedure. If the pairing is successful, you will be able to
  access the characteristic. Otherwise, it will fail." He also wrote: "there also isn't a way to detect how that went".
- URL: https://developer.apple.com/accessories/Accessory-Design-Guidelines.pdf (R32 Update 1, 2026-10-30) ;
  https://developer.apple.com/forums/thread/798665
- Forma: Do the first subscribe or read in the foreground, in case the system shows a pairing alert. Treat ATT `insufficientAuthentication` / `insufficientEncryption` as "pairing needed or declined".

**4.2 Bonds are system-level, not per app**
- An Apple Engineer wrote in Jul 2026 (thread 839787): "There is no API to remove the keys by an app. As the LTK is strictly managed at
  the system level, the only way to remove them is by the user manually 'forgetting' the paired device in System
  Settings."
- An Apple Engineer wrote in Sep 2020 (thread 132488) about `peerRemovedPairingInformation`: "the remote accessory has lost the pairing keys,
  and this device will no longer connect to it unless the user forgets the device from Settings first."
- Whether a bond made by the official app is reused when Forma connects is **INFERRED**. The keys are system-level and the link is shared (4.3), but Apple doesn't state it in so many words.
- URL: https://developer.apple.com/forums/thread/839787 ; https://developer.apple.com/forums/thread/132488
- Forma: Expect no second pairing prompt if the iPhone is already bonded to the band. Forma can't re-pair or unpair. On `CBError.peerRemovedPairingInformation`, tell the user to Forget the band in Settings. That also affects the WHOOP app.
- Related error codes: `peerRemovedPairingInformation` and `encryptionTimedOut` (iOS 13.4 and later), `tooManyLEPairedDevices` (iOS 14 and later).

**4.3 Several apps can be connected to the same peripheral at once**
- `retrieveConnectedPeripherals(withServices:)`: "The list of connected peripherals can include those that other apps
  have connected. You need to connect these peripherals locally using the connect(_:options:) method before using them."
- `cancelPeripheralConnection(_:)`: "Because other apps may still have a connection to the peripheral, canceling a local
  connection doesn't guarantee that the underlying physical link is immediately disconnected."
- Argun Tekant (DTS), Aug 2025: "There really isn't an API to force a disconnection from the application level".
- URL: https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:) ;
  https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection(_:)
- Forma: At launch, call `retrieveConnectedPeripherals` with the WHOOP service and then `connect()` locally. Disconnecting in Forma won't drop the band while the WHOOP app holds it.
- Whether the WHOOP firmware and protocol tolerate two GATT clients is **UNCONFIRMED**. The concern is two clients subscribing and sending commands with a shared command and response stream.

## 5. File protection for SQLite written during background BLE events, and backup exclusion

**5.1 The protection classes**
- "Complete until first user authentication. (Default) The file is inaccessible until the first time the user unlocks the device.
  After the first unlocking of the device, the file remains accessible until the device shuts down or reboots."
- "Complete unless open. You can open existing files only when the device is unlocked. If you have a file
  already open, you may continue to access that file even after the user locks the device. You can also create new
  files and access them while the device is locked or unlocked."
- "Complete. The file is accessible only when the device is unlocked."
  (Source: https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)
- The Platform Security guide (published Dec 19, 2024) adds detail on each class:
  - Complete Protection: "Shortly after the user locks a device (10 seconds, if the Require Password setting is
    Immediately), the decrypted class key is discarded".
  - Protected Until First User Authentication: "This is the default class for all third-party app data not otherwise assigned".
  - Protected Unless Open: "As soon as the file is closed, the per-file key is wiped from memory."
  (Source: https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)
- `completeUnlessOpen`: "once closed, cannot be opened again until the device is unlocked."
  (Source: https://developer.apple.com/documentation/foundation/fileprotectiontype/completeunlessopen)
- The encryption guide also says: "If your app supports background capabilities ... assign a different protection level for files that you might access while
  in the background. For example, a fitness app might use the complete unless open protection level on a file that it
  uses to log location events in the background."

**5.2 SQLite under data protection**
- Ziqiao Chen (DTS) wrote in Jun 2024 (thread 756604, accepted answer) about `SQLITE_IOERR_SHMOPEN`: "SQLite hit the error when it tried to open or create a
  `.shm` file ... one common reason that triggers an I/O error is that the file is data-protected ... Your app sets the
  data protection level to .complete, but then tries to access the file when running in the background. Your app is
  launched into the background and tries to access the file after the user reboots and hasn't unlocked the device."
- URL: https://developer.apple.com/forums/thread/756604
- **The -wal and -shm files.** SQLite creates and opens these side files on its own schedule, and each file has its own protection class.
  - How Apple's SQLite assigns classes to them is **UNCONFIRMED**.
  - So is whether Apple's `sqlite3.h` provides `SQLITE_OPEN_FILEPROTECTION_*` open flags. Check the SDK header on the Mac.
  - Under complete-unless-open, a side file that has been closed and must be opened again while the device is locked will fail. That follows from the Class B rule in 5.1.
- Forma:
  - Put the database in its own folder under Application Support.
  - Set the folder, the database, the -wal file and the -shm file to `completeUntilFirstUserAuthentication`.
  - Keep one long-lived connection.
  - Never use `.complete` for the live database.
  - Check for lost access with `applicationProtectedDataWillBecomeUnavailable(_:)` / `isProtectedDataAvailable`.
  - TN3115 note 4 means there is no Bluetooth relaunch before first unlock, which lines up with this class.

**5.3 Holding a lock during suspension gets the app killed (0xdead10cc)**
- Rule: "`0xdead10cc` ... The operating system terminated the app because it held on to a file lock or SQLite database lock during
  suspension. Request additional background execution time on the main thread with beginBackgroundTask(withName:expirationHandler:). Make this
  request well before starting to write to the file in order to complete those operations and relinquish the lock
  before the app suspends."
- URL: https://developer.apple.com/documentation/xcode/sigkill
- Forma: Wrap each write after a BLE wake in `beginBackgroundTask` / `endBackgroundTask`. Commit before returning. Never leave a write transaction open.

**5.4 Default protection entitlement**
- `com.apple.developer.default-data-protection`: "To add this entitlement to your app, enable the Data Protection
  capability in Xcode." The free Apple Developer account can use it (capabilities table, 6.2).
- URL: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.default-data-protection
- Forma: Don't set the app-wide default to Complete.

**5.5 `isExcludedFromBackup`**
- The property docs say: "This property is only useful for excluding cache and other application support files which are not needed in a backup.
  Some operations commonly made to user documents will cause this property to be reset to false and so this property
  should not be used on user documents."
  (Source: https://developer.apple.com/documentation/foundation/urlresourcevalues/isexcludedfrombackup)
- Apple's iCloud Backup optimization article says three things:
  - It's "not a mechanism to guarantee those items never appear in a backup or on a restored device".
  - "Because certain file operations can reset resource values, make sure you set an excluded file's resource values each time
    you save it."
  - Put related files in a directory and set "the directory's isExcludedFromBackup resource value".
  (Source: https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)
- Scope:
  - iCloud backups and computer backups. The archived File System Programming Guide (updated 2018-04-09) says: "files in Documents/
    and Application Support/ are backed up by default. You can exclude files from the backup by calling -[NSURL
    setResourceValue:forKey:error:] using the NSURLIsExcludedFromBackupKey key". The guide's table describes those
    directories as "backed up by iTunes and iCloud".
    (Source: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
  - That the same applies to Finder backups is **INFERRED**, since Finder replaced iTunes.
  - Device-to-device (Quick Start) migration has no Apple statement, so it is **UNCONFIRMED**. A developer reports that excluded files were not copied in iPhone-to-iPhone migration or an iTunes backup and restore (thread 749467, Apr 2024, no Apple reply). Thread 853078 from 2026 is also unanswered.
- Forma: Excluding the database keeps health data out of iCloud Backup. It also means the history is probably lost when the user moves to a new phone. If excluded, Forma needs an explicit local export and import. Set the exclusion on the directory and apply it again after each save. Note the trade-off in the privacy doc.

## 6. Installing a personally built app on your own iPhone in 2026

**6.1 Free Personal Team**
- Rule: "You can register up to 10 App IDs, which expire after 7 days. You can register up to 3 devices, which expire
  after 7 days. You can install up to 3 apps per device. Provisioning profiles that enable apps to be installed on a
  device will expire 7 days from issuance. You'll need to rebuild and reinstall your app to your device after
  expiration."
- URL: https://developer.apple.com/help/account/basics/about-your-developer-account/
- Context: This is current. The old URL `/support/compare-memberships/` now redirects here.
- Forma:
  - Rebuild and reinstall at least every 7 days. Once the profile expires the app can't launch, so background collection stops.
  - Show the profile expiry date in the app. Reading `embedded.mobileprovision` to get it is **UNCONFIRMED**.
  - A widget or Live Activity extension probably uses one more App ID. That is **INFERRED**.
- Before an app from a free account will run, iOS shows "Untrusted Developer" and you must trust it under Settings > General > VPN & Device Management. This comes from forum and third-party sources only; no Apple doc was found, so it is **UNCONFIRMED**.

**6.2 Capabilities by membership**
- The capabilities table has three columns: paid Apple Developer Program (ADP), Enterprise Program (ADEP), and free "Apple Developer". Rows relevant to Forma:
  - Allowed for the free account: "Background modes", "Data protection", HealthKit, App groups, Keychain sharing and "Wireless Accessory Configuration".
  - Paid only: Push notifications, iCloud, Time Sensitive Notifications and Sign in with Apple.
- Core Bluetooth needs no capability, just the Info.plist usage key. ASK has no capability either (3.6). So `bluetooth-central` plus ASK should work with a free team. That is **INFERRED**; no Apple statement says it.
- "Sustained Execution" (paid only) is `com.apple.developer.sustained-execution`. It is described as "performs consistently when the
  system constrains it to a sustainable performance level". It is a GPU and performance setting, **not** background runtime, so it is irrelevant here.
- URL: https://developer.apple.com/help/account/reference/supported-capabilities-ios/

**6.3 Paid Apple Developer Program**
- Price: "The Apple Developer Program is 99 USD per membership year."
  (Source: https://developer.apple.com/programs/enroll/)
- Devices: "register up to 100 of the following devices, per product family, per membership year".
  (Source: https://developer.apple.com/help/account/devices/devices-overview/)
- Profile check-in: "New Apple Developer Program memberships created after June 6, 2021, require development- and ad-hoc-signed
  apps ... to check in with the PPQ service when the app is first launched. Your device must be connected to the
  internet". Offline profiles are "valid for 7 days".
  (Source: https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates/)
  This check-in is done by iOS. It isn't app networking, but first launch needs a network connection.
- How long a paid development profile stays valid isn't stated on the Apple pages fetched. It is commonly said to be about 1 year, ending no later than the certificate or membership. **UNCONFIRMED**.

**6.4 Developer Mode**
- Rule: "Enable Developer Mode on a device to run your app on the device through Xcode ... The feature doesn't affect
  ordinary installation techniques, such as buying apps from the App Store or participating in a TestFlight team."
- Steps: Settings > Privacy & Security > Developer Mode, then Restart, then Enable and enter the passcode. "Developer Mode only appears in
  Settings if you initiate pairing or if you previously paired the device to a Mac."
- URL: https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device

**6.5 TestFlight**
- Rule: "You can test a build for up to 90 days." and "Your build becomes unavailable for testers after 90 days."
- TestFlight needs the paid program and an App Store Connect upload. "If you invite external testers, your beta build may require review."
- URL: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/

**6.6 Xcode for iOS 27 devices**
- The Xcode 27 release notes say: "Xcode 27 includes Swift 6.4 and SDKs for iOS 27 ... Xcode 27 supports on-device debugging in iOS 17 and later
  ... Xcode 27 requires a Mac running macOS Tahoe 26.6 or later."
- The current release is Xcode 27.2: Swift 6.4, iOS 27.2 SDK, macOS Tahoe 26.6 or later. Xcode 27.3 is in beta.
- Language modes are Swift 6, 5, 4.2 and 4 (system requirements table).
- For comparison, Xcode 26.6 has Swift 6.3, the iOS 26.5 SDK, and lists "Device Support: iOS 15 or later". Whether Xcode 26.x can install and debug on iOS 27 is **UNCONFIRMED**, so use 27.x.
- Xcode 27 replaces the old devices window with Device Hub, which adds "a new way to pair iPhone ... running iOS 27 ... over a network".
- The iOS 27 SDK requires the scene-based app life cycle (2.1).
- URL: https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes ;
  https://developer.apple.com/documentation/xcode-release-notes/xcode-27_2-release-notes ;
  https://developer.apple.com/xcode/system-requirements/

## 7. Low Power Mode, battery, and iOS 26/27 background changes for continuous BLE collection

**7.1 Low Power Mode**
- Apple Support (published Sep 21, 2026) says:
  - "When the battery level gets low, Low Power Mode reduces background activity to extend battery life."
  - Among other things it "Sets Auto-Lock to 30 seconds" and "Turns off Background App Refresh".
  - "If your device supports Adaptive Power and it's turned on, Low Power Mode turns on when your battery goes below 20%."
  - "When you charge the device to 80% or higher, Low Power Mode turns off."
  - Bluetooth is not on the list.
  (Source: https://support.apple.com/en-us/101604)
- `ProcessInfo.isLowPowerModeEnabled` lists "Pausing discretionary and background activities." Apps can observe `NSProcessInfoPowerStateDidChange`.
  (Source: https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled)
- WWDC25 session 227 says users "influence scheduling by toggling settings like Low Power Mode, Background App Refresh, and Low Data Mode."
- Any effect of Low Power Mode on `bluetooth-central` wakes, notifications, scan rates or restoration is **UNCONFIRMED**. No Apple statement was found.
- Forma: Record the Low Power Mode state next to data gaps, reduce work when it's on, and test it on hardware. Users may have Adaptive Power switch it on automatically.

**7.2 `BGContinuedProcessingTask` (iOS 26)**
- Rule: "Unlike other BGTask subclasses, BGContinuedProcessingTask starts in the foreground. In addition, your app needs
  to run the task only in response to someone's action, such as tapping a button."
  Also: "The system displays the progress of this task in a Live Activity and a person can cancel it". Also: "The system cancels any
  running tasks if a person closes the app in the app switcher".
- WWDC25 227 gives examples like "completing an update on a connected accessory" and says "Avoid automatic workloads like maintenance, backups, or photo syncing."
- URL: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask ;
  https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados ;
  https://developer.apple.com/videos/play/wwdc2025/227/
- Forma: Use it only for a user-tapped "Download history from band" with progress. It is not a way to collect 24/7.

**7.3 `BGProcessingTask`**
- WWDC25 227 says it "enables apps to perform more complex work like running ML models or database maintenance ... you can configure it to run only
  when the device is on a charger".
- Forma: Run nightly analytics and database checkpoint/VACUUM while charging.

**7.4 Live Activity plus Core Bluetooth (iOS 26)**
- See 1.6. It works only while the screen is on and lasts at most 8 hours active, 12 hours on the Lock Screen.

**7.5 `LongRunningIntent` (new in iOS 27, App Intents)**
- Rule: "In iOS ... the system gives tasks 30 seconds to run in the background unless you use the methods of this protocol to
  extend that runtime." The intent must keep reporting progress: "If you don't update this property regularly, the system
  can cancel the background runtime extension".
- URL: https://developer.apple.com/documentation/appintents/longrunningintent
- Context: iOS 27.0 and later.
- Forma: Possibly a Shortcuts-triggered "sync now". It doesn't help with continuous collection.

**7.6 Other iOS 27 changes**
- Scene life cycle is mandatory (2.1).
- MetricKit: "CrashDiagnostic now includes a terminationCategory that maps to the corresponding case in ForegroundTerminationMetric and
  BackgroundTerminationMetric", and "A new Swift-first MetricManager API ... through AsyncStream".
  Forma can use this to diagnose background kills on the device, with no server.
- The iOS 27 Core Bluetooth release note covers only a Channel Sounding fix.
- The iOS 26.1–26.6, 27.2 and 27.3-beta release notes have no Core Bluetooth, ASK, BackgroundTasks, Low Power Mode or data-protection entries (searched).
- URL: https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes

**7.7 Force quit from the app switcher**
- WWDC25 227 says: "when someone removes your app from the app switcher, the system respects their intent."
- Forma: Combined with TN3115, a plain Core Bluetooth build stops collecting after a swipe-away until the user opens it again. Onboarding should say this. ASK on iOS 26 and later is the documented exception.

---------------------------------------------------------------------------------------------------

## Must test on the device (open items)
1. Which UUID or company ID WHOOP 5.0 advertises in its primary advertising PDU, and whether it keeps advertising while the WHOOP app is connected. This decides whether background rediscovery works and whether ASK can be used.
2. Whether its vendor characteristics are encrypted (pairing prompt), and whether the existing WHOOP-app bond is reused.
3. Whether the band and the official app tolerate a second client (Forma) subscribing and sending commands at the same time.
4. Relaunch with "Fast App Termination" for: memory kill, reboot then first unlock, Control Center toggle, Low Power Mode on, after an app update, and after force quit (plain Core Bluetooth versus ASK on iOS 27).
5. SQLite with WAL under `completeUntilFirstUserAuthentication`, with writes while locked over a 24-hour run. Check that no 0xdead10cc kills occur.
6. Whether the free-team 7-day expiry and reinstall keep the data container. This is expected, since a reinstall is an app update, but **UNCONFIRMED**.
