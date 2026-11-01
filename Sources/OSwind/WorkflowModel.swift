import Foundation
import Combine
import OSwindCore

struct WorkflowEditorFrame:Sendable {
    var source:WorkflowSourceBinding
    var title:String
    var app:String
    var timestamp:Date
    var png:Data
    var choices:[WorkflowFrameChoice]
    init(_ value:WorkflowFramePreview) {source=value.source;title=value.title;app=value.app;timestamp=value.timestamp;png=value.png;choices=value.frames}
    init(source:WorkflowSourceBinding,title:String,app:String,timestamp:Date,png:Data,choices:[WorkflowFrameChoice]=[]) {self.source=source;self.title=title;self.app=app;self.timestamp=timestamp;self.png=png;self.choices=choices}
}
struct WorkflowEditorStep:Identifiable {
    var step:WorkflowStep
    var frame:WorkflowEditorFrame
    var id:UUID {step.id}
}
@MainActor struct WorkflowEnvironment {
    var preview:(String,Int) async throws->WorkflowEditorFrame
    var export:(WorkflowDraft,URL,WorkflowExportOptions,WorkflowExportPermit,@escaping @Sendable (WorkflowExportProgress) async throws->Void) async throws->WorkflowExportInfo
    var locked:()->Bool = {SessionState.locked}
    static func live(store:MemoryStore)->Self {
        .init(preview:{id,ordinal in WorkflowEditorFrame(try await NarratedWorkflow.preview(store:store,memoryID:id,frameOrdinal:ordinal))},export:{draft,url,options,permit,progress in
            try await NarratedWorkflow.export(store:store,draft:draft,destination:url,options:options,permit:permit,progress:progress)
        })
    }
}

/// A single actual worker owns preview/render work. Revocation is immediate;
/// its busy state remains until even a noncooperative worker has returned.
@MainActor final class WorkflowModel:ObservableObject {
    @Published var title="A workflow worth keeping"
    @Published private(set) var steps=[WorkflowEditorStep]()
    @Published private(set) var busy=false
    @Published private(set) var exporting=false
    @Published private(set) var status="Add retained screens from Memories to build a walkthrough."
    @Published private(set) var completedURL:URL?
    @Published private(set) var completedDuration:Double?
    @Published var helperPath=WorkflowExportOptions().narrationHelper.path
    private let store:MemoryStore,environment:WorkflowEnvironment
    private var settings:AppSettings,generation=UUID(),worker:Task<Void,Never>?,permit:WorkflowExportPermit?
    var allowed:()->Bool = {false}
    var canEdit:Bool {!busy && allowed() && !environment.locked() && !store.isClosed}
    var helperReady:Bool {helperPath.hasPrefix("/") && FileManager.default.isExecutableFile(atPath:helperPath)}
    var draft:WorkflowDraft {.init(title:title,steps:steps.map(\.step))}
    var canExport:Bool {canEdit && helperReady && (try? draft.validated()) != nil}
    init(store:MemoryStore,settings:AppSettings,environment:WorkflowEnvironment) {self.store=store;self.settings=settings;self.environment=environment}
    func apply(_ value:AppSettings) {
        let changed=settings.privacy != value.privacy || settings.piiImports != value.piiImports;settings=value
        if changed {cancel(clear:true)}
    }
    private func current(_ token:UUID)throws {
        try Task.checkCancellation()
        guard generation==token,allowed(),!environment.locked(),!store.isClosed else {throw CancellationError()}
        try store.validateDirectoryIdentity()
    }
    func add(memoryID:String,frameOrdinal:Int=0) {load(memoryID:memoryID,ordinal:frameOrdinal,replacing:nil)}
    func selectFrame(stepID:UUID,ordinal:Int) {
        guard let item=steps.first(where:{$0.id==stepID}) else {return}
        load(memoryID:item.step.source.memoryID,ordinal:ordinal,replacing:stepID)
    }
    private func load(memoryID:String,ordinal:Int,replacing:UUID?) {
        guard canEdit,replacing != nil || steps.count<WorkflowDraft.maximumSteps else {return}
        let token=UUID();generation=token;busy=true;status="Inspecting retained source…"
        worker=Task {[weak self] in
            guard let self else {return};defer {busy=false;worker=nil;if generation != token {status="Workflow work cancelled."}}
            do {
                try current(token);let frame=try await environment.preview(memoryID,ordinal);try current(token)
                if let replacing,let index=steps.firstIndex(where:{$0.id==replacing}) {steps[index].frame=frame;steps[index].step.source=frame.source}
                else {steps.append(.init(step:.init(source:frame.source,title:frame.title.isEmpty ? "Step \(steps.count+1)":frame.title,narration:""),frame:frame))}
                completedURL=nil;completedDuration=nil;status="Edit each step’s narration, then export when you’re ready."
            }catch is CancellationError {if generation==token {status="Workflow work cancelled."}}
            catch {if generation==token {status=error.localizedDescription}}
        }
    }
    func edit(_ id:UUID,title:String?=nil,narration:String?=nil) {
        guard canEdit,let index=steps.firstIndex(where:{$0.id==id}) else {return}
        if let title {steps[index].step.title=title};if let narration {steps[index].step.narration=narration}
    }
    func move(_ id:UUID,by offset:Int) {
        guard canEdit,let index=steps.firstIndex(where:{$0.id==id}),steps.indices.contains(index+offset) else {return};steps.swapAt(index,index+offset)
    }
    func remove(_ id:UUID) {guard canEdit else {return};steps.removeAll {$0.id==id}}
    func reset() {guard canEdit else {return};steps=[];title="A workflow worth keeping";completedURL=nil;completedDuration=nil;status="Add retained screens from Memories to build a walkthrough."}
    func export(to destination:URL) {
        guard canExport else {status="Add narration for every step and choose an installed local Kokoro helper.";return}
        let token=UUID(),snapshot=draft,options=WorkflowExportOptions(narrationHelper:URL(fileURLWithPath:helperPath)),admission=WorkflowExportPermit()
        generation=token;permit=admission;busy=true;exporting=true;completedURL=nil;completedDuration=nil;status="Preparing workflow…"
        worker=Task {[weak self] in
            guard let self else {return}
            defer {busy=false;exporting=false;worker=nil;permit=nil}
            do {
                try current(token)
                let result=try await environment.export(snapshot,destination,options,admission) {[weak self] progress in
                    try await self?.receive(progress,token:token)
                }
                // Core has crossed its atomic publication boundary. A late
                // cancellation cannot turn an existing export into no output.
                completedURL=destination;completedDuration=result.duration
                status="Exported \(result.steps) steps · \(String(format:"%.1f",result.duration)) seconds. This folder is an independent copy."
            }catch is CancellationError {status="Workflow export cancelled."}
            catch {status=error.localizedDescription}
        }
    }
    private func receive(_ value:WorkflowExportProgress,token:UUID)throws {
        try current(token)
        switch value.phase {
        case .preparing:status="Checking sources and privacy…"
        case .narrating:status="Local narration · step \(value.step) of \(value.totalSteps)"
        case .combining:status="Combining measured narration…"
        case .encoding:status="Encoding video on this Mac…"
        case .verifying:status="Verifying complete picture and audio…"
        case .copying:status="Preparing portable files…"
        case .publishing:status="Finishing export…"
        }
    }
    func cancel(clear:Bool=false) {
        generation=UUID();permit?.invalidate();worker?.cancel()
        if clear {steps=[];title="A workflow worth keeping";completedURL=nil;completedDuration=nil}
        if busy {status="Cancelling · waiting for local work…"}
    }
    func cancelAndWait() async {cancel(clear:true);let actual=worker;await actual?.value}
    deinit {permit?.invalidate();worker?.cancel()}
}
