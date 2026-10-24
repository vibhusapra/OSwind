import Foundation
import Combine
import OSwindCore

@MainActor final class VisualModelSetupModel:ObservableObject {
    typealias Installer=@Sendable (@escaping @Sendable (NativeModelProgress)->Void) async throws -> VisualModelInstallation
    @Published private(set) var busy=false
    @Published private(set) var cancelling=false
    @Published private(set) var progress:NativeModelProgress?
    @Published private(set) var status=""
    @Published private(set) var error:String?
    private let installer:Installer
    private var task:Task<Void,Never>?
    private var worker:Task<VisualModelInstallation,Error>?
    init(installer:@escaping Installer={progress in try await VisualModelPreparation.prepare(progress:progress)}) {self.installer=installer}
    func start(completion:@escaping (VisualModelInstallation)->Void) {
        guard !busy else {return};busy=true;cancelling=false;error=nil;status="Preparing local visual models…";progress=nil
        let relay=NativeModelProgressRelay(),installer=installer
        let worker=Task.detached(priority:.utility) {try await installer {relay.set($0)}};self.worker=worker
        task=Task {
            let observer=Task {while !Task.isCancelled {do {try await Task.sleep(for:.milliseconds(100))}catch {break};if !self.cancelling {self.progress=relay.get() ?? self.progress}}}
            defer {observer.cancel();self.worker=nil;self.task=nil;self.busy=false;self.cancelling=false;self.progress=nil}
            do {
                let installed=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                try Task.checkCancellation();status=installed.reused ? "Local visual models verified.":"Local visual models prepared and verified.";completion(installed)
            } catch is CancellationError {status="Cancelled. Preparation processes stopped; verified public downloads stay cached."}
            catch {self.error=error.localizedDescription;status="Visual model setup did not finish."}
        }
    }
    func cancel() {guard busy else {return};cancelling=true;status="Stopping visual preparation…";worker?.cancel();task?.cancel()}
}
