import Foundation
import Testing
@testable import FormaAnalytics

@Suite("Methodology document")
struct MethodologyDocumentTests {
    /// METHODOLOGY.md: the published specifications are generated from the catalog compiled into the app;
    /// this fails until `swift run forma-docs > ../docs/METHODOLOGY_SPECS.md` is run after a catalog change.
    @Test func publishedSpecificationsMatchTheCatalog() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/METHODOLOGY_SPECS.md")
        let published = try String(contentsOf: docs, encoding: .utf8)
        #expect(published == MethodologyDocument.markdown(),
                "docs/METHODOLOGY_SPECS.md is out of date: run `swift run forma-docs > ../docs/METHODOLOGY_SPECS.md` in FormaKit")
    }
}
