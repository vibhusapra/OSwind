import SwiftUI
import OSwindCore

@MainActor final class LibraryWipeModel:ObservableObject {
    typealias Operation = @MainActor (@escaping @Sendable (LibraryBackupProgress)->Void)async throws->LibraryWipeResult
    @Published private(set) var busy=false
    @Published var pendingCleanup=false
    @Published private(set) var progress:LibraryBackupProgress?
    @Published private(set) var result:LibraryWipeResult?
    @Published private(set) var status=""
    @Published private(set) var error:String?
    private var task:Task<Void,Never>?
    private var cancelWorker:(()->Void)?
    func cancel() {cancelWorker?();task?.cancel()}
    func cancelAndWait()async {cancel();let pending=task;await pending?.value}
    func run(store:MemoryStore,retry:Bool,before:@escaping () async->Void={},operation:Operation?=nil,ownedSync:Bool=false,completion:@escaping (LibraryWipeResult)->Void,onFailure:@escaping ()->Void={}) {
        guard !busy else {return};busy=true;result=nil;error=nil;status=retry ? "Retrying unfinished cleanup…":"Deleting local history…";progress = .init(phase:"Preparing")
        let relay=LibraryProgressRelay()
        task=Task {
            let observer=Task {while !Task.isCancelled {do {try await Task.sleep(nanoseconds:100_000_000)} catch {break};self.progress=relay.get()}}
            defer {observer.cancel();busy=false;progress=nil;task=nil;cancelWorker=nil}
            do {
                await before();try Task.checkCancellation()
                let worker:Task<LibraryWipeResult,Error>
                if let operation {worker=Task {try await operation({relay.set($0)})}}
                else {worker=Task.detached(priority:.utility) {try retry ? store.retryLibraryWipeCleanup(progress:{relay.set($0)}):store.wipeLibrary(progress:{relay.set($0)})}}
                cancelWorker={worker.cancel()}
                let value=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()});result=value;pendingCleanup = !value.cleanupComplete
                status=retry ? "Cleanup retry checked the earlier pending files.":"Deleted \(value.erasure.sources) sources, \(value.conversations) conversations and \(value.routines) routines."
                if value.cancelled {status+=" Cleanup stopped after the deletion committed."}
                completion(value)
            } catch is CancellationError {status=ownedSync ? "Erasure stopped. Reopen the library to check whether cleanup needs to finish.":retry ? "Retry stopped before cleanup began.":"Cancelled before history deletion committed. Existing history remains.";onFailure()}
            catch {self.error=ownedSync ? "Erasure could not finish. Reopen this library to check its saved cleanup and recovery options.":error.localizedDescription;status=ownedSync ? "Erasure needs attention.":retry ? "Retry did not begin. Existing cleanup state remains.":"History was not deleted by this attempt.";onFailure()}
        }
    }
}
struct LibraryWipeStatusView:View {
    @ObservedObject var model:LibraryWipeModel
    var retry:()->Void
    var body:some View {
        if model.busy || model.pendingCleanup || !model.status.isEmpty {
            VStack(alignment:.leading,spacing:10) {
                Label("Library erasure",systemImage:"trash").font(.headline)
                if model.busy {HStack {ProgressView().controlSize(.small);Text(model.progress?.phase ?? "Working…");Spacer();Button("Stop cleanup") {model.cancel()}}}
                if !model.status.isEmpty {Text(model.status).textSelection(.enabled)}
                if let result=model.result {
                    Text("\(result.erasure.removedMedia) files removed · \(result.erasure.pendingMedia) pending · compaction \(result.compacted ? "complete":"pending")").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.erasure.warnings,id:\.self) {Text($0).font(.caption).foregroundStyle(.secondary)}
                }
                if let error=model.error {Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
                if model.pendingCleanup,!model.busy {Text("History deletion has unfinished file or database cleanup. Retrying preserves new recordings.").font(.caption);Button("Retry library cleanup",action:retry)}
                Text("Stopping does not undo committed deletion. External exports and backups are independent copies.").font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
        }
    }
}
