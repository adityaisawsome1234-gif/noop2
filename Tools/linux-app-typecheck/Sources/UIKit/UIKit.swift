import Foundation
open class UIImage: NSObject, @unchecked Sendable {
    public override init() {}
    public init?(systemName: String) {}
    public init?(named: String) {}
}
public enum UIUserInterfaceStyle: Int { case unspecified, light, dark }
public enum UIAccessibilityContrast: Int { case unspecified, normal, high }
open class UITraitCollection: NSObject, @unchecked Sendable {
    open var userInterfaceStyle: UIUserInterfaceStyle { .light }
    open var accessibilityContrast: UIAccessibilityContrast { .normal }
}
open class UIColor: NSObject, @unchecked Sendable {
    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {}
    public init(dynamicProvider: @escaping @Sendable (UITraitCollection) -> UIColor) {}
}

// Responders, views, windows and scenes are main-actor isolated in the real SDK.
@MainActor open class UIResponder: NSObject {
    public override init() {}
}
@MainActor open class UIView: UIResponder {
    open var isHidden: Bool = false
    /// Declared on NSObject (UIAccessibility) in the real SDK.
    open var accessibilityViewIsModal: Bool = false
    open var overrideUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    @discardableResult open func endEditing(_ force: Bool) -> Bool { true }
}
@MainActor open class UIViewController: UIResponder {
    open var view: UIView! { UIView() }
    open var overrideUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
}
@MainActor open class UIScene: UIResponder {
    public enum ActivationState: Int { case unattached = -1, foregroundActive, foregroundInactive, background }
    open var activationState: UIScene.ActivationState { .foregroundActive }
}
@MainActor open class UIWindowScene: UIScene {
    open var windows: [UIWindow] { [] }
    open var keyWindow: UIWindow? { nil }
}
@MainActor open class UIWindow: UIView {
    public struct Level: RawRepresentable, Hashable, Sendable {
        public var rawValue: CGFloat
        public init(rawValue: CGFloat) { self.rawValue = rawValue }
        public static let normal = Level(rawValue: 0)
        public static let statusBar = Level(rawValue: 1000)
        public static let alert = Level(rawValue: 2000)
    }
    public init(windowScene: UIWindowScene) {}
    open weak var windowScene: UIWindowScene?
    open var windowLevel: UIWindow.Level = .normal
    open var rootViewController: UIViewController?
    open var isKeyWindow: Bool { false }
    open func makeKey() {}
    open func makeKeyAndVisible() {}
}
extension UIWindow.Level {
    public static func + (lhs: UIWindow.Level, rhs: CGFloat) -> UIWindow.Level { UIWindow.Level(rawValue: lhs.rawValue + rhs) }
    public static func - (lhs: UIWindow.Level, rhs: CGFloat) -> UIWindow.Level { UIWindow.Level(rawValue: lhs.rawValue - rhs) }
}
@MainActor open class UIApplication: UIResponder {
    open class var shared: UIApplication { UIApplication() }
    open var connectedScenes: Set<UIScene> { [] }
    /// SDK: `UIApplication.State` (active, inactive, background).
    public enum State: Int, Sendable { case active, inactive, background }
    open var applicationState: UIApplication.State { .active }
}
