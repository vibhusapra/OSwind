import Foundation
import Dispatch
import Darwin
import OSwindCore

final class BackupCLIProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = ""
    private var last = Date.distantPast
    func update(_ value: LibraryBackupProgress) {
        lock.lock(); defer { lock.unlock() }
        let now = Date(); guard phase != value.phase || now.timeIntervalSince(last)>=0.2 else { return }
        phase = value.phase; last = now
        let count = value.totalItems>0 ? " · \(value.completedItems)/\(value.totalItems) \(value.unit)" : value.completedItems>0 ? " · \(value.completedItems) \(value.unit)" : ""
        let bytes = value.copiedBytes>0 ? " · "+ByteCountFormatter.string(fromByteCount:value.copiedBytes,countStyle:.file) : ""
        FileHandle.standardError.write(Data((value.phase+count+bytes+"\n").utf8))
    }
}
func runBackupCLI<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority:.utility,operation:operation)
    let queue = DispatchQueue(label:"OSwind.backup.interrupt"), source = DispatchSource.makeSignalSource(signal:SIGINT,queue:queue)
    let previous = signal(SIGINT,SIG_IGN); let interrupts = BackupCLIInterrupts()
    source.setEventHandler {
        if interrupts.add(source.data)>1 { _exit(130) }
        FileHandle.standardError.write(Data("Cancelling; cleaning temporary data. Press Ctrl-C again to exit immediately.\n".utf8)); task.cancel()
    }
    source.resume()
    defer { source.setEventHandler(handler:nil); source.cancel(); signal(SIGINT,previous) }
    do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
    catch { if task.isCancelled { throw CancellationError() }; throw error }
}

private final class BackupCLIInterrupts: @unchecked Sendable {
    private let lock = NSLock(); private var value: UInt = 0
    func add(_ count: UInt) -> UInt { lock.lock(); defer { lock.unlock() }; value += count; return value }
}
