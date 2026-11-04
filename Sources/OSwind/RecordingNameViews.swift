import SwiftUI
import OSwindCore

struct RecordingNameSection:View {
    @ObservedObject var names:RecordingNamesModel
    @ObservedObject var archive:RecordedMeetingsModel
    let originalTitle:String
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            HStack(alignment:.top) {
                Text(names.rows.count==1 ? names.rows[0].name:originalTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
                Spacer(minLength:12)
                if names.loading || names.saving {ProgressView().controlSize(.small)}
                if names.rows.count<=1 {
                    Button(names.rows.isEmpty ? "Name recording":"Rename") {names.beginEditing()}.disabled(!names.canEdit || archive.busy)
                }
            }
            if let error=names.error {
                HStack(alignment:.top) {Label(error,systemImage:"exclamationmark.circle").foregroundStyle(.orange);Button("Refresh") {archive.refresh()}.disabled(archive.busy)}.font(.caption)
            }
            if let notice=names.notice {Text(notice).font(.caption).foregroundStyle(.secondary)}
            if names.rows.count>1 {
                Label("Multiple saved names",systemImage:"exclamationmark.bubble").font(.subheadline.weight(.medium))
                Text("Review each definition. Remove the ones you no longer want, then edit the remaining name.").font(.caption).foregroundStyle(.secondary)
                ForEach(names.rows,id:\.revision) {name in
                    HStack(alignment:.top) {Text(name.name).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading);removeButton(name)}.font(.callout)
                }
            }else if let name=names.rows.first {
                HStack {Text("Saved recording name").foregroundStyle(.secondary);Spacer();removeButton(name)}.font(.caption)
            }
        }
        .sheet(item:$names.editor,onDismiss:{names.editorDismissed()}) {review in
            RecordingNameEditorView(names:names,archive:archive,review:review)
        }
        .confirmationDialog("Remove this saved name?",isPresented:Binding(get:{names.removal != nil},set:{if !$0 {names.cancelRemoval()}}),titleVisibility:.visible) {
            Button("Remove name",role:.destructive) {names.confirmRemoval()}.disabled(names.saving || archive.busy)
            Button("Cancel",role:.cancel) {names.cancelRemoval()}
        } message: {
            if let name=names.removal?.expected {Text("\(name.name)\n\nOriginal clips and transcripts are kept.")}
        }
    }
    private func removeButton(_ name:RecordedMeetingDetailsSnapshot)->some View {
        Button("Remove name",role:.destructive) {names.requestRemoval(name)}.buttonStyle(.borderless).disabled(names.loading || names.saving || archive.busy)
    }
}

struct RecordingNameEditorView:View {
    @ObservedObject var names:RecordingNamesModel
    @ObservedObject var archive:RecordedMeetingsModel
    let review:RecordingNameReview
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(review.expected==nil ? "Name this recording":"Rename recording").font(.title2.weight(.semibold))
            Text(review.source.belongsToSession ? "This name follows the clips in this recording session. Original transcripts and dates stay the same.":"This name applies to this clip version. Original transcripts and dates stay the same.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let expected=review.expected {Text("Current name: "+expected.name).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}
            TextField("Recording name",text:$names.draft).textFieldStyle(.roundedBorder).disabled(names.saving).accessibilityIdentifier("recording-name-field")
            Text("\(names.draft.count)/200 characters").font(.caption).foregroundStyle(names.draft.count>200 ? Color.orange:Color.secondary)
            if let error=names.editorError {
                Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
                Button("Review latest name, keep draft") {names.reviewLatest()}.disabled(names.saving || archive.busy)
            }
            HStack {
                if names.saving {ProgressView().controlSize(.small);Text("Saving…").font(.caption).foregroundStyle(.secondary)}
                Spacer()
                Button("Cancel") {names.cancelEditor()}.keyboardShortcut(.cancelAction).disabled(names.saving)
                Button("Save name") {names.saveEditor()}.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!names.canSave || archive.busy)
            }
        }.padding(24).frame(width:440).interactiveDismissDisabled(names.saving)
    }
}
