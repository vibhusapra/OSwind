import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSwindCore

struct VaultLockedView:View {
    @ObservedObject var session:AppSession
    @State private var passphrase=""
    @State private var remember=false
    private var state:LibraryVaultState? {session.vaultStatus?.state}
    private var finishing:Bool {state == .closing || state == .opening || (state == .unavailable && session.vaultStatus?.imageAttached == true)}
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:15) {
                    Image(systemName:finishing ? "externaldrive.badge.exclamationmark":"lock.shield").font(.system(size:42)).foregroundStyle(OSwindTheme.accent)
                    VStack(alignment:.leading,spacing:6) {
                        Text(session.vaultStatus?.info.name ?? "Encrypted library").font(.system(size:30,weight:.semibold,design:.rounded))
                        Text(finishing ? "Locking needs attention":state == .unlocked ? "Library is mounted":"Your history stays with you.").foregroundStyle(.secondary)
                    }
                }
                Text(finishing ? "Recording and local access are stopped. The encrypted volume is still attached.":session.vaultStatus?.message ?? "Checking the encrypted library…").textSelection(.enabled)
                if finishing {
                    if session.failure==nil {Label("Close other readers and retry locking.",systemImage:"exclamationmark.circle").foregroundStyle(.orange)}
                    Button("Retry locking") {session.requestLock()}.buttonStyle(.borderedProminent).disabled(session.busy)
                } else if state == .unlocked {
                    HStack {Button("Open library") {session.retry()}.buttonStyle(.borderedProminent);Button("Lock library") {session.requestLock()}}.disabled(session.busy)
                } else if session.vaultStatus != nil {
                    VStack(alignment:.leading,spacing:12) {
                        if session.vaultStatus?.info.keychainEnabled == true {
                            Button {passphrase="";session.unlockWithKeychain()} label:{Label("Unlock with Mac authentication",systemImage:"touchid")}.buttonStyle(.borderedProminent).controlSize(.large).disabled(UserPresenceVaultSecrets.unavailabilityReason != nil)
                            Text("Touch ID or your Mac password protects the saved unlock. You can always use the vault passphrase.").font(.caption).foregroundStyle(.secondary)
                            Divider()
                        }
                        SecureField("Vault passphrase",text:$passphrase).textFieldStyle(.roundedBorder).onSubmit {unlock()}
                        Toggle("Remember in Keychain with Mac authentication",isOn:$remember).font(.callout).disabled(UserPresenceVaultSecrets.unavailabilityReason != nil)
                        if let reason=UserPresenceVaultSecrets.unavailabilityReason {Text(reason).font(.caption).foregroundStyle(.secondary)}
                        Button("Unlock library",action:unlock).buttonStyle(.borderedProminent).disabled(passphrase.utf8.count<12)
                    }.disabled(session.busy).frame(maxWidth:480)
                }
                if session.busy {HStack {ProgressView().controlSize(.small);Text(session.progress?.phase ?? "Working safely…");Button("Stop") {passphrase="";session.cancelOperation()}}}
                if let failure=session.failure {Label(failure,systemImage:"exclamationmark.circle").foregroundStyle(.orange).textSelection(.enabled)}
                if !session.message.isEmpty {Text(session.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
                Divider()
                Label("AES-256 encrypted disk image · on this Mac",systemImage:"externaldrive").font(.callout)
                Text("Unlock mounts the encrypted volume. Lock stops recording and local access, closes this app’s library connection, and verifies the volume is detached. An interrupted or busy lock is shown above.").font(.caption).foregroundStyle(.secondary)
                if let package=session.vaultPackage {Text(package.path).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)}
                HStack {
                    Button("Choose another library…") {session.choose()}
                    Button("Create encrypted library…") {session.showVaultSetup=true}
                    if session.vaultStatus?.info.keychainEnabled == true {Button("Forget saved unlock") {session.forgetKeychain()}}
                }.disabled(session.busy)
            }.padding(44).frame(maxWidth:800,alignment:.leading).frame(maxWidth:.infinity)
        }.onDisappear {passphrase=""}
    }
    private func unlock() {
        guard passphrase.utf8.count>=12,!session.busy else {return}
        let value=passphrase;passphrase="";session.unlock(passphrase:value,remember:remember)
    }
}
struct VaultSetupView:View {
    @ObservedObject var session:AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var name="Private memory"
    @State private var capacity=128
    @State private var passphrase=""
    @State private var confirmation=""
    @State private var copyHistory=true
    @State private var remember=false
    private var valid:Bool {let count=passphrase.utf8.count;return !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && name.count<=128 && (12...4096).contains(count) && !passphrase.utf8.contains(0) && passphrase==confirmation}
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            HStack {Image(systemName:"lock.shield").font(.system(size:32)).foregroundStyle(OSwindTheme.accent);VStack(alignment:.leading,spacing:4) {Text("A private home for your history").font(.title2.weight(.semibold));Text("An encrypted library you control.").foregroundStyle(.secondary)}}
            ScrollView {VStack(alignment:.leading,spacing:18) {
                TextField("Library name",text:$name).textFieldStyle(.roundedBorder)
                if session.model != nil {Toggle("Copy my current history into this library",isOn:$copyHistory);Text("The copy includes retained media, conversations and search vectors. Your original stays on disk. OSwind verifies the snapshot before changing libraries.").font(.caption).foregroundStyle(.secondary)}
                VStack(alignment:.leading,spacing:10) {
                    SecureField("New passphrase · at least 12 UTF-8 bytes",text:$passphrase)
                    SecureField("Confirm passphrase",text:$confirmation)
                    Text("Keep a recovery copy of this passphrase. OSwind cannot reset it.").font(.caption).foregroundStyle(.secondary)
                }.textFieldStyle(.roundedBorder)
                Toggle("Remember in Keychain with Mac authentication",isOn:$remember).disabled(UserPresenceVaultSecrets.unavailabilityReason != nil)
                if let reason=UserPresenceVaultSecrets.unavailabilityReason {Text(reason).font(.caption).foregroundStyle(.secondary)}
                else {Text("Optional. The saved unlock requires Touch ID or your Mac password. OSwind never requests authentication at launch.").font(.caption).foregroundStyle(.secondary)}
                Stepper("Maximum volume size: \(capacity) GB",value:$capacity,in:1...4096,step:16)
                Text("The sparse image grows as you save history; it does not reserve the full maximum. Recording, local API access and automatic cleanup start off in a copied library.").font(.caption).foregroundStyle(.secondary)
                if session.busy {VStack(alignment:.leading,spacing:7) {ProgressView(session.progress?.phase ?? "Preparing encrypted storage…");if let p=session.progress,p.totalItems>0 {Text("\(p.completedItems) / \(p.totalItems) \(p.unit)").font(.caption).monospacedDigit()}}}
                if let failure=session.failure {Text(failure).foregroundStyle(.orange).textSelection(.enabled)}
                if !session.message.isEmpty {Text(session.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)}
            }.padding(.trailing,8)}.disabled(session.busy)
            Divider()
            HStack {
                Button(session.busy ? "Stop safely":"Cancel") {if session.busy {session.cancelOperation()} else {dismiss()}}
                Spacer()
                Button("Choose location and create…",action:create).buttonStyle(.borderedProminent).disabled(!valid || session.busy)
            }
        }.padding(30).frame(width:600,height:620).interactiveDismissDisabled(session.busy).onDisappear {passphrase="";confirmation=""}
    }
    private func create() {
        let panel=NSSavePanel();panel.nameFieldStringValue=name+".oswindvault";panel.allowedContentTypes=[UTType(exportedAs:"com.oswind.vault",conformingTo:.package)];panel.canCreateDirectories=true;panel.message="Choose a new encrypted-library package. Existing files are never replaced."
        guard panel.runModal() == .OK,let url=panel.url else {return}
        let secret=passphrase;passphrase="";confirmation=""
        session.createVault(at:url,name:name,capacityGiB:capacity,passphrase:secret,copyHistory:copyHistory && session.model != nil,remember:remember)
    }
}
struct VaultStorageControls:View {
    let root:URL
    private var package:URL? {try? LibraryVault.package(containing:root)}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if package != nil {
                Label("Managed encrypted library",systemImage:"lock.shield").font(.headline)
                Text("Database, retained media and supported temporary work live inside the encrypted volume. Lock verifies that the volume detaches; a busy volume remains visibly pending.").font(.caption).foregroundStyle(.secondary)
                HStack {Button("Lock library") {NotificationCenter.default.post(name:.oswindLockVault,object:nil)};Button("Forget saved unlock") {NotificationCenter.default.post(name:.oswindForgetVaultSecret,object:nil)}}
            } else {Text("Protect this history with a separately locked encrypted library. Copying verifies the destination and keeps your original library.").font(.caption).foregroundStyle(.secondary)}
            Button("Create encrypted library…") {NotificationCenter.default.post(name:.oswindCreateVault,object:nil)}
            Text("Explicit backups, Markdown and JSON exports are readable copies. Original libraries and earlier exports are retained separately.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
