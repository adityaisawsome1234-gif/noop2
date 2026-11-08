// Minimal SwiftUI stand-in for Linux type-checking of Forma's views (structure only; no rendering).
@_exported import Foundation
@_exported import Observation
import UIKit
import UniformTypeIdentifiers

// MARK: View & builders
@MainActor @preconcurrency public protocol View { associatedtype Body: View; @ViewBuilder @MainActor var body: Body { get } }
extension Never: View { public var body: Never { fatalError() } }
public struct EmptyView: View { public init() {}; public var body: Never { fatalError() } }
public struct TupleView<T>: View { public init() {}; public var body: Never { fatalError() } }
public struct ConditionalContent<T, F>: View { public init() {}; public var body: Never { fatalError() } }
public struct AnyView: View { public init<V: View>(_ v: V) {}; public var body: Never { fatalError() } }
extension Optional: View where Wrapped: View { public var body: Never { fatalError() } }
public struct ModifiedView<Content>: View { public init() {}; public var body: Never { fatalError() } }
@resultBuilder public enum ViewBuilder {
    public static func buildBlock() -> EmptyView { EmptyView() }
    public static func buildBlock<C: View>(_ c: C) -> C { c }
    public static func buildBlock<each C: View>(_ c: repeat each C) -> TupleView<(repeat each C)> { TupleView() }
    public static func buildExpression<C: View>(_ c: C) -> C { c }
    public static func buildIf<C: View>(_ c: C?) -> C? { c }
    public static func buildEither<T: View, F: View>(first: T) -> ConditionalContent<T, F> { ConditionalContent() }
    public static func buildEither<T: View, F: View>(second: F) -> ConditionalContent<T, F> { ConditionalContent() }
    public static func buildLimitedAvailability<C: View>(_ c: C) -> AnyView { AnyView(c) }
}
public struct Group<Content>: View { public init(@ViewBuilder content: () -> Content) where Content: View {}; public var body: Never { fatalError() } }

// MARK: App & scenes
public protocol Scene {}
public struct WindowGroup<Content: View>: Scene { public init(@ViewBuilder content: () -> Content) {} }
@resultBuilder public enum SceneBuilder { public static func buildBlock<S: Scene>(_ s: S) -> S { s } }
@MainActor public protocol App { associatedtype Body: Scene; @SceneBuilder var body: Body { get }; init() }
extension App { public static func main() {} }

// MARK: State, bindings, environment
@propertyWrapper public struct State<Value> {
    public init(wrappedValue: Value) {}
    public init(initialValue: Value) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { fatalError() }
}
@propertyWrapper @dynamicMemberLookup public struct Binding<Value> {
    public init(get: @escaping () -> Value, set: @escaping (Value) -> Void) {}
    public var wrappedValue: Value { get { fatalError() } nonmutating set {} }
    public var projectedValue: Binding<Value> { self }
    public subscript<T>(dynamicMember kp: WritableKeyPath<Value, T>) -> Binding<T> { fatalError() }
}
@propertyWrapper @dynamicMemberLookup public struct Bindable<Value: AnyObject> {
    public init(wrappedValue: Value) {}
    public init(_ v: Value) {}
    public var wrappedValue: Value { fatalError() }
    public var projectedValue: Bindable<Value> { self }
    public subscript<T>(dynamicMember kp: ReferenceWritableKeyPath<Value, T>) -> Binding<T> { fatalError() }
}
public struct DismissAction { public func callAsFunction() {} }
public enum ScenePhase: Equatable { case active, inactive, background }
public enum DynamicTypeSize: Comparable { case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge, accessibility1, accessibility2, accessibility3, accessibility4, accessibility5
    public var isAccessibilitySize: Bool { self >= .accessibility1 } }
public enum ColorScheme { case light, dark }
public struct EnvironmentValues {
    public var dismiss: DismissAction { DismissAction() }
    public var scenePhase: ScenePhase { .active }
    public var dynamicTypeSize: DynamicTypeSize { get { .large } set {} }
    public var isEnabled: Bool { get { true } set {} }
}
@propertyWrapper public struct Environment<Value> {
    public init(_ kp: KeyPath<EnvironmentValues, Value>) {}
    public init(_ t: Value.Type) where Value: AnyObject & Observable {}
    public var wrappedValue: Value { fatalError() }
}

// MARK: Layout & style values
public struct HorizontalAlignment { public static let leading = Self(), center = Self(), trailing = Self() }
public struct VerticalAlignment { public static let top = Self(), center = Self(), bottom = Self(), firstTextBaseline = Self() }
public struct Alignment { public static let leading = Self(), center = Self(), trailing = Self(), top = Self() }
public enum Edge { case top, bottom, leading, trailing
    public struct Set: OptionSet { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }
        public static let horizontal = Set(rawValue: 1), vertical = Set(rawValue: 2), top = Set(rawValue: 4), all = Set(rawValue: 7) } }
public enum VerticalEdge { case top, bottom }
public enum RoundedCornerStyle { case circular, continuous }
public enum TextAlignment { case leading, center, trailing }
public enum Visibility { case automatic, visible, hidden }
public enum SymbolRenderingMode { case monochrome, hierarchical, palette, multicolor }
public enum UIKeyboardType { case `default`, numberPad, decimalPad }
public enum ButtonRole { case destructive, cancel }
public struct PresentationDetent: Hashable { public static let medium = Self(), large = Self() }
public struct AccessibilityTraits: OptionSet { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }
    public static let isHeader = Self(rawValue: 1), isSelected = Self(rawValue: 2), isStaticText = Self(rawValue: 4), isButton = Self(rawValue: 8),
                      isModal = Self(rawValue: 16) }
public struct AccessibilityChildBehavior { public static let ignore = Self(), combine = Self(), contain = Self() }
public struct NavigationBarItem { public enum TitleDisplayMode { case automatic, inline, large } }
public struct ToolbarItemPlacement { public static let topBarTrailing = Self(), topBarLeading = Self(), confirmationAction = Self(), cancellationAction = Self() }
public struct DatePickerComponents: OptionSet { public let rawValue: Int; public init(rawValue: Int) { self.rawValue = rawValue }
    public static let date = Self(rawValue: 1), hourAndMinute = Self(rawValue: 2) }
public struct StrokeStyle { public init(lineWidth: CGFloat = 1) {} }

// MARK: Fonts & colors
public struct Font: Hashable, Sendable {
    public enum TextStyle { case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2 }
    public enum Design { case `default`, rounded, monospaced, serif }
    public struct Weight: Hashable { public static let regular = Self(), medium = Self(), semibold = Self(), bold = Self() }
    public static let largeTitle = Font(), title = Font(), title2 = Font(), title3 = Font(), headline = Font(), subheadline = Font(),
                      body = Font(), callout = Font(), footnote = Font(), caption = Font(), caption2 = Font()
    public static func system(_ style: TextStyle, design: Design? = nil, weight: Weight? = nil) -> Font { Font() }
    public func weight(_ w: Weight) -> Font { self }
    public func monospacedDigit() -> Font { self }
    public func monospaced() -> Font { self }
}
public protocol ShapeStyle {}
// As in the real SDK: Sendable, with the View conformance in an extension (so `init(_: UIColor)` is not
// main-actor isolated).
public struct Color: Hashable, Sendable, ShapeStyle {
    public init(_ ui: UIColor) {}
    public static let clear = Color(UIColor(red: 0, green: 0, blue: 0, alpha: 0))
    public func opacity(_ opacity: Double) -> Color { self }
}
extension Color: View { public var body: Never { fatalError() } }

// MARK: Shapes
public protocol Shape: View {}
extension Shape {
    public func fill<S: ShapeStyle>(_ s: S) -> some View { ModifiedView<Self>() }
    public func strokeBorder<S: ShapeStyle>(_ s: S, lineWidth: CGFloat = 1) -> some View { ModifiedView<Self>() }
}
public struct Capsule: Shape { public init() {}; public var body: Never { fatalError() } }
public struct Rectangle: Shape { public init() {}; public var body: Never { fatalError() } }
public struct RoundedRectangle: Shape { public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .circular) {}; public var body: Never { fatalError() } }

// MARK: Views
public struct Text: View { public init<S: StringProtocol>(_ s: S) {}; public init(verbatim: String) {}; public var body: Never { fatalError() } }
public struct Image: View { public init(systemName: String) {}; public var body: Never { fatalError() } }
public struct Label<T: View, I: View>: View {
    public init<S: StringProtocol>(_ title: S, systemImage: String) where T == Text, I == Image {}
    public init(@ViewBuilder title: () -> T, @ViewBuilder icon: () -> I) {}
    public var body: Never { fatalError() } }
public struct Button<L: View>: View {
    public init<S: StringProtocol>(_ title: S, action: @escaping () -> Void) where L == Text {}
    public init<S: StringProtocol>(_ title: S, role: ButtonRole?, action: @escaping () -> Void) where L == Text {}
    public init(action: @escaping () -> Void, @ViewBuilder label: () -> L) {}
    public init(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> L) {}
    public var body: Never { fatalError() } }
public struct VStack<C: View>: View { public init(alignment: HorizontalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct HStack<C: View>: View { public init(alignment: VerticalAlignment = .center, spacing: CGFloat? = nil, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct ZStack<C: View>: View { public init(alignment: Alignment = .center, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct ScrollView<C: View>: View { public init(@ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct List<C: View>: View {
    public init(@ViewBuilder content: () -> C) {}
    public init<D: RandomAccessCollection, R: View>(_ data: D, @ViewBuilder rowContent: @escaping (D.Element) -> R) where D.Element: Identifiable, C == ForEach<D, D.Element.ID, R> {}
    public var body: Never { fatalError() } }
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content> {
    public init(_stub: Void) {}
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID, Content: View {}
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) where Content: View {}
}
extension ForEach: View where Content: View { public var body: Never { fatalError() } }
public struct Section<C: View>: View {
    public init(@ViewBuilder content: () -> C) {}
    public init<H: View>(@ViewBuilder content: () -> C, @ViewBuilder header: () -> H) {}
    public init<F: View>(@ViewBuilder content: () -> C, @ViewBuilder footer: () -> F) {}
    public init<H: View, F: View>(@ViewBuilder content: () -> C, @ViewBuilder header: () -> H, @ViewBuilder footer: () -> F) {}
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> C) {}
    public var body: Never { fatalError() } }
public struct Form<C: View>: View { public init(@ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct NavigationStack<C: View>: View { public init(@ViewBuilder root: () -> C) {}; public var body: Never { fatalError() } }
public struct NavigationLink<L: View, D: View>: View {
    public init<S: StringProtocol>(_ title: S, @ViewBuilder destination: () -> D) where L == Text {}
    public init(@ViewBuilder destination: () -> D, @ViewBuilder label: () -> L) {}
    public var body: Never { fatalError() } }
public struct TabView<S: Hashable, C: View>: View { public init(selection: Binding<S>, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct Tab<V: Hashable, C: View>: View { public init<S: StringProtocol>(_ title: S, systemImage: String, value: V, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct Toggle: View { public init<S: StringProtocol>(_ title: S, isOn: Binding<Bool>) {}; public var body: Never { fatalError() } }
public struct Picker<S: Hashable, C: View>: View { public init<T: StringProtocol>(_ title: T, selection: Binding<S>, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct DatePicker: View { public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: DatePickerComponents) {}; public var body: Never { fatalError() } }
public struct TextField: View { public init<S: StringProtocol>(_ title: S, text: Binding<String>) {}; public var body: Never { fatalError() } }
public struct ProgressView: View {
    public init() {}
    public init<S: StringProtocol>(_ title: S) {}
    public init(value: Double?, total: Double = 1) {}
    public var body: Never { fatalError() } }
public struct GridItem { public enum Size { case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity), adaptive(minimum: CGFloat, maximum: CGFloat = .infinity) }
    public init(_ size: Size = .flexible(minimum: 10, maximum: .infinity), spacing: CGFloat? = nil) {} }
public struct LazyVGrid<C: View>: View { public init(columns: [GridItem], spacing: CGFloat? = nil, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct Grid<C: View>: View { public init(alignment: Alignment = .center, horizontalSpacing: CGFloat? = nil, verticalSpacing: CGFloat? = nil, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct GridRow<C: View>: View { public init(@ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct LabeledContent<C: View>: View {
    public init<S: StringProtocol, V: StringProtocol>(_ title: S, value: V) where C == Text {}
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> C) {}
    public var body: Never { fatalError() } }
public struct DisclosureGroup<C: View>: View { public init<S: StringProtocol>(_ title: S, isExpanded: Binding<Bool>, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }
public struct Spacer: View { public init(minLength: CGFloat? = nil) {}; public var body: Never { fatalError() } }
public struct Divider: View { public init() {}; public var body: Never { fatalError() } }
public struct GeometryProxy { public var size: CGSize { .zero } }
public struct GeometryReader<C: View>: View { public init(@ViewBuilder content: @escaping (GeometryProxy) -> C) {}; public var body: Never { fatalError() } }
public struct ToolbarItem<C: View>: View { public init(placement: ToolbarItemPlacement, @ViewBuilder content: () -> C) {}; public var body: Never { fatalError() } }

// MARK: Button & picker styles
@MainActor @preconcurrency public protocol ButtonStyle {
    associatedtype Body: View
    @ViewBuilder @MainActor func makeBody(configuration: Self.Configuration) -> Self.Body
    typealias Configuration = ButtonStyleConfiguration
}
public struct ButtonStyleConfiguration {
    public struct Label: View { public var body: Never { fatalError() } }
    public let role: ButtonRole?
    public let label: ButtonStyleConfiguration.Label
    public let isPressed: Bool
}
public protocol PrimitiveButtonStyle {}
public struct BorderedProminentButtonStyle: PrimitiveButtonStyle {}
public struct BorderedButtonStyle: PrimitiveButtonStyle {}
public struct BorderlessButtonStyle: PrimitiveButtonStyle {}
public struct PlainButtonStyle: PrimitiveButtonStyle {}
extension PrimitiveButtonStyle where Self == BorderedProminentButtonStyle { public static var borderedProminent: Self { .init() } }
extension PrimitiveButtonStyle where Self == BorderedButtonStyle { public static var bordered: Self { .init() } }
extension PrimitiveButtonStyle where Self == BorderlessButtonStyle { public static var borderless: Self { .init() } }
extension PrimitiveButtonStyle where Self == PlainButtonStyle { public static var plain: Self { .init() } }
public protocol PickerStyle {}
public struct MenuPickerStyle: PickerStyle {}
public struct SegmentedPickerStyle: PickerStyle {}
extension PickerStyle where Self == MenuPickerStyle { public static var menu: Self { .init() } }
extension PickerStyle where Self == SegmentedPickerStyle { public static var segmented: Self { .init() } }

// MARK: Documents
public struct FileWrapperShim {}
open class FileWrapper { public init(regularFileWithContents: Data) {}; open var regularFileContents: Data? { nil } }
public struct FileDocumentReadConfiguration { public var file: FileWrapper { FileWrapper(regularFileWithContents: Data()) } }
public struct FileDocumentWriteConfiguration {}
public protocol FileDocument {
    static var readableContentTypes: [UTType] { get }
    typealias ReadConfiguration = FileDocumentReadConfiguration
    typealias WriteConfiguration = FileDocumentWriteConfiguration
    init(configuration: ReadConfiguration) throws
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
}

// MARK: Modifiers
extension View {
    public func font(_ f: Font?) -> some View { ModifiedView<Self>() }
    public func foregroundStyle<S: ShapeStyle>(_ s: S) -> some View { ModifiedView<Self>() }
    public func tint(_ c: Color?) -> some View { ModifiedView<Self>() }
    public func frame(width: CGFloat? = nil, height: CGFloat? = nil, alignment: Alignment = .center) -> some View { ModifiedView<Self>() }
    public func frame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, maxWidth: CGFloat? = nil, minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil, alignment: Alignment = .center) -> some View { ModifiedView<Self>() }
    public func padding(_ edges: Edge.Set, _ length: CGFloat? = nil) -> some View { ModifiedView<Self>() }
    public func padding(_ length: CGFloat) -> some View { ModifiedView<Self>() }
    public func padding() -> some View { ModifiedView<Self>() }
    public func environment<O: AnyObject & Observable>(_ o: O?) -> some View { ModifiedView<Self>() }
    public func buttonStyle<S: PrimitiveButtonStyle>(_ s: S) -> some View { ModifiedView<Self>() }
    public func buttonStyle<S: ButtonStyle>(_ s: S) -> some View { ModifiedView<Self>() }
    public func opacity(_ o: Double) -> some View { ModifiedView<Self>() }
    public func contentShape<S: Shape>(_ s: S) -> some View { ModifiedView<Self>() }
    public func scrollContentBackground(_ v: Visibility) -> some View { ModifiedView<Self>() }
    public func navigationTitle<S: StringProtocol>(_ s: S) -> some View { ModifiedView<Self>() }
    public func accessibilityElement(children: AccessibilityChildBehavior = .ignore) -> some View { ModifiedView<Self>() }
    public func tag<V: Hashable>(_ v: V) -> some View { ModifiedView<Self>() }
    public func disabled(_ b: Bool) -> some View { ModifiedView<Self>() }
    public func background<S: ShapeStyle, Sh: Shape>(_ s: S, in shape: Sh) -> some View { ModifiedView<Self>() }
    public func background<V: View>(_ v: V) -> some View { ModifiedView<Self>() }
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View { ModifiedView<Self>() }
    public func accessibilityLabel<S: StringProtocol>(_ s: S) -> some View { ModifiedView<Self>() }
    public func accessibilityHint<S: StringProtocol>(_ s: S) -> some View { ModifiedView<Self>() }
    public func accessibilityHidden(_ b: Bool) -> some View { ModifiedView<Self>() }
    public func accessibilityAddTraits(_ t: AccessibilityTraits) -> some View { ModifiedView<Self>() }
    public func sheet<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View { ModifiedView<Self>() }
    public func sheet<I: Identifiable, C: View>(item: Binding<I?>, @ViewBuilder content: @escaping (I) -> C) -> some View { ModifiedView<Self>() }
    public func overlay<V: View>(@ViewBuilder content: () -> V) -> some View { ModifiedView<Self>() }
    public func overlay<V: View>(_ v: V) -> some View { ModifiedView<Self>() }
    public func navigationBarTitleDisplayMode(_ m: NavigationBarItem.TitleDisplayMode) -> some View { ModifiedView<Self>() }
    public func keyboardType(_ t: UIKeyboardType) -> some View { ModifiedView<Self>() }
    public func confirmationDialog<S: StringProtocol, A: View>(_ t: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A) -> some View { ModifiedView<Self>() }
    public func confirmationDialog<S: StringProtocol, A: View, M: View>(_ t: S, isPresented: Binding<Bool>, titleVisibility: Visibility = .automatic, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { ModifiedView<Self>() }
    public func preferredColorScheme(_ c: ColorScheme?) -> some View { ModifiedView<Self>() }
    public func pickerStyle<S: PickerStyle>(_ s: S) -> some View { ModifiedView<Self>() }
    public func onChange<V: Equatable>(of v: V, _ action: @escaping (V, V) -> Void) -> some View { ModifiedView<Self>() }
    public func lineLimit(_ n: Int?) -> some View { ModifiedView<Self>() }
    public func ignoresSafeArea() -> some View { ModifiedView<Self>() }
    public func fileExporter<D: FileDocument>(isPresented: Binding<Bool>, document: D?, contentType: UTType, defaultFilename: String? = nil, onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View { ModifiedView<Self>() }
    public func fileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType], onCompletion: @escaping (Result<URL, Error>) -> Void) -> some View { ModifiedView<Self>() }
    public func alert<S: StringProtocol, A: View, M: View>(_ t: S, isPresented: Binding<Bool>, @ViewBuilder actions: () -> A, @ViewBuilder message: () -> M) -> some View { ModifiedView<Self>() }
    public func symbolRenderingMode(_ m: SymbolRenderingMode?) -> some View { ModifiedView<Self>() }
    public func safeAreaInset<V: View>(edge: VerticalEdge, spacing: CGFloat? = nil, @ViewBuilder content: () -> V) -> some View { ModifiedView<Self>() }
    public func presentationDetents(_ d: Set<PresentationDetent>) -> some View { ModifiedView<Self>() }
    public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View { ModifiedView<Self>() }
    public func multilineTextAlignment(_ a: TextAlignment) -> some View { ModifiedView<Self>() }
    public func dynamicTypeSize(_ s: DynamicTypeSize) -> some View { ModifiedView<Self>() }
    public func clipShape<S: Shape>(_ s: S) -> some View { ModifiedView<Self>() }
    public func refreshable(action: @escaping () async -> Void) -> some View { ModifiedView<Self>() }
    public func task(_ action: @escaping () async -> Void) -> some View { ModifiedView<Self>() }
    public func onAppear(perform: (() -> Void)? = nil) -> some View { ModifiedView<Self>() }
    public func onDisappear(perform: (() -> Void)? = nil) -> some View { ModifiedView<Self>() }
    public func toolbar<C: View>(@ViewBuilder content: () -> C) -> some View { ModifiedView<Self>() }
    public func monospacedDigit() -> some View { ModifiedView<Self>() }
}

// MARK: UIKit hosting
@MainActor @preconcurrency open class UIHostingController<Content: View>: UIViewController {
    public init(rootView: Content) { super.init() }
}
