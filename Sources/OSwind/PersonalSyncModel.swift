import Foundation
import Combine
import OSwindCore

/// Own the actual core session, its serialized commands and the status consumer.
/// An app retirement closes admission synchronously, then joins all three before
/// SQLite close, vault unmount or wipe. No enrollment keys enter this model.
@MainActor final class PersonalSyncModel:ObservableObject {
    @Published private(set) var status:PersonalSyncStatus?
    @Published private(set) var networkPaused=false
    @Published private(set) var changing=false
    @Published private(set) var stopping=false
    @Published private(set) var error:String?
    var allowed:()->Bool={true}
    private let store:MemoryStore,locked:()->Bool
    private var session:PersonalSyncSession?
    private var observer:Task<Void,Never>?,command:Task<Void,Never>?,stopTask:Task<Bool,Never>?
    private var generation=UUID(),retired=false,desiredActive=false,desiredNetwork=true,suspended=false
    var configured:Bool {session != nil}
    var busy:Bool {session != nil || observer != nil || command != nil || stopTask != nil}
    init(store:MemoryStore,locked:@escaping ()->Bool={SessionState.locked}) {self.store=store;self.locked=locked}
    deinit {
        // Fallback cancellation prevents an idle subscription retaining a
        // session forever. Real storage departure still awaits cancelAndWait.
        observer?.cancel();command?.cancel()
        if let session {Task {try? await session.stop()}}
    }
    /// Called only with a session prepared by the enrollment owner. This cannot
    /// create peers, change group authority or bypass core policy/media checks.
    func attachPrepared(_ candidate:PersonalSyncSession)throws {
        guard !retired,!busy,!store.isClosed,!locked(),allowed(),candidate.belongs(to:store) else {throw OSwindError.unavailable("Sync requires its current open library")}
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
        guard retired,!busy else {return};retired=false;suspended=false;desiredActive=false;desiredNetwork=true;networkPaused=false;status=nil;error=nil
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
        command?.cancel();observer?.cancel();stopping=busy
        if let session {stopTask=Task {do {try await session.stop();return true}catch{return false}}}
    }
    /// A cancelled drain caller still waits for the actual core worker and all
    /// earlier configuration/observation work. No task may outlive its store.
    func cancelAndWait()async {
        retire()
        let stopped=stopTask,configured=command,observed=observer
        let clean=await stopped?.value
        await configured?.value;await observed?.value
        stopTask=nil;command=nil;observer=nil;session=nil;stopping=false
        if clean==false {error="The sync worker stopped, but its connection needs to be reopened."}
    }
}
