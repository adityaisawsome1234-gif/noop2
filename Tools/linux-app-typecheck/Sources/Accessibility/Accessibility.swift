import Foundation
public protocol AXDataAxisDescriptor {}
public final class AXNumericDataAxisDescriptor: AXDataAxisDescriptor {
    public init(title: String, range: ClosedRange<Double>, gridlinePositions: [Double], valueDescriptionProvider: @escaping (Double) -> String) {}
}
public final class AXDataPoint {
    public init(x: Double, y: Double?, additionalValues: [Double] = [], label: String? = nil) {}
}
public final class AXDataSeriesDescriptor {
    public init(name: String, isContinuous: Bool, dataPoints: [AXDataPoint]) {}
}
public final class AXChartDescriptor {
    public init(title: String?, summary: String?, xAxis: any AXDataAxisDescriptor, yAxis: AXNumericDataAxisDescriptor?, additionalAxes: [AXNumericDataAxisDescriptor], series: [AXDataSeriesDescriptor]) {}
}
public protocol AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor
}
