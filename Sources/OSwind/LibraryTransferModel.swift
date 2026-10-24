import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OSwindCore

final class LibraryProgressRelay: @unchecked Sendable {
    private let lock = NSLock(); private var value: LibraryBackupProgress?
    func set(_ value: LibraryBackupProgress) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> LibraryBackupProgress? { lock.lock(); defer { lock.unlock() }; return value }
}
@MainActor final class LibraryTransferModel: ObservableObject {
    @Published var busy = false
    @Published var markdownOperation = false
    @Published var progress: LibraryBackupProgress?
    @Published var status = ""
    @Published var error: String?
    @Published var inspected: LibraryBackupInfo?
    @Published var archive: URL?
    @Published var restored: URL?
    @Published var markdownFolder: URL?
    private var task: Task<Void,Never>?
    private var cancelWorker: (() -> Void)?
    func chooseBackup(store: MemoryStore) {
        guard !busy else { return }
        markdownOperation = false
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
        guard !busy else { return }; markdownOperation = false; inspected = nil; archive = nil; restored = nil
        run({ relay in try LibraryBackup.inspect(url,progress:relay.set) }) { info in self.archive = url; self.inspected = info; self.status = "Backup verified. Choose a location for a restored copy." }
    }
    func chooseRestoreLocation() {
        guard !busy,let archive,let inspected else { return }; markdownOperation = false
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Restore here"; panel.message = "A new library folder will be created here. Your current library stays intact."
        guard panel.runModal() == .OK,let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("OSwind Restored "+Date().formatted(.iso8601.year().month().day())+"-"+UUID().uuidString.prefix(6))
        run({ relay in try LibraryBackup.restore(archive,to:destination,expectedFingerprint:inspected.archiveFingerprint,progress:relay.set) }) { _ in self.restored = destination; self.status = "Restored copy verified. Recording, API access and automatic cleanup are off." }
    }
    func chooseMarkdown(store: MemoryStore, policy: PrivacyPolicy, includeMedia: Bool) {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind Markdown "+Date().formatted(.iso8601.year().month().day()); panel.canCreateDirectories = true
        panel.message = "A new folder will contain your sources, conversations and an index. Existing folders are never replaced."
        guard panel.runModal() == .OK,let url = panel.url else { return }
        exportMarkdown(store:store,destination:url,policy:policy,includeMedia:includeMedia)
    }
    func exportMarkdown(store: MemoryStore, destination: URL, policy: PrivacyPolicy, includeMedia: Bool) {
        guard !busy else { return }; markdownOperation = true; markdownFolder = nil
        run({ relay in try MarkdownExport.create(store:store,destination:destination,policy:policy,includeMedia:includeMedia,progress:relay.set) }) { info in
            self.markdownFolder = destination; self.status = "Markdown saved: \(info.memories) sources, \(info.turns) conversation turns. Privacy omitted \(info.excludedMemories) sources and \(info.excludedTurns) dependent turns."
        }
    }
    func cancel() { cancelWorker?(); task?.cancel() }
    private func run<T: Sendable>(_ operation: @escaping @Sendable (LibraryProgressRelay) throws -> T, completion: @escaping (T) -> Void) {
        busy = true; error = nil; status = ""; progress = LibraryBackupProgress(phase:"Preparing"); let relay = LibraryProgressRelay()
        let worker = Task.detached(priority:.utility) { try operation(relay) }; self.cancelWorker = { worker.cancel() }
        task = Task {
            let observer = Task { while !Task.isCancelled { do { try await Task.sleep(nanoseconds:100_000_000) } catch { break }; self.progress = relay.get() ?? self.progress } }
            defer { observer.cancel(); self.cancelWorker = nil; self.task = nil; self.busy = false; self.progress = nil }
            do { let info = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }; completion(info) }
            catch is CancellationError { status = "Cancelled. Unfinished temporary data was removed." }
            catch {
                if worker.isCancelled || Task.isCancelled { status = "Cancelled. Unfinished temporary data was removed." }
                else { self.error = error.localizedDescription; status = "Operation did not complete." }
            }
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
            if !transfer.markdownOperation { LibraryTransferStatusView(transfer:transfer) }
            if let info = transfer.inspected {
                VStack(alignment:.leading,spacing:6) {
                    Text("\(info.memories) memories · \(info.conversations) conversations · \(info.mediaFiles) media files").font(.callout.weight(.medium))
                    if let discarded=info.discardedVisualIndexes,discarded>0 {Text("\(discarded) changed or unsupported visual indexes need rebuilding. Original history was restored.").font(.caption).foregroundStyle(.secondary)}
                    Text("Created \(info.createdAt) · \(ByteCountFormatter.string(fromByteCount:info.payloadBytes,countStyle:.file))").font(.caption).foregroundStyle(.secondary)
                    Button("Restore a new library…") { transfer.chooseRestoreLocation() }.disabled(transfer.busy)
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.primary.opacity(0.04),in:RoundedRectangle(cornerRadius:8))
            }
            if let restored = transfer.restored {
                HStack { Button("Open restored library") { NotificationCenter.default.post(name:.oswindOpenLibrary,object:restored) }; Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([restored]) } }.disabled(transfer.busy)
            }
        }
    }
}

struct LibraryTransferStatusView: View {
    @ObservedObject var transfer: LibraryTransferModel
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if transfer.busy {
                if let progress = transfer.progress {
                    Text(progress.phase).font(.callout)
                    if progress.totalItems>0 { ProgressView(value:min(1,Double(progress.completedItems)/Double(progress.totalItems))) } else { ProgressView().controlSize(.small) }
                    HStack { if progress.totalItems>0 { Text("\(progress.completedItems) / \(progress.totalItems) \(progress.unit)").font(.caption) }; if progress.copiedBytes>0 { Text(ByteCountFormatter.string(fromByteCount:progress.copiedBytes,countStyle:.file)).font(.caption) }; Spacer(); Button("Cancel") { transfer.cancel() } }
                }
            }
            if !transfer.status.isEmpty { Text(transfer.status).font(.caption) }
            if let error = transfer.error { Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let folder = transfer.markdownFolder { Button("Show Markdown folder") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }.disabled(transfer.busy) }
        }
    }
}

/// Observe the nested transfer model here, so a background completion and its
/// busy/cancel state invalidate these controls independently of AppModel.
struct MarkdownLibraryTransferView: View {
    @ObservedObject var transfer: LibraryTransferModel
    let store: MemoryStore
    let policy: PrivacyPolicy
    @State private var includeMedia = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Toggle("Include retained screenshots, replay and audio",isOn:$includeMedia).disabled(transfer.busy)
            Button("Export Markdown library…") { transfer.chooseMarkdown(store:store,policy:policy,includeMedia:includeMedia) }.disabled(transfer.busy)
            Text("A portable folder with an index, every allowed source, timed transcripts and source-linked conversations. Current exclusions and redaction apply; dependent conversation turns are omitted. Captured text stays literal. Exports are independent snapshots and are not encrypted.").font(.caption).foregroundStyle(.secondary)
            if transfer.markdownOperation { LibraryTransferStatusView(transfer:transfer) }
        }
    }
}

struct LibrarySelectionButton: View {
    @ObservedObject var transfer: LibraryTransferModel
    var body: some View {
        Button("Choose another library…") { NotificationCenter.default.post(name:.oswindChooseLibrary,object:nil) }.disabled(transfer.busy)
    }
}
