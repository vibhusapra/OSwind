import SwiftUI
import OSwindCore

struct ContextualDraftView:View {
    @ObservedObject var draft:ContextualDraftModel
    let privacy:PrivacyPolicy
    @ObservedObject var voice:VoiceTypingModel
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Text("Make it yours.").font(.system(size:28,weight:.medium,design:.rounded))
                    Text("Review the draft, then copy it or insert it into your chosen field.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {voice.cancel();draft.showing=false}.disabled(draft.busy || voice.busy)
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
            VoiceTypingControls(voice:voice,draft:draft)
            TextEditor(text:$draft.text).font(.system(size:15)).scrollContentBackground(.hidden).padding(12).background(.background,in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.12))).frame(minHeight:220).disabled(draft.busy || voice.busy).accessibilityLabel("Reviewed draft text")
            HStack {
                Text(draft.provider.isEmpty ? "Editable draft" : draft.sourceCount==0 ? draft.provider : "\(draft.sourceCount) sources · \(draft.provider)").lineLimit(1)
                Spacer()
                Text("\(draft.text.utf8.count.formatted()) / 65,536 bytes").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            Text("This editable copy stays in memory until you close the library or clear it. Dictation is not saved to history. For sourced drafts, check the original answer’s citations. OSwind never presses Send or Enter.").font(.caption).foregroundStyle(.secondary)
            if let error=draft.error ?? (draft.text.isEmpty ? nil:draft.textError) {Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)}
            if let status=draft.status {Label(status,systemImage:"checkmark.circle").font(.callout).foregroundStyle(OSwindTheme.accent).fixedSize(horizontal:false,vertical:true)}
            HStack {
                Button("Clear draft",role:.destructive) {voice.cancel();draft.clear()}.disabled(draft.busy || voice.busy)
                Spacer()
                if draft.busy {ProgressView().controlSize(.small);Button("Cancel handoff") {draft.cancelHandoff()}}
                Button("Copy draft") {draft.copy()}.disabled(voice.busy || draft.busy || draft.textError != nil)
                Button("Insert into \(draft.destination?.app ?? "app")") {draft.insert(privacy:privacy)}.buttonStyle(.borderedProminent).disabled(voice.busy || draft.busy || draft.textError != nil || draft.destination==nil)
            }
        }.padding(28).frame(width:760,height:740).interactiveDismissDisabled(draft.busy || voice.busy)
    }
}

struct VoiceTypingControls:View {
    @ObservedObject var voice:VoiceTypingModel
    @ObservedObject var draft:ContextualDraftModel
    var body:some View {
        HStack(spacing:12) {
            Image(systemName:voice.recording ? "mic.fill":"waveform").foregroundStyle(voice.recording ? .red:OSwindTheme.accent).font(.title2)
            VStack(alignment:.leading,spacing:4) {
                Text(voice.recording ? "Listening · \(voice.elapsed) / 30 seconds":"Voice typing · local only").font(.headline)
                Text(voice.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:12)
            if voice.recording {Button("Stop & transcribe") {voice.finishRecording()}}
            else if voice.busy {ProgressView().controlSize(.small)}
            else {Button("Record") {voice.start()}.disabled(draft.busy)}
            if voice.busy {Button("Cancel") {voice.cancel()}}
        }.padding(14).background(OSwindTheme.accent.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
    }
}
