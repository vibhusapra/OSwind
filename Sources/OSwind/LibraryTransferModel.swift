import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSwindCore

private final class LibraryProgressRelay: @unchecked Sendable {
    private let lock = NSLock(); private var value: LibraryBackupProgress?
    func set(_ value: LibraryBackupProgress) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> LibraryBackupProgress? { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor final class LibraryTransferModel: ObservableObject {
    @Published var busy = false
    @Published var progress: LibraryBackupProgress?
    @Published var status = ""
    @Published var error: String?
    @Published var inspected: LibraryBackupInfo?
    @Published var archive: URL?
    @Published var restored: URL?
    private var task: Task<Void,Never>?
    private var worker: Task<LibraryBackupInfo,Error>?
    func chooseBackup(store: MemoryStore) {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-"+Date().formatted(.iso8601.year().month().day())+".oswindbackup"; panel.allowedContentTypes = [UTType(exportedAs:"com.oswind.backup",conformingTo:.package)]; panel.canCreateDirectories = true; panel.message = "Choose a new name. Existing backups are never replaced."
        guard panel.runModal() == .OK,let url = panel.url else { return }
        run({ relay in try LibraryBackup.create(store:store,destination:url,progress:relay.set) }) { info in self.archive = url; self.inspected = info; self.status = "Backup verified and saved." }
    }
    func chooseArchive() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false; panel.prompt = "Inspect backup"
        guard panel.runModal() == .OK,let url = panel.url else { return }; inspect(url)
    }
    func inspect(_ url: URL) {
        guard !busy else { return }; inspected = nil; archive = nil; restored = nil
        run({ relay in try LibraryBackup.inspect(url,progress:relay.set) }) { info in self.archive = url; self.inspected = info; self.status = "Backup verified. Choose a location for a restored copy." }
    }
    func chooseRestoreLocation() {
        guard !busy,let archive,let inspected else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Restore here"; panel.message = "A new library folder will be created here. Your current library stays intact."
        guard panel.runModal() == .OK,let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("OSwind Restored "+Date().formatted(.iso8601.year().month().day())+"-"+UUID().uuidString.prefix(6))
        run({ relay in try LibraryBackup.restore(archive,to:destination,expectedFingerprint:inspected.archiveFingerprint,progress:relay.set) }) { _ in self.restored = destination; self.status = "Restored copy verified. Recording, API access and automatic cleanup are off." }
    }
    func cancel() { worker?.cancel(); task?.cancel() }
    private func run(_ operation: @escaping @Sendable (LibraryProgressRelay) throws -> LibraryBackupInfo, completion: @escaping (LibraryBackupInfo) -> Void) {
        busy = true; error = nil; progress = LibraryBackupProgress(phase:"Preparing"); let relay = LibraryProgressRelay()
        let worker = Task.detached(priority:.utility) { try operation(relay) }; self.worker = worker
        task = Task {
            let observer = Task { while !Task.isCancelled { do { try await Task.sleep(nanoseconds:100_000_000) } catch { break }; self.progress = relay.get() ?? self.progress } }
            defer { observer.cancel(); self.worker = nil; self.task = nil; self.busy = false; self.progress = nil }
            do { let info = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }; completion(info) }
            catch is CancellationError { status = "Cancelled. Unfinished temporary data was removed." }
            catch { self.error = error.localizedDescription; status = "Operation did not complete." }
        }
    }
}
struct LibraryTransferView: View {
    @ObservedObject var transfer: LibraryTransferModel
    var store: MemoryStore?
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { if let store { Button("Create full backup…") { transfer.chooseBackup(store:store) } }; Button("Inspect or restore backup…") { transfer.chooseArchive() } }.disabled(transfer.busy)
            Text("Includes source records, conversations, search vectors and retained media. Keychain secrets, API tokens and downloaded model files are excluded. Backups are not encrypted.").font(.caption).foregroundStyle(.secondary)
            if transfer.busy {
                if let progress = transfer.progress {
                    Text(progress.phase).font(.callout)
                    if progress.totalItems>0 { ProgressView(value:min(1,Double(progress.completedItems)/Double(progress.totalItems))) } else { ProgressView().controlSize(.small) }
                    HStack { if progress.unit=="files",progress.totalItems>0 { Text("\(progress.completedItems) / \(progress.totalItems) files").font(.caption) }; if progress.copiedBytes>0 { Text(ByteCountFormatter.string(fromByteCount:progress.copiedBytes,countStyle:.file)).font(.caption) }; Spacer(); Button("Cancel") { transfer.cancel() } }
                }
            }
            if let info = transfer.inspected {
                VStack(alignment:.leading,spacing:6) {
                    Text("\(info.memories) memories · \(info.conversations) conversations · \(info.mediaFiles) media files").font(.callout.weight(.medium))
                    Text("Created \(info.createdAt) · \(ByteCountFormatter.string(fromByteCount:info.payloadBytes,countStyle:.file))").font(.caption).foregroundStyle(.secondary)
                    Button("Restore a new library…") { transfer.chooseRestoreLocation() }.disabled(transfer.busy)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
            }
            if !transfer.status.isEmpty { Text(transfer.status).font(.caption) }
            if let error = transfer.error { Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let restored = transfer.restored {
                HStack { Button("Open restored library") { NotificationCenter.default.post(name:.oswindOpenLibrary,object:restored) }; Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([restored]) } }.disabled(transfer.busy)
            }
        }
    }
}
