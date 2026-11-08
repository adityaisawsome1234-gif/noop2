# Linux type-check for the iOS app sources

`./run.sh` copies `App/Forma/**/*.swift` into a SwiftPM target and compiles it against the real FormaKit modules plus minimal stand-ins for Apple-only frameworks (SwiftUI, Charts, Core Bluetooth, AccessorySetupKit, LocalAuthentication, UIKit, UniformTypeIdentifiers, Accessibility, and a few Foundation APIs). This check was used because the build environment for this project had no Apple SDK.

**What it proves.** The app code is consistent with FormaKit's APIs and with itself: names, argument labels, optionality, closure signatures and main-actor isolation all line up.

**What it doesn't prove.** That the code compiles against Apple's SDKs. The stand-ins encode only the API shapes the app uses, as their author understood them. Xcode is the authority.
