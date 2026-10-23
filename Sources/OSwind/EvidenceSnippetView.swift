import SwiftUI
import OSwindCore

/// Excerpt selection runs off the main actor; only the small visible snippet is
/// attributed. Full source text remains available in the memory inspector.
struct EvidenceSnippetView: View {
    let text: String
    let query: String
    var budget = 280
    var passage: PassageRange?
    @State private var snippet = ""
    init(text: String, query: String, budget: Int = 280, passage: PassageRange? = nil) {
        self.text = text; self.query = query; self.budget = budget; self.passage = passage
        _snippet = State(initialValue:(text as NSString).length <= budget ? text : String(text.prefix(budget))+" …")
    }
    private struct Input: Hashable, Sendable { var text: String; var query: String; var budget: Int; var passage: PassageRange? }
    private var highlighted: AttributedString {
        var result = AttributedString(snippet)
        for range in EvidenceText.matchRanges(in:snippet,query:query) {
            if let span = Range(range,in:snippet), let start = AttributedString.Index(span.lowerBound,within:result), let end = AttributedString.Index(span.upperBound,within:result) {
                result[start..<end].backgroundColor = OSwindTheme.accent.opacity(0.2)
                result[start..<end].foregroundColor = Color.primary
            }
        }
        return result
    }
    var body: some View {
        Text(highlighted)
            .task(id:Input(text:text,query:query,budget:budget,passage:passage)) {
                do { try await Task.sleep(nanoseconds:100_000_000) } catch { return }
                let input = Input(text:text,query:query,budget:budget,passage:passage)
                let worker = Task.detached(priority:.userInitiated) { SearchHit(memory:Memory(text:input.text),score:0,match:"",passage:input.passage).excerpt(query:input.query,budget:input.budget) }
                let value = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }; snippet = value
            }
    }
}
