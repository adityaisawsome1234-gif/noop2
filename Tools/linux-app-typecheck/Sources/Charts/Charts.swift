import Foundation
import SwiftUI
import Accessibility
public protocol ChartContent {}
@resultBuilder public enum ChartContentBuilder {
    public static func buildBlock<each C: ChartContent>(_ c: repeat each C) -> ChartTuple { ChartTuple() }
    public static func buildExpression<C: ChartContent>(_ c: C) -> C { c }
}
public struct ChartTuple: ChartContent {}
public struct PlottableValue<V> {
    public static func value<S: StringProtocol>(_ label: S, _ v: V) -> PlottableValue<V> { PlottableValue() }
    public static func value<S: StringProtocol>(_ label: S, _ v: Date, unit: Calendar.Component) -> PlottableValue<Date> where V == Date { PlottableValue<Date>() }
}
public struct InterpolationMethod { public static let linear = Self(), catmullRom = Self() }
public struct LineMark: ChartContent { public init<X, Y, S>(x: PlottableValue<X>, y: PlottableValue<Y>, series: PlottableValue<S>) {} }
public struct PointMark: ChartContent { public init<X, Y>(x: PlottableValue<X>, y: PlottableValue<Y>) {} }
public struct RectangleMark: ChartContent { public init<X>(xStart: PlottableValue<X>, xEnd: PlottableValue<X>) {} }
extension ChartContent {
    public func interpolationMethod(_ m: InterpolationMethod) -> some ChartContent { ChartTuple() }
    public func foregroundStyle<S: ShapeStyle>(_ s: S) -> some ChartContent { ChartTuple() }
    public func lineStyle(_ s: StrokeStyle) -> some ChartContent { ChartTuple() }
    public func symbolSize(_ s: CGFloat) -> some ChartContent { ChartTuple() }
}
extension ForEach: ChartContent where Content: ChartContent {}
extension ForEach where Content: ChartContent {
    public init(_ data: Data, @ChartContentBuilder content: @escaping (Data.Element) -> Content) where Data.Element: Identifiable, ID == Data.Element.ID { self.init(_stub: ()) }
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ChartContentBuilder content: @escaping (Data.Element) -> Content) { self.init(_stub: ()) }
}
public struct Chart<C: ChartContent>: View { public init(@ChartContentBuilder content: () -> C) {}; public var body: Never { fatalError() } }
extension View {
    public func chartXScale(domain: ClosedRange<Date>) -> some View { ModifiedView<Self>() }
    public func chartYAxisLabel<V: View>(@ViewBuilder content: () -> V) -> some View { ModifiedView<Self>() }
    public func accessibilityChartDescriptor<R: AXChartDescriptorRepresentable>(_ r: R) -> some View { ModifiedView<Self>() }
}
