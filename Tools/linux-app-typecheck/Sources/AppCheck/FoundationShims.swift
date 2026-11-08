// Apple-only Foundation APIs used by the platform files, stubbed for Linux type-checking.
import Foundation
public struct FileProtectionType: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let complete = FileProtectionType(rawValue: "complete")
    public static let completeUntilFirstUserAuthentication = FileProtectionType(rawValue: "cufua")
}
extension FileAttributeKey { public static let protectionKey = FileAttributeKey(rawValue: "NSFileProtectionKey") }
extension URLResourceValues { public var isExcludedFromBackup: Bool? { get { nil } set {} } }
extension URLResourceKey { public static let isExcludedFromBackupKey = URLResourceKey(rawValue: "NSURLIsExcludedFromBackupKey") }
public final class NSFileCoordinator {
    public struct ReadingOptions: OptionSet { public let rawValue: UInt; public init(rawValue: UInt) { self.rawValue = rawValue }; public static let forUploading = ReadingOptions(rawValue: 8) }
    public init() {}
    public func coordinate(readingItemAt url: URL, options: ReadingOptions = [], error outError: UnsafeMutablePointer<NSError?>?, byAccessor reader: (URL) -> Void) { reader(url) }
}
extension ProcessInfo { public func performExpiringActivity(withReason reason: String, using block: @escaping @Sendable (Bool) -> Void) { block(false) } }
