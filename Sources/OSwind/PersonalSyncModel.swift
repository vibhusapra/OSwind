import Foundation
import Combine
import OSwindCore

/// Own the actual core session, its serialized commands and the status consumer.
/// An app retirement closes admission synchronously, then joins all three before
/// SQLite close, vault unmount or wipe. No enrollment keys enter this model.
@MainActor final class PersonalSyncModel:ObservableObject {
    @Published private(set) var pairingStatus:PersonalSyncPairingStatus?
    @Published private(set) var pairingReview:PersonalSyncPairingReview?
    @Published private(set) var pairingResponse:String?
    @Published private(set) var pairingBusy=false
    @Published private(set) var pairingError:String?
    @Published private(set) var status:PersonalSyncStatus?
    @Published private(set) var networkPaused=false
    @Published private(set) var changing=false
    @Published private(set) var stopping=false
    @Published private(set) var preparing=false
    @Published private(set) var error:String?
    var allowed:()->Bool={true}
    private let store:MemoryStore,locked:()->Bool
    private var session:PersonalSyncSession?
    private var observer:Task<Void,Never>?,command:Task<Void,Never>?,stopTask:Task<Bool,Never>?
    private var preparation:Task<Bool,Never>?
    private var pairing:PersonalSyncPairing?,pairingTask:Task<Void,Never>?
    private let pairingFactory:@Sendable (MemoryStore)throws->PersonalSyncPairing
    private var drains=0
    private var generation=UUID(),retired=false,desiredActive=false,desiredNetwork=true,suspended=false
    var configured:Bool {session != nil}
    var busy:Bool {drains>0 || pairing != nil || pairingTask != nil || preparation != nil || session != nil || observer != nil || command != nil || stopTask != nil}
    init(store:MemoryStore,locked:@escaping ()->Bool={SessionState.locked},pairingFactory:@escaping @Sendable (MemoryStore)throws->PersonalSyncPairing={try PersonalSyncPairing(store:$0)}) {self.store=store;self.locked=locked;self.pairingFactory=pairingFactory}
    deinit {
        // Fallback cancellation prevents an idle subscription retaining a
        // session forever. Real storage departure still awaits cancelAndWait.
        preparation?.cancel();pairingTask?.cancel();observer?.cancel();command?.cancel()
        if let pairing {Task.detached {pairing.close()}}
        if let session {Task {try? await session.stop()}}
    }
    /// Called only with a session prepared by the enrollment owner. This cannot
    /// create peers, change group authority or bypass core policy/media checks.
    func attachPrepared(_ candidate:PersonalSyncSession)throws {
        try attach(candidate,fromPreparation:false)
    }
    private func attach(_ candidate:PersonalSyncSession,fromPreparation:Bool)throws {
        guard !retired,session==nil,observer==nil,command==nil,stopTask==nil,
              pairing==nil,pairingTask==nil,(preparation==nil || fromPreparation),!store.isClosed,!locked(),allowed(),candidate.belongs(to:store) else {throw OSwindError.unavailable("Sync requires its current open library")}
        session=candidate;error=nil
        observer=Task {[weak self] in
            let stream=await candidate.updates()
            for await value in stream {
                guard let self,!self.retired,!Task.isCancelled else {break}
                if self.status != value {self.status=value}
            }
        }
        enqueueConfiguration()
    }
    /// Take lifetime ownership BEFORE setup may touch SQLite or the vault.
    /// The operation owns partially constructed resources until it returns a
    /// session. Cancellation is advisory: even a late result is stopped and
    /// joined before library departure. This grants no enrollment authority.
    func prepare(_ operation:@escaping @Sendable (MemoryStore)async throws->PersonalSyncSession)throws {
        guard !retired,!busy,!store.isClosed,!locked(),allowed() else {throw OSwindError.unavailable("Sync setup requires its current open library")}
        preparing=true;error=nil
        let store=store
        preparation=Task {[weak self] in
            defer {self?.preparing=false;self?.preparation=nil}
            do {
                let candidate=try await operation(store)
                if !Task.isCancelled,let self,!self.retired,!self.store.isClosed,!self.locked(),self.allowed(),candidate.belongs(to:self.store) {
                    do {try self.attach(candidate,fromPreparation:true);return true}
                    catch { /* Retain ownership until the rejected result stops. */ }
                }
                do {
                    try await candidate.stop()
                    if let self,!self.retired,!Task.isCancelled {self.error="Sync setup finished after library access changed. Try again from the current library."}
                    return true
                }
                catch {
                    if let self,!self.retired {self.error="Sync setup stopped, but its connection needs to be reopened."}
                    return false
                }
            }catch {
                if let self,!self.retired,!Task.isCancelled {self.error="Sync setup could not finish. Check the connection and try again."}
                return true
            }
        }
    }
    enum PairingAction:Sendable {
        case load,create(String),request(String),renew,review(String),approve(PersonalSyncPairingReview),accept(String,String),retire
    }
    private struct PairingResult:Sendable {
        let owner:PersonalSyncPairing,status:PersonalSyncPairingStatus,review:PersonalSyncPairingReview?,response:String?
    }
    /// Pairing owns the same app exit/switch/wipe barrier as a prepared delivery
    /// session. No detached SQL/Keychain work can outlive this tracked task.
    func performPairing(_ action:PairingAction) {
        guard !retired,drains==0,session==nil,preparation==nil,pairingTask==nil,!store.isClosed,!locked(),allowed() else {return}
        if case .load=action,pairing != nil {return}
        let existing=pairing,store=store,factory=pairingFactory
        pairingBusy=true;pairingError=nil;pairingReview=nil;pairingResponse=nil
        pairingTask=Task {[weak self] in
            let worker=Task.detached {()throws->PairingResult in
                let owner=try existing ?? factory(store)
                do {
                    guard owner.belongs(to:store) else {throw OSwindError.unavailable("Pair only the current native library")}
                    try Task.checkCancellation()
                    var review:PersonalSyncPairingReview?,response:String?
                    switch action {
                    case .load:break
                    case .create(let name):_=try owner.createGroup(deviceName:name)
                    case .request(let name):_=try owner.requestJoin(deviceName:name)
                    case .renew:_=try owner.renewRequest()
                    case .review(let text):review=try owner.reviewRequest(text)
                    case .approve(let value):response=try owner.approve(value)
                    case .accept(let text,let fingerprint):_=try owner.acceptResponse(text,trustedRootFingerprint:fingerprint)
                    case .retire:_=try owner.retire()
                    }
                    return try .init(owner:owner,status:owner.status(),review:review,response:response)
                }catch {if existing==nil {owner.close()};throw error}
            }
            defer {self?.pairingTask=nil;self?.pairingBusy=false}
            do {
                let result=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                guard !Task.isCancelled,let self,!self.retired,!store.isClosed,!self.locked(),self.allowed(),result.owner.belongs(to:store) else {result.owner.close();self?.pairing=nil;self?.pairingStatus=nil;return}
                self.pairing=result.owner;self.pairingStatus=result.status;self.pairingReview=result.review;self.pairingResponse=result.response
            }catch {
                // A committed Keychain replacement remains authoritative even
                // if status refresh/cancellation fails. Reload before retrying.
                existing?.close()
                if let self {
                    self.pairing=nil;self.pairingStatus=nil
                    if !self.retired,!Task.isCancelled {self.pairingError="Pairing could not finish. Reopen setup to resume its saved state. If access is missing or this library was copied or erased, recovery is required. Local recording remains available."}
                }
            }
        }
    }
    func cancelPairing() {pairingTask?.cancel()}
    func clearPairingMessages() {pairingReview=nil;pairingResponse=nil}
    /// Do not clear the task here: storage still belongs to the real setup job.
    func cancelPreparation() {preparation?.cancel()}
    func start() {
        guard !retired,!store.isClosed,!locked(),allowed() else {return}
        desiredActive=true;enqueueConfiguration()
    }
    func configure(active:Bool) {
        guard !retired else {return}
        desiredActive=active
        enqueueConfiguration()
    }
    func suspend() {guard !retired else {return};suspended=true;enqueueConfiguration()}
    func wake() {guard !retired else {return};suspended=false;enqueueConfiguration()}
    func prepareForReconnection() {
        guard retired,!busy else {return};retired=false;suspended=false;desiredActive=false;desiredNetwork=true;networkPaused=false;status=nil;error=nil;pairingStatus=nil;pairingError=nil
    }
    func setNetworkEnabled(_ enabled:Bool) {
        guard !retired,configured,!store.isClosed,!locked(),allowed() else {return}
        desiredNetwork=enabled;enqueueConfiguration()
    }
    private func enqueueConfiguration() {
        guard !retired,let session else {return}
        let previous=command,scope=UUID(),active=desiredActive && !suspended && !store.isClosed && !locked() && allowed(),network=desiredNetwork
        generation=scope;changing=true;error=nil
        command=Task {[weak self] in
            await previous?.value
            guard let self,!self.retired,self.generation==scope else {return}
            defer {if self.generation==scope {self.command=nil;self.changing=false}}
            do {
                // Pausing processing first avoids restarting provider work while
                // onboarding/sleep suspension is taking ownership of the worker.
                if !active {try await session.setProcessingEnabled(false)}
                try await session.setNetworkEnabled(network)
                if active {
                    guard !self.retired,self.generation==scope,!self.locked(),self.allowed(),!self.store.isClosed else {return}
                    try await session.setProcessingEnabled(true)
                }
                guard !self.retired,self.generation==scope else {return}
                self.networkPaused = !network
            }catch {
                guard !self.retired,self.generation==scope else {return}
                self.error="Sync could not change state. Stop and reopen the connection before retrying."
            }
        }
    }
    /// No async gap exists between denying admission and requesting core stop.
    func retire() {
        guard !retired else {return}
        retired=true;desiredActive=false;generation=UUID();changing=false;status=nil;error=nil
        preparation?.cancel();pairingTask?.cancel();command?.cancel();observer?.cancel();stopping=busy
        pairingStatus=nil;pairingReview=nil;pairingResponse=nil;pairingError=nil
        if let session {stopTask=Task {do {try await session.stop();return true}catch{return false}}}
    }
    /// A cancelled drain caller still waits for the actual core worker and all
    /// earlier configuration/observation work. No task may outlive its store.
    func cancelAndWait()async {
        retire()
        drains+=1;defer {drains-=1}
        let setup=preparation,paired=pairingTask,stopped=stopTask,configured=command,observed=observer
        await paired?.value
        pairing?.close();pairing=nil;pairingTask=nil;pairingBusy=false
        let setupClean=await setup?.value
        let clean=await stopped?.value
        await configured?.value;await observed?.value
        preparation=nil;preparing=false;stopTask=nil;command=nil;observer=nil;session=nil;stopping=false
        if clean==false || setupClean==false {error="The sync worker stopped, but its connection needs to be reopened."}
    }
}
