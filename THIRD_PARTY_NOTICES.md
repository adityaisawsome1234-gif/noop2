# Third-party notices

## Code

Forma contains **no third-party source code and no third-party package dependencies**. `FormaKit/Package.swift` declares none, and the Xcode project references only the local `FormaKit` package.

At runtime Forma uses only Apple system frameworks: SwiftUI, UIKit, Charts, Core Bluetooth, AccessorySetupKit, LocalAuthentication, Accessibility, UniformTypeIdentifiers, Observation and Foundation. It also uses the SQLite library that ships with iOS. SQLite is in the public domain (https://sqlite.org/copyright.html).

The Bluetooth SIG Heart Rate Service, Battery Service and Device Information Service parsers were written from the public Bluetooth specifications.

## Interoperability facts

Forma's WHOOP 5.0 adapter was written from **facts**: service and characteristic identifiers, frame layouts, checksum parameters, command numbers and byte offsets. Those facts were described by public interoperability projects. None of those projects' code is included. Four of the five projects consulted have no license grant (only whoop4-ble is MIT-licensed), so Forma's implementation is original. The projects consulted, their licenses, and what was used from each are listed in `docs/LICENSE_AUDIT.md`.

The test suite contains frame byte sequences that Forma derives itself from the documented algorithm. `Tools/verify-published-captures.sh` checks Forma's decoder against payloads published by the goose project. It downloads them at run time, and they are not redistributed here.

## Trademarks

"WHOOP" is a trademark of WHOOP, Inc. It is used only to identify compatible hardware. Forma is not affiliated with or endorsed by WHOOP, Inc.
