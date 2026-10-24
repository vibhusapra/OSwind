import Foundation
import Dispatch
import Darwin

func runVaultCLI<T:Sendable>(_ operation:@escaping @Sendable () async throws -> T) async throws -> T {
    let source=DispatchSource.makeSignalSource(signal:SIGINT,queue:DispatchQueue(label:"OSwind.vault.interrupt")),previous=signal(SIGINT,SIG_IGN),interrupts=VaultCLIInterrupts()
    let worker=Task.detached(priority:.utility,operation:operation)
    source.setEventHandler {
        if interrupts.add(source.data)>1 {_exit(130)}
        FileHandle.standardError.write(Data("Stopping vault work safely; check vault status before retrying. Press Ctrl-C again to exit immediately.\n".utf8));worker.cancel()
    }
    source.resume();defer {source.setEventHandler(handler:nil);source.cancel();signal(SIGINT,previous)}
    do {return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}}
    catch {if worker.isCancelled {throw CancellationError()};throw error}
}
private final class VaultCLIInterrupts:@unchecked Sendable {
    private let lock=NSLock();private var count:UInt=0
    func add(_ value:UInt) -> UInt {lock.lock();defer {lock.unlock()};count+=value;return count}
}
