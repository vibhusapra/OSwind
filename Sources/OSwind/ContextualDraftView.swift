import SwiftUI
import OSwindCore

struct ContextualDraftView:View {
    @ObservedObject var draft:ContextualDraftModel
    let privacy:PrivacyPolicy
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text("Make it yours.").font(.system(size:28,weight:.medium,design:.rounded))
                    Text("Review the draft, then copy it or insert it into your chosen field.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {draft.showing=false}.disabled(draft.busy)
            }
            HStack(spacing:10) {
                Image(systemName:"arrow.up.forward.app").font(.title2).foregroundStyle(OSwindTheme.accent)
                VStack(alignment:.leading,spacing:4) {
                    if let target=draft.destination {
                        Text(target.app+" · "+target.title).font(.headline).lineLimit(2)
                        Text(target.selectionLength==0 ? "Insert at the selected caret" : "Replace the selected text").font(.caption).foregroundStyle(.secondary)
                    }else {Text("Choose a destination").font(.headline)}
                    Text(draft.destinationStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                }
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(OSwindTheme.accent.opacity(0.08),in:RoundedRectangle(cornerRadius:12))
            TextEditor(text:$draft.text).font(.system(size:15)).scrollContentBackground(.hidden).padding(12).background(.background,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.12))).frame(minHeight:260).disabled(draft.busy).accessibilityLabel("Reviewed draft text")
            HStack {
                Text("\(draft.sourceCount) sources · \(draft.provider)").lineLimit(1)
                Spacer()
                Text("\(draft.text.utf8.count.formatted()) / 65,536 bytes").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            Text("This editable copy stays in memory until you close the library or clear it. Citation markers are preserved; check the original answer’s sources. OSwind never presses Send or Enter.").font(.caption).foregroundStyle(.secondary)
            if let error=draft.error ?? draft.textError {Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            if let status=draft.status {Label(status,systemImage:"checkmark.circle").font(.callout).foregroundStyle(OSwindTheme.accent).fixedSize(horizontal:false,vertical:true)}
            HStack {
                Button("Clear draft",role:.destructive) {draft.clear()}.disabled(draft.busy)
                Spacer()
                if draft.busy {ProgressView().controlSize(.small);Button("Cancel handoff") {draft.cancelHandoff()}}
                Button("Copy draft") {draft.copy()}.disabled(draft.busy || draft.textError != nil)
                Button("Insert into \(draft.destination?.app ?? "app")") {draft.insert(privacy:privacy)}.buttonStyle(.borderedProminent).disabled(draft.busy || draft.textError != nil || draft.destination==nil)
            }
        }.padding(28).frame(width:760,height:710).interactiveDismissDisabled(draft.busy)
    }
}
