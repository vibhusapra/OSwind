import Foundation
import Combine
import OSwindCore

private final class NativeModelProgressRelay:@unchecked Sendable {
    private let lock=NSLock();private var value:NativeModelProgress?
    func set(_ value:NativeModelProgress){lock.lock();self.value=value;lock.unlock()}
    func get()->NativeModelProgress?{lock.lock();defer{lock.unlock()};return value}
}
@MainActor final class NativeModelSetupModel:ObservableObject {
    typealias Installer = @Sendable (NativeModelKind,URL?,Bool,@escaping @Sendable (NativeModelProgress)->Void) async throws -> NativeModelInstallation
    @Published private(set) var active:NativeModelKind?
    @Published private(set) var cancelling=false
    @Published private(set) var progress:NativeModelProgress?
    @Published private(set) var installed=[NativeModelKind:NativeModelInstallation]()
    @Published private(set) var status=[NativeModelKind:String]()
    @Published private(set) var errors=[NativeModelKind:String]()
    var busy:Bool { active != nil }
    private let installer:Installer
    private var task:Task<Void,Never>?
    private var worker:Task<NativeModelInstallation,Error>?
    init(installer:@escaping Installer={kind,cache,verify,progress in
        if verify {return try await NativeModelInstaller.verify(kind,cache:cache,progress:progress)}
        return try await NativeModelInstaller.install(kind,cache:cache,progress:progress)
    }) {self.installer=installer}
    func message(_ value:String,for kind:NativeModelKind){status[kind]=value}
    func start(_ kind:NativeModelKind,cache:URL?=nil,verifyOnly:Bool=false,completion:@escaping (NativeModelInstallation)->Void) {
        guard !busy else{return};active=kind;cancelling=false;progress=nil;errors[kind]=nil;status[kind]=verifyOnly ? "Verifying local files…":"Preparing model download…"
        let relay=NativeModelProgressRelay(),installer=installer
        let worker=Task.detached(priority:.utility){try await installer(kind,cache,verifyOnly,{relay.set($0)})};self.worker=worker
        task=Task {
            let observer=Task {while !Task.isCancelled {do{try await Task.sleep(nanoseconds:100_000_000)}catch{break};if !self.cancelling {self.progress=relay.get() ?? self.progress}}}
            defer {observer.cancel();self.worker=nil;self.task=nil;self.active=nil;self.cancelling=false;self.progress=nil}
            do {
                let result=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                try Task.checkCancellation()
                guard result.kind==kind else {throw OSwindError.invalid("Model installer returned an unexpected model")}
                installed[kind]=result;status[kind]=result.reused ? "Local model verified.":"Model downloaded and verified.";completion(result)
            }catch is CancellationError {status[kind]="Cancelled. Unfinished temporary files were removed."}
            catch {errors[kind]=error.localizedDescription;status[kind]="Model setup did not complete."}
        }
    }
    func cancel(){guard busy else{return};cancelling=true;if let active{status[active]="Cancelling…"};worker?.cancel();task?.cancel()}
}
