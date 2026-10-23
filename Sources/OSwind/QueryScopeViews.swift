import SwiftUI
import OSwindCore

/// Preview uses the same deterministic resolver as execution. Actual saved
/// answer bounds are rendered separately from this editable input preview.
struct QueryScopeControls: View {
    @Binding var query: String
    var filter: SearchFilter
    @Binding var enabled: Bool
    var knownApps = [String]()
    var executionError: String? = nil
    @State private var showHelp = false
    private var preview: (QueryResolution?,String?) {
        var input = filter; input.query = query
        do { return (try QueryScopeResolver.resolve(input,interpret:enabled,canonicalApp:{ try QueryScopeResolver.canonicalAppName($0,names:knownApps) }),nil) }
        catch { return (nil,error.localizedDescription) }
    }
    var body: some View {
        let (resolution,error) = preview
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:10) {
                Toggle("Query filters",isOn:$enabled).toggleStyle(.checkbox).controlSize(.small).fixedSize()
                if let resolution, !resolution.clauses.isEmpty {
                    ScrollView(.horizontal,showsIndicators:false) {
                        HStack(spacing:6) {
                            ForEach(Array(resolution.clauses.enumerated()),id:\.offset) { _,clause in
                                Button { if query == resolution.originalQuery { query = resolution.removing(clause) } } label: {
                                    HStack(spacing:5) { Image(systemName:clause.kind == "time" ? "clock" : clause.kind == "app" ? "app" : clause.kind == "tag" ? "tag" : "line.3.horizontal.decrease"); Text(clause.label); Image(systemName:"xmark").font(.system(size:8,weight:.semibold)) }
                                        .padding(.horizontal,8).padding(.vertical,4).background(OSwindTheme.accent.opacity(0.12),in:Capsule())
                                }.buttonStyle(.plain).help("Remove \(clause.label) from the query").accessibilityLabel("Remove filter: \(clause.label)")
                            }
                        }
                    }
                } else { Text(enabled ? "Try yesterday or app:\"Safari\"" : "Date words and operators stay as search text").foregroundStyle(.secondary).lineLimit(1); Spacer(minLength:0) }
                Button { showHelp.toggle() } label: { Image(systemName:"questionmark.circle") }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Query filter help")
                    .popover(isPresented:$showHelp) {
                        VStack(alignment:.leading,spacing:9) {
                            Text("Find a moment, with scope.").font(.headline)
                            Text("Dates narrow when a memory was captured. Selected controls and query filters apply together. Weeks start Monday; dates use this Mac’s time zone.")
                            Text("yesterday · last week · past 3 hours\non:2026-10-22 · since:2026-10-01\napp:\"Google Chrome\" · kind:audio\ntag:work · is:favorite").font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            Text("Use double quotes around date words/operators, or turn Query filters off, to search them as content. since: includes its boundary; until: excludes it.").foregroundStyle(.secondary)
                        }.font(.caption).padding(18).frame(width:340)
                    }
            }.font(.caption)
            if let message = error ?? executionError { Label(message,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.orange).accessibilityLabel("Query filter error: \(message)") }
            else if let resolution, !resolution.clauses.isEmpty { RecordedScopeView(filter:resolution.filter,timeZone:resolution.timeZone) }
        }
    }
}
struct RecordedScopeView: View {
    var filter: SearchFilter
    var timeZone: String?
    private var text: String {
        let zone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        let formatter = DateFormatter(); formatter.timeZone = zone; formatter.dateStyle = .medium; formatter.timeStyle = .short
        var parts = [String]()
        if let app = filter.app { parts.append(app) }
        if let kind = filter.kind { parts.append(kind.rawValue.capitalized) }
        if filter.favoritesOnly { parts.append("Saved") }
        if let tag = filter.tag { parts.append("#"+tag) }
        if let start = filter.start { parts.append("From "+formatter.string(from:start)) }
        if let end = filter.end { parts.append("Before "+formatter.string(from:end)) }
        if parts.isEmpty { parts.append("All recorded times and apps") }
        return parts.joined(separator:" · ")
    }
    var body: some View {
        Label(text,systemImage:"line.3.horizontal.decrease.circle").font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            .help("Recorded scope · \(timeZone ?? "original time zone not recorded") · start inclusive, end exclusive")
    }
}
