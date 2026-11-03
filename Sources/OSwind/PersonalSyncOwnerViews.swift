import SwiftUI
import AppKit
import OSwindCore

struct SyncApprovalPresentation:Identifiable {
    let id=UUID()
    let response:PersonalSyncApprovedResponse
    let rootFingerprint:String
}

struct PersonalSyncOwnerAdditionView:View {
    @ObservedObject var model:PersonalSyncModel
    @State private var request=""
    @State private var compared=false
    @State private var expanded:Bool
    init(model:PersonalSyncModel,initiallyExpanded:Bool=false) {self.model=model;_expanded=State(initialValue:initiallyExpanded)}
    var body:some View {
        DisclosureGroup("Add another Mac",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:12) {
                Text("Owner approval preview. Existing Macs still need membership refresh before the expanded group can sync.").font(.caption).foregroundStyle(.orange)
                if let review=model.ownerAdditionReview {
                    Text(review.deviceName).font(.headline)
                    Text("Compare this request fingerprint with the joining Mac:").font(.callout)
                    Text(review.requestFingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    Text("Group fingerprint").font(.caption.weight(.semibold))
                    Text(review.rootFingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    Text("Expires \(review.expires.formatted(date:.abbreviated,time:.standard))").font(.caption).foregroundStyle(.secondary)
                    Toggle("The name and request fingerprint match the joining Mac",isOn:$compared)
                    Text("Approval briefly stops recording and local work. Your library reopens with recording and sync paused; return the encrypted response to the joining Mac.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Back") {model.clearOwnerReview();compared=false}
                        Spacer()
                        Button("Approve this Mac") {model.approveReviewedOwner(review)}.buttonStyle(.borderedProminent)
                            .disabled(!compared || review.expires<Date() || model.stopping || model.ownerReviewBusy)
                    }
                }else {
                    Text("On the new Mac, choose Join an existing group. Paste its signed request here, then compare its fingerprint before approving.").font(.callout)
                    TextEditor(text:$request).font(.system(.caption,design:.monospaced)).frame(height:110).scrollContentBackground(.hidden)
                        .padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8)).privacySensitive()
                        .onChange(of:request) {_,value in if value.utf8.count>8192 {request=""}}
                    HStack {
                        Button("Review request") {compared=false;model.reviewOwnerRequest(request)}.disabled(request.isEmpty || model.ownerReviewBusy || model.stopping)
                        if model.ownerReviewBusy {ProgressView().controlSize(.small);Button("Cancel review") {model.clearOwnerReview()}}
                    }
                }
                if let error=model.ownerReviewError {Text(error).font(.caption).foregroundStyle(.orange)}
            }.padding(.top,8)
        }.disabled(model.preparing || model.stopping)
            .onChange(of:model.ownerAdditionReview) {_,review in if review != nil {expanded=true}}
    }
}

struct PersonalSyncApprovalResponseView:View {
    let presentation:SyncApprovalPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var copied=false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Label("Return approval to \(presentation.response.deviceName)",systemImage:"checkmark.shield").font(.title2.weight(.semibold));Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)}
            Text("Give this encrypted response and the group fingerprint to the joining Mac through your trusted channel.")
            Text("Group fingerprint").font(.caption.weight(.semibold))
            Text(presentation.rootFingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            ScrollView {Text(presentation.response.response).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                .frame(height:180).padding(10).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8)).privacySensitive()
            Text("Request expires \(presentation.response.expires.formatted(date:.abbreviated,time:.standard)). Recovering this response does not extend its expiry.").font(.caption).foregroundStyle(presentation.response.expires<Date() ? .orange:.secondary)
            HStack {Button(copied ? "Copied":"Copy response") {NSPasteboard.general.clearContents();NSPasteboard.general.setString(presentation.response.response,forType:.string);copied=true}.buttonStyle(.borderedProminent);Spacer();Text("Recording and sync stay paused.").font(.caption).foregroundStyle(.secondary)}
        }.padding(24).frame(width:660)
    }
}
