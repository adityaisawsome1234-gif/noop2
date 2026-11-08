import Foundation
import FormaAnalytics

// forma-docs — renders the metric specifications compiled into Forma as Markdown.
//   swift run forma-docs > ../docs/METHODOLOGY_SPECS.md
// (MethodologyDocumentTests fails while that file differs from this output.)

print(MethodologyDocument.markdown(), terminator: "")
