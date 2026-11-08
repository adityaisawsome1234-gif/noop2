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
