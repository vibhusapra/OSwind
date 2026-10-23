import Foundation
import Dispatch
import Darwin
import OSwindCore

private final class NativeModelCLIProgress:@unchecked Sendable {
    private let lock=NSLock();private var phase="";private var last=Date.distantPast
    func update(_ value:NativeModelProgress) {
        lock.lock();defer{lock.unlock()};let now=Date()
        guard phase != value.phase || now.timeIntervalSince(last)>=0.2 else{return};phase=value.phase;last=now
        let bytes=ByteCountFormatter.string(fromByteCount:value.completedBytes,countStyle:.file)+" / "+ByteCountFormatter.string(fromByteCount:value.totalBytes,countStyle:.file)
        let file=value.file.map{" · "+$0} ?? ""
        FileHandle.standardError.write(Data((value.phase+" · "+bytes+file+"\n").utf8))
    }
}
private final class NativeModelCLIInterrupts:@unchecked Sendable {
    let lock=NSLock();var count:UInt=0
    func add(_ value:UInt)->UInt{lock.lock();defer{lock.unlock()};count += value;return count}
}
func runNativeModelCLI(_ kind:NativeModelKind,cache:URL?,verifyOnly:Bool) async throws -> NativeModelInstallation {
    let progress=NativeModelCLIProgress()
    let worker=Task.detached(priority:.utility) {
        if verifyOnly {return try await NativeModelInstaller.verify(kind,cache:cache,progress:{progress.update($0)})}
        return try await NativeModelInstaller.install(kind,cache:cache,progress:{progress.update($0)})
    }
    let source=DispatchSource.makeSignalSource(signal:SIGINT,queue:DispatchQueue(label:"OSwind.model.interrupt")),interrupts=NativeModelCLIInterrupts(),previous=signal(SIGINT,SIG_IGN)
    source.setEventHandler {
        if interrupts.add(source.data)>1 {_exit(130)}
        FileHandle.standardError.write(Data("Cancelling model setup; cleaning unfinished files. Press Ctrl-C again to exit immediately.\n".utf8));worker.cancel()
    }
    source.resume();defer{source.setEventHandler(handler:nil);source.cancel();signal(SIGINT,previous)}
    return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
}
