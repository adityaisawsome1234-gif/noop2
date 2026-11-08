public struct UTType: Hashable, Sendable {
    public let identifier: String
    public init(_ id: String) { identifier = id }
    public static let json = UTType("public.json")
    public static let plainText = UTType("public.plain-text")
    public static let commaSeparatedText = UTType("public.comma-separated-values-text")
    public static let data = UTType("public.data")
    public static let zip = UTType("public.zip-archive")
}
