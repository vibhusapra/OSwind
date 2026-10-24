import SwiftUI
import AppKit
import Combine
import Darwin
import OSwindCore

@MainActor final class AppSession: ObservableObject {
    static weak var current:AppSession?
    @Published var model:AppModel?
    @Published var failure:String?
    @Published var requested:URL
    @Published private(set) var vaultPackage:URL?
    @Published private(set) var vaultStatus:LibraryVaultStatus?
    @Published private(set) var busy=false
    @Published private(set) var progress:LibraryBackupProgress?
    @Published var message=""
    @Published var showVaultSetup=false
    @Published private(set) var createdVault:URL?
    @Published private(set) var snapshotNeedsReview=false
    let recoveryTransfer=LibraryTransferModel()
    private var selection:LibraryLocationSelection
    private let defaults:UserDefaults
    private let locked:() -> Bool
    private var operation:Task<Void,Never>?
    private var pendingLock=false
    private var closingStore:MemoryStore?
    private var workspaceSubscriptions=Set<AnyCancellable>()
    private var watcher:DispatchSourceFileSystemObject?
    private var lockMonitor:Timer?
    init(selection:LibraryLocationSelection?=nil,defaults:UserDefaults = .standard,locked:@escaping () -> Bool={SessionState.locked}) {
        let resolved=selection ?? LibraryLocationPreferences.selection(demo:CommandLine.arguments.contains("--demo"),defaults:defaults)
        self.selection=resolved;self.defaults=defaults;self.locked=locked;requested=resolved.url
        do {
            if let package=try LibraryVault.package(containing:resolved.url) {
                vaultPackage=package;requested=package.appendingPathComponent("Library");watch(package)
                run {try await self.loadVault(startServices:true)}
            } else {try resolved.validate();model=try AppModel(root:resolved.url)}
        } catch {failure=error.localizedDescription}
        for name in [NSWorkspace.willSleepNotification,NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for:name).sink {[weak self] _ in self?.requestLock()}.store(in:&workspaceSubscriptions)
        }
        Self.current=self
    }
    deinit {watcher?.cancel();lockMonitor?.invalidate();operation?.cancel()}
    func retry() {
        guard !busy else {return}
        if vaultPackage != nil {run {try await self.loadVault(startServices:false)}} else {open(selection.url,persist:false)}
    }
    func open(_ url:URL,persist:Bool=true) {
        guard maySwitch else {return}
        run {
            let package=try LibraryVault.package(containing:url)
            if package==self.vaultPackage,self.model != nil {return}
            if package==nil {try LibraryLocationSelection(url:url,requiresExisting:true,origin:"selected").validate()}
            try await self.departCurrent()
            self.selection = .init(url:package?.appendingPathComponent("Library") ?? url,requiresExisting:true,origin:"selected")
            self.requested=self.selection.url;self.vaultPackage=package;self.vaultStatus=nil;self.message="";self.createdVault=nil;self.snapshotNeedsReview=false
            self.watch(package)
            if let package {
                if persist {try LibraryLocationPreferences.save(package,defaults:self.defaults)}
                try await self.loadVault(startServices:false)
            } else {
                let candidate=try AppModel(root:url,startServices:false)
                if persist {try LibraryLocationPreferences.save(url,defaults:self.defaults)}
                self.model=candidate
            }
        }
    }
    private var maySwitch:Bool {
        guard !busy,model?.libraryTransfer.busy != true,model?.libraryWipe.busy != true,!recoveryTransfer.busy else {failure="Complete or cancel the current library operation before switching libraries.";return false};return true
    }
    func choose() {
        guard maySwitch else {return}
        let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=true;panel.treatsFilePackagesAsDirectories=false;panel.allowsMultipleSelection=false;panel.prompt="Open library"
        guard panel.runModal() == .OK,let url=panel.url else {return};open(url)
    }
    func openDefault() {
        guard maySwitch else {return}
        run {
            try await self.departCurrent()
            let next=LibraryLocationSelection(url:Paths.data,requiresExisting:false,origin:"default");try next.validate()
            let candidate=try AppModel(root:next.url,startServices:false)
            self.defaults.removeObject(forKey:LibraryLocationPreferences.key);self.selection=next;self.requested=next.url;self.vaultPackage=nil;self.vaultStatus=nil;self.watch(nil);self.model=candidate
        }
    }
    private func loadVault(startServices:Bool) async throws {
        guard let package=vaultPackage else {return}
        let vault=try LibraryVault(package:package);vaultStatus=try await vault.status()
        if vaultStatus?.state == .unlocked {
            if locked() {try await performLock();return}
            if model==nil {model=try AppModel(root:vault.libraryURL,startServices:startServices)}
        } else if let previous=model {
            previous.clearForVaultLock();closingStore=previous.store;model=nil
            // A competing CLI may have already replaced the public handle. The
            // store retains its verified canonical root solely for safe close.
            let store=previous.store;try await Task.detached(priority:.utility) {try store.close()}.value;closingStore=nil
        }
    }
    func unlock(passphrase:String,remember:Bool,using provider:any VaultSecretProvider=UserPresenceVaultSecrets()) {
        guard !busy,let package=vaultPackage else {return}
        message=""
        run {
            var secret=Data(passphrase.utf8);defer {secret.resetBytes(in:0..<secret.count)}
            let vault=try LibraryVault(package:package);self.vaultStatus=try await vault.unlock(passphrase:secret)
            try Task.checkCancellation()
            if remember {
                do {try await vault.rememberPassphrase(secret,using:provider);self.vaultStatus=try await vault.status()}
                catch {self.message="Library unlocked. Keychain was not updated: "+error.localizedDescription}
            }
            if self.locked() {try await self.performLock();return}
            self.model=try AppModel(root:vault.libraryURL,startServices:false)
            if self.message.isEmpty {self.message="Library unlocked. Recording starts when you resume it."}
        }
    }
    func unlockWithKeychain(using provider:any VaultSecretProvider=UserPresenceVaultSecrets()) {
        guard !busy,let package=vaultPackage else {return}
        message=""
        run {
            let vault=try LibraryVault(package:package);self.vaultStatus=try await vault.unlockUsingKeychain(using:provider);try Task.checkCancellation()
            if self.locked() {try await self.performLock();return}
            self.model=try AppModel(root:vault.libraryURL,startServices:false)
            self.message="Library unlocked. Recording starts when you resume it."
        }
    }
    func forgetKeychain() {
        guard !busy,let package=vaultPackage else {return}
        run {let vault=try LibraryVault(package:package);try await vault.forgetPassphrase();self.vaultStatus=try await vault.status();self.message="Saved unlock removed. Your vault passphrase still works."}
    }
    func requestLock() {
        guard vaultPackage != nil || busy else {return}
        if busy {pendingLock=true;operation?.cancel();return}
        run {try await self.performLock()}
    }
    private func performLock() async throws {
        guard let package=vaultPackage else {return}
        if let previous=model {previous.clearForVaultLock();closingStore=previous.store;model=nil}
        let vault=try LibraryVault(package:package)
        vaultStatus=try await vault.lock(store:closingStore);closingStore=nil
        guard vaultStatus?.state == .locked else {throw OSwindError.unavailable("The encrypted volume is still attached. Retry locking when other readers finish.")}
        message="Encrypted volume detached. Recording, audio and local API access are stopped."
    }
    private func departCurrent() async throws {
        if vaultPackage != nil {try await performLock()}
        else if let previous=model {
            previous.clearForVaultLock();closingStore=previous.store;model=nil
            let store=previous.store;try await Task.detached(priority:.utility) {try store.close()}.value;closingStore=nil
        } else if let store=closingStore {try await Task.detached(priority:.utility) {try store.close()}.value;closingStore=nil}
    }
    func createVault(at package:URL,name:String,capacityGiB:Int,passphrase:String,copyHistory:Bool,remember:Bool,observeMigration:@escaping @Sendable (LibraryBackupProgress)->Void={_ in}) {
        guard maySwitch else {return}
        let original=model,source=copyHistory ? original?.store:nil
        if copyHistory,source==nil {failure="Open the source library before copying history.";return}
        message="";snapshotNeedsReview=false
        original?.prepareForLibrarySwitch()
        run {
            let relay=LibraryProgressRelay(),observer=Task {while !Task.isCancelled {do {try await Task.sleep(for:.milliseconds(100))} catch {break};self.progress=relay.get() ?? self.progress}}
            defer {observer.cancel();self.progress=nil}
            var secret=Data(passphrase.utf8);defer {secret.resetBytes(in:0..<secret.count)}
            self.progress = .init(phase:"Creating encrypted storage")
            do {
                if let source {
                    let result=try await LibraryVault.migrate(from:source,to:package,name:name,capacityGiB:capacityGiB,passphrase:secret,progress:{relay.set($0);observeMigration($0)})
                    self.createdVault=package
                    if !result.sourceStable {
                        if let original {try await self.restorePreparedOriginal(original)}
                        self.snapshotNeedsReview=true
                        self.message="A verified encrypted snapshot was saved, but the original changed during the copy. OSwind kept the original selected. Open the snapshot explicitly or make another copy after stopping other writers."
                        self.showVaultSetup=false;return
                    }
                } else {_=try await LibraryVault.create(at:package,name:name,capacityGiB:capacityGiB,passphrase:secret);self.createdVault=package}
                try Task.checkCancellation();try await self.departCurrent()
                let managed=try LibraryVault(package:package)
                self.vaultPackage=managed.packageURL;self.requested=managed.libraryURL;self.selection = .init(url:self.requested,requiresExisting:true,origin:"selected");self.watch(managed.packageURL)
                try LibraryLocationPreferences.save(package,defaults:self.defaults)
                let vault=try LibraryVault(package:package);self.vaultStatus=try await vault.unlock(passphrase:secret)
                try Task.checkCancellation()
                if remember {do {try await vault.rememberPassphrase(secret);self.vaultStatus=try await vault.status()} catch {self.message="Encrypted library created. Keychain was not updated: "+error.localizedDescription}}
                if self.locked() {try await self.performLock()} else {self.model=try AppModel(root:vault.libraryURL,startServices:false)}
                if self.message.isEmpty {self.message=copyHistory ? "Encrypted copy verified. The original library is still on disk; recording starts when you resume it.":"Encrypted library ready. Recording starts when you resume it."}
                self.showVaultSetup=false
            } catch {
                // A failed or cancelled copy never selects its destination. A
                // prepared source resumes as a fresh, quiet model when possible.
                if let original,self.model === original,!original.store.isClosed {try await self.restorePreparedOriginal(original)}
                throw error
            }
        }
    }
    private func restorePreparedOriginal(_ original:AppModel) async throws {
        let store=original.store;try await Task.detached(priority:.utility) {try store.close()}.value
        model=try AppModel(root:store.root,startServices:false)
    }
    func cancelOperation() {if vaultPackage != nil {pendingLock=true};operation?.cancel()}
    func lockForTermination() async -> Bool {
        if busy {cancelOperation();while busy {if let operation {await operation.value} else {break}}}
        guard vaultPackage != nil else {model?.prepareForLibrarySwitch();return true}
        if vaultStatus?.state != .locked {requestLock();while busy {if let operation {await operation.value} else {break}}}
        return vaultStatus?.volumeMounted == false
    }
    private func run(_ work:@escaping @MainActor () async throws -> Void) {
        guard !busy else {return};busy=true;failure=nil
        operation=Task {
            do {try await work()}
            catch is CancellationError {self.message="Operation stopped. Existing libraries were preserved. Check vault status before retrying."}
            catch {self.failure=error.localizedDescription}
            if let package=self.vaultPackage {
                let status=Task.detached {try await LibraryVault(package:package).status()}
                if let fresh=try? await status.value {self.vaultStatus=fresh}
            }
            self.busy=false;self.operation=nil
            if self.pendingLock {self.pendingLock=false;self.requestLock()}
        }
    }
    #if DEBUG
    static func previewVault(in root:URL,state:LibraryVaultState) async throws -> AppSession {
        let package=root.appendingPathComponent("Preview-"+UUID().uuidString+".oswindvault");try Paths.ensure(package)
        var info=LibraryVaultInfo(name:"Private memory · sample",capacityGiB:128,volumeUUID:UUID().uuidString,keychainEnabled:true);info.setupComplete=true
        try JSONEncoder().encode(info).write(to:package.appendingPathComponent("oswind-vault.json"));try Data("Owned closed preview handle".utf8).write(to:package.appendingPathComponent("Library"))
        let session=AppSession(selection:.init(url:package,requiresExisting:true,origin:"preview"),locked:{false})
        while session.busy {try await Task.sleep(for:.milliseconds(10))}
        session.vaultStatus?.state=state;session.vaultStatus?.volumeMounted=state == .closing
        session.vaultStatus?.message=state == .closing ? "The encrypted volume is still mounted. Finish the current operation or retry locking.":"Encrypted volume is detached"
        if state == .closing {session.failure="The vault is still mounted because files are in use. Close other readers and retry locking."}
        return session
    }
    #endif
    private func watch(_ package:URL?) {
        watcher?.cancel();watcher=nil;lockMonitor?.invalidate();lockMonitor=nil
        guard let package else {return}
        // Workspace sleep/session events are the fast path. This bounded check
        // also covers a locked session that produces no workspace notification.
        lockMonitor=Timer.scheduledTimer(withTimeInterval:1,repeats:true) {[weak self] _ in Task {@MainActor in
            guard let self,self.model != nil,self.locked() else {return};self.requestLock()
        }}
        lockMonitor?.tolerance=0.25
        let fd=Darwin.open(package.path,O_EVTONLY | O_CLOEXEC);guard fd>=0 else {return}
        let source=DispatchSource.makeFileSystemObjectSource(fileDescriptor:fd,eventMask:[.write,.rename,.delete],queue:.main)
        source.setCancelHandler {close(fd)}
        source.setEventHandler {[weak self] in
            guard let self,!self.busy,self.vaultPackage==package else {return}
            self.run {try await self.loadVault(startServices:false)}
        }
        watcher=source;source.resume()
    }
}
struct LibraryRecoveryView:View {
    @ObservedObject var session:AppSession
    var body:some View {
        ScrollView {VStack(alignment:.leading,spacing:22) {
            Image(systemName:"externaldrive.badge.exclamationmark").font(.system(size:42)).foregroundStyle(OSwindTheme.accent)
            Text("Your library is unavailable.").font(.largeTitle.weight(.semibold))
            Text(session.failure ?? "Reconnect its drive or choose another library.").foregroundStyle(.secondary).textSelection(.enabled)
            Text(session.requested.path).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if session.busy {ProgressView("Opening library…")}
            HStack {Button("Try again") {session.retry()};Button("Choose library…") {session.choose()};Button("Open default library") {session.openDefault()}}.disabled(session.busy || session.recoveryTransfer.busy)
            Button("Create encrypted library…") {session.showVaultSetup=true}.disabled(session.busy)
            Divider();Text("Restore from a backup").font(.title2.weight(.medium));LibraryTransferView(transfer:session.recoveryTransfer,store:nil).disabled(session.busy)
        }.padding(40).frame(maxWidth:800,alignment:.leading).frame(maxWidth:.infinity)}
    }
}
