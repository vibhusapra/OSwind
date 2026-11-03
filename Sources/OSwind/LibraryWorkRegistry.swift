import Foundation

/// Own the actual detached work together with its actor completion. A cancelled
/// drain caller still waits for both; no new job enters while draining.
@MainActor final class LibraryWorkRegistry {
    enum Kind:Hashable,CaseIterable,Sendable {case recordedMeetings,note,recap,statistics,storage,answer,audioImport,selectedPII,sourceOpening,historicalValidation,query,textRebuild,fastIndex,automaticText,visualRebuild,automaticVisual}
    private struct Job {
        let kind:Kind
        let cancel:@Sendable ()->Void
        let join:@Sendable ()async->Void
    }
    private var jobs=[UUID:Job]()
    private var drainers=0
    var busy:Bool {!jobs.isEmpty}
    var accepting:Bool {drainers==0}
    @discardableResult func launch<Value:Sendable>(kind:Kind,priority:TaskPriority = .utility,operation:@escaping @Sendable ()async throws->Value,completion:@escaping @MainActor (Result<Value,Error>,Bool)->Void)->UUID? {
        guard accepting else {return nil}
        let id=UUID(),worker=Task.detached(priority:priority,operation:operation)
        let finished=Task {
            defer {jobs[id]=nil}
            do {
                let value=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                completion(.success(value),Task.isCancelled)
            } catch {completion(.failure(error),Task.isCancelled)}
        }
        jobs[id]=Job(kind:kind,cancel:{worker.cancel();finished.cancel()},join:{_ = try? await worker.value;await finished.value})
        return id
    }
    /// Observe an individual job without releasing its registry ownership.
    /// Cancelling the observer forwards to actual work and still joins it.
    func wait(for id:UUID)async {
        guard let job=jobs[id] else {return}
        await withTaskCancellationHandler {await job.join()} onCancel:{job.cancel()}
    }
    func count(kinds:Set<Kind>)->Int {jobs.values.filter {kinds.contains($0.kind)}.count}
    func cancel(id:UUID) {jobs[id]?.cancel()}
    func cancel(kinds:Set<Kind>=Set(Kind.allCases)) {for job in jobs.values where kinds.contains(job.kind) {job.cancel()}}
    func cancelAndWait()async {
        drainers+=1;defer {drainers-=1}
        let owned=Array(jobs.values)
        for job in owned {job.cancel()}
        for job in owned {await job.join()}
    }
}
