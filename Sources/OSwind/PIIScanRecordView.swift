import SwiftUI
import OSwindCore

struct PIIScanRecordView:View {
    let status:PIIScanStatus?
    var error:String?
    private var title:String {
        if error != nil {return "Import check unavailable"}
        switch status?.state {
        case .recorded:return "Experimental import check recorded"
        case .changed:return "Source edited or replaced after its import check"
        case .notRecorded:return "No local PII import check recorded"
        case .unavailable:return "Import check unavailable"
        case nil:return "Loading import-check record…"
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Label(title,systemImage:"doc.text.magnifyingglass").font(.callout.weight(.medium))
            if let record=status?.record {
                Text("Checked \(record.checkedAt.formatted(date:.abbreviated,time:.shortened)) · \(record.compute == .coreML ? "Core ML":"CPU") · threshold \(record.threshold.formatted(.number.precision(.fractionLength(2))))").font(.caption).foregroundStyle(.secondary)
                if status?.state == .recorded {Text(record.redacted ? "Text masking was applied during import.":"The check returned no text masks. Personal information may remain.").font(.caption)}
                else {Text("The earlier record is retained for reference. It does not cover the current source.").font(.caption)}
                DisclosureGroup("Scan details") {
                    VStack(alignment:.leading,spacing:5) {
                        Text(record.modelID).font(.system(.caption2,design:.monospaced)).textSelection(.enabled)
                        Text("\(record.fields) string fields · \(record.windows) model windows").font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.font(.caption)
            } else if status?.state == .notRecorded {
                Text("Records are created by additional PII masking on new imports. Earlier history and capture paths have not been checked by this feature.").font(.caption).foregroundStyle(.secondary)
            } else if error != nil || status?.state == .unavailable {
                Text("No current check can be established. This source should be treated as unchecked.").font(.caption).foregroundStyle(.secondary)
            }
            Text("This experimental check covers imported text fields. It can miss PII; images, audio, video and remote requests are outside its protection.").font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:10)).padding(.bottom,12)
        .accessibilityElement(children:.contain)
    }
}
