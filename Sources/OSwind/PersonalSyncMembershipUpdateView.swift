import SwiftUI
import AppKit
import OSwindCore

struct PersonalSyncMembershipUpdateView:View {
    @ObservedObject var model:PersonalSyncModel
    @State private var expanded=false
    @State private var page=""
    @State private var request=""
    @State private var inputError=""
    @State private var compared=false
    var body:some View {
        DisclosureGroup("Update paired Macs",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:12) {
                Text("Membership preview. Updates reopen this library with recording and sync paused. Expanded-group connection is still being verified.").font(.caption).foregroundStyle(.orange)
                if model.configured {
                    if let review=model.membershipUpdateReview {
                        Text("Review added Macs").font(.headline)
                        Text(review.addedDeviceNames.joined(separator:" · ")).font(.headline).textSelection(.enabled)
                        Text("\(review.currentMemberCount) → \(review.updatedMemberCount) trusted Macs · revision \(review.currentRevision) → \(review.updatedRevision)").font(.caption).foregroundStyle(.secondary)
                        Text("Group fingerprint").font(.caption.weight(.semibold))
                        Text(review.rootFingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        Text("Update fingerprint").font(.caption.weight(.semibold))
                        Text(review.updateFingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        Toggle("I have checked the group and the added Macs",isOn:$compared)
                        Text("This signed page extends the membership already trusted on this Mac. Another page may still be needed after this update.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Back") {model.clearOwnerReview();compared=false}
                            Spacer()
                            Button("Apply device update") {model.approveReviewedMembership(review)}.buttonStyle(.borderedProminent)
                                .disabled(!compared || model.ownerReviewBusy || model.stopping)
                        }
                    }else {
                        Text("Ask the owner for an update").font(.headline)
                        Text("Send this Mac's current public membership request to the original owner. Paste the signed update page they return.").font(.callout)
                        Button("Prepare membership request") {model.requestMembershipUpdate()}.disabled(model.ownerReviewBusy)
                        if let request=model.membershipRequest {message(request);Button("Copy membership request") {copy(request)}}
                        TextEditor(text:$page).font(.system(.caption,design:.monospaced)).frame(height:100).privacySensitive()
                            .onChange(of:page) {_,value in if value.utf8.count>PersonalSyncPairing.maximumMembershipUpdateBytes {page="";inputError="This update is too long. Ask the owner to copy one signed page again."}}
                        Button("Review update page") {compared=false;inputError="";model.reviewMembershipPage(page)}.disabled(page.isEmpty || model.ownerReviewBusy)
                    }
                }else if model.pairingStatus?.phase == .owner {
                    Text("Help an existing Mac catch up").font(.headline)
                    Text("Paste its public membership request. Return the signed page through your trusted channel. No private keys are included.").font(.callout)
                    TextEditor(text:$request).font(.system(.caption,design:.monospaced)).frame(height:100).privacySensitive()
                        .onChange(of:request) {_,value in if value.utf8.count>PersonalSyncPairing.maximumMembershipRequestBytes {request="";inputError="This request is too long. Copy the current membership request again."}}
                    Button("Prepare signed update page") {inputError="";model.performPairing(.membershipPage(request))}.disabled(request.isEmpty || model.pairingBusy)
                    if let page=model.membershipPage {message(page);Button("Copy update page") {copy(page)}}
                    if model.membershipPageCurrent {Text("This library has no newer signed membership page for that request.").font(.callout).foregroundStyle(.secondary)}
                }
                if model.ownerReviewBusy {HStack {ProgressView().controlSize(.small);Text("Checking saved membership…");Button("Cancel") {model.clearOwnerReview()}}}
                if !inputError.isEmpty {Text(inputError).font(.caption).foregroundStyle(.orange)}
                if let error=model.ownerReviewError {Text(error).font(.caption).foregroundStyle(.orange)}
            }.padding(.top,8)
        }.disabled(model.preparing || model.stopping)
            .onChange(of:model.membershipUpdateReview) {_,review in compared=false;if review != nil {expanded=true}}
    }
    private func message(_ text:String)->some View {
        ScrollView {Text(text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
            .frame(height:100).padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8)).privacySensitive()
    }
    private func copy(_ text:String) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
}
