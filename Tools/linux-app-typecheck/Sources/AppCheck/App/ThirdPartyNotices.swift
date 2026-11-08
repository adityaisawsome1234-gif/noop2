import Foundation

/// Shown in Settings → About. Forma ships no third-party code; this text states that precisely.
enum ThirdPartyNotices {
    static let text = """
    Forma contains no third-party libraries. It uses Apple system frameworks and the SQLite library that is part of iOS (SQLite is in the public domain).

    Bluetooth protocol facts (service identifiers, frame layouts, command numbers) were learned from public interoperability research. Facts are not copyrightable and no code from those projects is included. Projects consulted are listed in docs/LICENSE_AUDIT.md in the source repository.

    "WHOOP" is a trademark of WHOOP, Inc., used only to identify compatible hardware.
    """
}
