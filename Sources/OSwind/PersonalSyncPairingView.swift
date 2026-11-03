import SwiftUI
import AppKit
import OSwindCore

struct PersonalSyncPairingSheet:View {
    @ObservedObject var model:PersonalSyncModel
    var body:some View {
        PersonalSyncPairingView(model:model)
            .task(id:model.preparing) {if !model.preparing {model.performPairing(.load)}}
            .onDisappear {model.cancelPairing();model.clearPairingMessages()}
    }
}

struct PersonalSyncPairingView:View {
    @ObservedObject var model:PersonalSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var deviceName=Host.current().localizedName ?? "My Mac"
    @State private var request=""
    @State private var response=""
    @State private var fingerprint=""
    @State private var copied=false
    @State private var retireConfirm=false
    @State private var requestMatches=false
    @State private var fingerprintMatches=false
    @State private var pendingStep=0
    init(model:PersonalSyncModel,receivingResponse:Bool=false) {
        self.model=model;_pendingStep=State(initialValue:receivingResponse ? 1:0)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Image(systemName:"laptopcomputer.and.arrow.down").font(.title2);Text("Pair your Macs").font(.title2.weight(.semibold));Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)}
            Text("Two-Mac sync preview").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text("Pair two Macs, then connect the same shared folder to exchange encrypted memories. Connecting sync does not change your capture choices.").foregroundStyle(.secondary)
            ScrollView {VStack(alignment:.leading,spacing:16) {
                if model.configured || model.preparing {
                    PersonalSyncConnectionDetails(model:model)
                } else if let status=model.pairingStatus {
                    switch status.phase {
                    case .unconfigured:begin
                    case .waitingForOwner:pending(status)
                    case .owner:owner(status)
                    case .paired:paired(status)
                    case .retired:
                        Label("Local pairing retired",systemImage:"key.slash")
                        Text("Private sync keys were removed from this Mac's pairing credential. A keyless record remains to prevent reuse. Other Macs' memberships have not been revoked; recovery and group rotation are still being built.").foregroundStyle(.secondary)
                    }
                    if status.phase == .owner,model.approveMembershipUpdate != nil {PersonalSyncMembershipUpdateView(model:model)}
                } else if !model.pairingBusy {
                    Button("Load saved pairing") {model.performPairing(.load)}
                }
                if !model.configured,let error=model.error {Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
                if let error=model.pairingError {Label(error,systemImage:"exclamationmark.triangle").foregroundStyle(.orange)}
                if model.pairingBusy {HStack {ProgressView().controlSize(.small);Text("Saving and verifying…");Spacer();Button("Cancel") {model.cancelPairing()}}}
            }.padding(.vertical,4)}
            Divider()
            Text("Keys stay in this Mac's login Keychain with a local software binding. Keep the original credentials: missing keys or copied libraries require recovery. Interrupted erasure has a separate cleanup step.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width:660,height:650)
        .disabled(model.stopping)
        .alert("Retire local pairing?",isPresented:$retireConfirm) {
            Button("Cancel",role:.cancel) {};Button("Retire keys",role:.destructive) {model.performPairing(.retire)}
        } message: {Text("Removes private pairing keys from this Mac's saved credential and keeps a keyless recovery record. This does not revoke the device on other Macs. Local memories remain available. Pairing recovery is not yet available in this preview.")}
    }
    private var begin:some View {
        VStack(alignment:.leading,spacing:14) {
            TextField("Name this Mac",text:$deviceName).textFieldStyle(.roundedBorder)
            HStack {Button("Create a group") {model.performPairing(.create(deviceName))}.buttonStyle(.borderedProminent)
                Button("Join an existing group") {model.performPairing(.request(deviceName))}}
            Text("Create on your main Mac. Join on the next Mac, then compare its request and the owner's fingerprint using a channel you trust.").font(.caption).foregroundStyle(.secondary)
        }.disabled(model.pairingBusy)
    }
    private func pending(_ status:PersonalSyncPairingStatus)->some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Waiting for the group owner",systemImage:"person.badge.key")
            Text(status.deviceName).font(.headline)
            Picker("Pairing step",selection:$pendingStep) {Text("1. Send request").tag(0);Text("2. Verify response").tag(1)}.pickerStyle(.segmented)
            if pendingStep==0 {
                Text("Copy this signed public request to the owner's Mac. Compare the request fingerprint on both screens.")
                if let value=status.requestFingerprint {Text(value).font(.system(.caption,design:.monospaced)).textSelection(.enabled)}
                if let value=status.request {message(value,label:"Signed request");Button(copied ? "Copied":"Copy request") {copy(value)}}
                if let expires=status.expires {Text("Request expires \(expires.formatted(date:.omitted,time:.standard)).").font(.caption).foregroundStyle(.secondary)}
                Button("I have an approval response") {pendingStep=1}.buttonStyle(.borderedProminent)
                Button("Replace expired request") {model.performPairing(.renew);response="";fingerprintMatches=false;copied=false}
                Text("Replacing creates fresh keys and invalidates the old response. If the owner already approved it, the unused membership remains until group rotation is available.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Paste the encrypted response. Enter the group fingerprint shown on the owner's screen through a channel you trust.")
                input("Encrypted response",text:$response,limit:98304)
                TextField("Trusted owner's fingerprint (64 hex characters)",text:$fingerprint).textFieldStyle(.roundedBorder).font(.system(.caption,design:.monospaced)).privacySensitive()
                Toggle("I compared the owner's fingerprint through a trusted channel",isOn:$fingerprintMatches)
                Button("Verify and save this Mac") {model.performPairing(.accept(response,fingerprint));response="";fingerprint="";fingerprintMatches=false}.buttonStyle(.borderedProminent).disabled(response.isEmpty || fingerprint.count != 64 || !fingerprintMatches)
            }
            retire
        }.disabled(model.pairingBusy)
    }
    private func owner(_ status:PersonalSyncPairingStatus)->some View {
        VStack(alignment:.leading,spacing:12) {
            identity(status)
            if let value=model.pairingResponse {
                Text("Return this encrypted response to the joining Mac. Give it the group fingerprint above through your trusted channel.")
                Text("The original request expiry still applies. Recovering this exact response does not extend it.").font(.caption).foregroundStyle(.secondary)
                if let expiry=model.pairingResponseExpiry {Text("Request expires \(expiry.formatted(date:.abbreviated,time:.standard))").font(.caption).foregroundStyle(expiry<Date() ? .orange:.secondary)}
                message(value,label:"Encrypted response");Button(copied ? "Copied":"Copy response") {copy(value)}
                Button(status.memberNames.count>=2 ? "Continue to folder setup":"Review another device") {model.clearPairingMessages();copied=false}
            } else if let review=model.pairingReview {
                GroupBox {VStack(alignment:.leading,spacing:10) {
                    Text(review.deviceName).font(.headline)
                    Text(review.requestFingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    Text("Expires \(review.expires.formatted(date:.omitted,time:.standard))").font(.caption)
                    Toggle("The name and request fingerprint match the joining Mac",isOn:$requestMatches)
                    if review.alreadyAdmitted {Text("This Mac is already admitted. Reissue its response without changing membership.").font(.caption).foregroundStyle(.secondary)}
                    else if status.memberNames.count>=2 {Text("This preview cannot add another Mac. Use the original admitted request to recover a legacy approval.").font(.caption).foregroundStyle(.orange)}
                    Button(review.alreadyAdmitted ? "Return approval for this Mac":"Approve this exact request") {model.performPairing(.approve(review));request="";requestMatches=false}.buttonStyle(.borderedProminent).disabled(!requestMatches || (status.memberNames.count>=2 && !review.alreadyAdmitted))
                }}
                Button("Back to request") {model.clearPairingMessages();requestMatches=false}
            } else if !status.deliveryPrepared && status.memberNames.count<2 {
                Text("Add a Mac").font(.headline)
                Text("Paste its signed request. Review the name and compare the exact request fingerprint with the joining Mac before approval.")
                input("Signed request",text:$request,limit:8192)
                Button("Review request") {model.performPairing(.review(request));requestMatches=false}.disabled(request.isEmpty)
            }
            if model.pairingResponse==nil && model.pairingReview==nil {
                if status.lastResponseAvailable {
                    Button("Recover last joining response") {model.performPairing(.recoverResponse);copied=false}
                } else if !status.deliveryPrepared && status.memberNames.count>=2 {
                    DisclosureGroup("Recover a legacy approval") {
                        Text("Paste the original still-valid request from the admitted Mac. Compare its fingerprint again before reissuing a response.").font(.caption).foregroundStyle(.secondary)
                        input("Original admitted request",text:$request,limit:8192)
                        Button("Review original request") {model.performPairing(.review(request));requestMatches=false}.disabled(request.isEmpty)
                    }
                }
            }
            if model.pairingResponse==nil && model.pairingReview==nil {folderSetup(status)}
            if !status.deliveryPrepared {retire}
        }.disabled(model.pairingBusy || model.preparing)
    }
    private func paired(_ status:PersonalSyncPairingStatus)->some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Device paired",systemImage:"checkmark.shield")
            identity(status)
            folderSetup(status)
            if !status.deliveryPrepared {retire}
        }.disabled(model.pairingBusy)
    }
    private func folderSetup(_ status:PersonalSyncPairingStatus)->some View {
        VStack(alignment:.leading,spacing:12) {
            if status.memberNames.count==2 {
                Divider()
                Text("Connect a shared folder").font(.headline)
                Text("Create the sync folder on the first Mac, then select that same folder on the other Mac. Your folder provider must make its files available locally.").foregroundStyle(.secondary)
                if model.folderURL != nil {Button("Reconnect saved folder") {model.reconnectSavedFolder()}.buttonStyle(.borderedProminent)}
                HStack {
                    if !status.deliveryPrepared {Button("Create sync folder…") {chooseFolder(create:true)}}
                    Button(model.folderURL == nil ? "Choose existing folder…":"Locate existing folder…") {chooseFolder(create:false)}
                }
                Text("Use only these two trusted Macs. Membership refresh, revocation and group rotation are still in development. Paired Macs can publish an approved group erase that also removes unsynced local history when observed.").font(.caption).foregroundStyle(.secondary)
            } else if status.memberNames.count>2 {
                Text("This setup preview supports two Macs. This group needs membership refresh before it can connect here.").foregroundStyle(.secondary)
            }
        }
    }
    private func chooseFolder(create:Bool) {
        if create {
            let panel=NSSavePanel();panel.title="Create encrypted sync folder";panel.prompt="Create folder";panel.nameFieldStringValue="OSwind Sync";panel.canCreateDirectories=true
            if panel.runModal() == .OK,let url=panel.url {model.connectFolder(url,create:true)}
        } else {
            let panel=NSOpenPanel();panel.title="Choose the existing OSwind sync folder";panel.prompt="Connect folder";panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false;panel.canCreateDirectories=false
            if panel.runModal() == .OK,let url=panel.url {model.connectFolder(url)}
        }
    }
    private func identity(_ status:PersonalSyncPairingStatus)->some View {
        VStack(alignment:.leading,spacing:10) {
            Text(status.deviceName).font(.headline)
            Text("Group fingerprint").font(.caption).foregroundStyle(.secondary)
            if let value=status.rootFingerprint {Text(value).font(.system(.caption,design:.monospaced)).textSelection(.enabled);Button("Copy group fingerprint") {copy(value)}}
            Text("\(status.memberNames.count) admitted device\(status.memberNames.count==1 ? "":"s") · \(status.memberNames.joined(separator:", "))").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var retire:some View {Button("Retire local pairing keys…",role:.destructive) {retireConfirm=true}.padding(.top,12)}
    private func input(_ title:String,text:Binding<String>,limit:Int)->some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.caption)
            TextEditor(text:Binding(get:{text.wrappedValue},set:{value in
                // Bound retained UI input before handing it to the canonical
                // decoder. Oversized input is cleared and cannot be approved.
                text.wrappedValue=value.utf8.count<=limit ? value:""
                model.clearPairingMessages();requestMatches=false
            })).font(.system(.caption,design:.monospaced)).frame(height:82).border(.quaternary).privacySensitive()
        }
    }
    private func message(_ value:String,label:String)->some View {
        DisclosureGroup(label) {Text(value).font(.system(size:10,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).privacySensitive()}
    }
    private func copy(_ value:String) {
        let board=NSPasteboard.general,item=NSPasteboardItem()
        item.setString(value,forType:.string)
        for type in ["org.nspasteboard.ConcealedType","org.nspasteboard.TransientType","org.nspasteboard.AutoGeneratedType"] {item.setData(Data(),forType:.init(type))}
        board.clearContents();copied=board.writeObjects([item])
    }
}
