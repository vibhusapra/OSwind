import SwiftUI
import AppKit
import OSwindCore

struct PersonalSyncMembershipUpdateView:View {
    @ObservedObject var model:PersonalSyncModel
    @State private var expanded:Bool
    @State private var page=""
    @State private var request=""
    @State private var inputError=""
    @State private var compared=false
    init(model:PersonalSyncModel,initiallyExpanded:Bool=false) {self.model=model;_expanded=State(initialValue:initiallyExpanded)}
    var body:some View {
        DisclosureGroup("Update paired Macs",isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:12) {
                Text("Membership preview. Updates reopen this library with recording and sync paused. Compare revisions on every Mac before reconnecting.").font(.caption).foregroundStyle(.orange)
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
                        signedInput("Signed update page from the owner",text:$page,limit:PersonalSyncPairing.maximumMembershipUpdateBytes,tooLong:"This update is too long. Ask the owner to copy one signed page again.")
                        Button("Review update page") {compared=false;inputError="";model.reviewMembershipPage(page)}.disabled(page.isEmpty || model.ownerReviewBusy)
                    }
                }else if model.pairingStatus?.phase == .owner {
                    Text("Help an existing Mac catch up").font(.headline)
                    Text("Paste its public membership request. Return the signed page through your trusted channel. No private keys are included.").font(.callout)
                    signedInput("Public membership request from the other Mac",text:$request,limit:PersonalSyncPairing.maximumMembershipRequestBytes,tooLong:"This request is too long. Copy the current membership request again.")
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
    private func signedInput(_ title:String,text:Binding<String>,limit:Int,tooLong:String)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.caption.weight(.semibold))
            ZStack(alignment:.topLeading) {
                TextEditor(text:Binding(get:{text.wrappedValue},set:{value in
                    guard value.utf8.count<=limit else {text.wrappedValue="";inputError=tooLong;return}
                    text.wrappedValue=value;inputError=""
                })).font(.system(.caption,design:.monospaced)).scrollContentBackground(.hidden).padding(6).accessibilityLabel(title)
                if text.wrappedValue.isEmpty {Text("Paste here").font(.caption).foregroundStyle(.secondary).padding(.horizontal,11).padding(.vertical,14).allowsHitTesting(false).accessibilityHidden(true)}
            }.frame(height:110).background(.quaternary.opacity(0.15),in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).stroke(.quaternary)).privacySensitive()
        }
    }
    private func message(_ text:String)->some View {
        ScrollView {Text(text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
            .frame(height:100).padding(8).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8)).privacySensitive()
    }
    private func copy(_ text:String) {NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string)}
}
