import AppKit
import OSwindCore

@MainActor final class EntityMemoryModel:ObservableObject {
    @Published var kind:EntityKind?
    @Published var query=""
    @Published var selectedID:String? {didSet {if !clearing && oldValue != selectedID {selected=nil;sources=[];reload()}}}
    @Published private(set) var entities=[MemoryEntity]()
    @Published private(set) var sources=[EntitySource]()
    @Published private(set) var selected:MemoryEntity?
    @Published private(set) var progress=EntityIndexProgress(eligible:0,indexed:0,limited:0)
    @Published private(set) var indexing=false
    @Published private(set) var editing=false
    @Published private(set) var error:String?
    @Published private(set) var status="Build local suggestions when you’re ready."
    var visible=false
    private var pendingIDs=Set<String>()
    private var indexSlot:UUID?
    private let indexSource:@Sendable (String,EntityIndexPlan)throws->Bool
    private let canIndex:@Sendable ()->Bool
    private let store:MemoryStore
    private var readTask:Task<Void,Never>?,indexTask:Task<Void,Never>?,editTask:Task<Void,Never>?
    private var clearing=false
    private var generation=UUID(),readGeneration=UUID(),pending=false
    init(store:MemoryStore,indexSource:(@Sendable (String,EntityIndexPlan)throws->Bool)?=nil,canIndex:@escaping @Sendable ()->Bool = { !SessionState.locked && !ProcessInfo.processInfo.isLowPowerModeEnabled && ProcessInfo.processInfo.thermalState.rawValue<ProcessInfo.ThermalState.serious.rawValue }) {self.store=store;self.canIndex=canIndex;self.indexSource=indexSource ?? {try store.indexEntities($0,plan:$1)}}
    func reload() {
        readTask?.cancel();readGeneration=UUID();let token=readGeneration,scope=kind,query=self.query,id=selectedID,store=self.store
        readTask=Task {[weak self] in
            let worker=Task.detached(priority:.utility) {
                try Task.checkCancellation();let plan=try store.entityIndexPlan()
                return (try store.entities(kind:scope,query:query),try id.flatMap {try store.entity($0)},try id.map {try store.entitySources($0)} ?? [],try store.entityIndexProgress(processor:EntityExtractor.processor(plan)))
            }
            do {
                let value=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                guard let self,self.readGeneration==token,!Task.isCancelled else {return}
                self.entities=value.0;self.selected=value.1;self.sources=value.2;self.progress=value.3;self.readTask=nil
            }catch {guard let self,self.readGeneration==token,!Task.isCancelled else {return};self.error=error.localizedDescription;self.readTask=nil}
        }
    }
    func enqueue(_ memory:Memory) {
        guard memory.kind != .summary else {return}
        guard pendingIDs.count<256 || pendingIDs.contains(memory.id) else {status="Entity capture queue reached 256 sources. Build / resume to catch up.";return}
        pendingIDs.insert(memory.id)
        if !indexing {start(ids:Array(pendingIDs))}
    }
    func build() {if indexing {pending=true;return};start(ids:nil)}
    private func start(ids:[String]?) {
        guard !indexing else {return}
        guard canIndex() else {status="Local indexing deferred while locked, in Low Power Mode or under thermal pressure.";return}
        if let ids {pendingIDs.subtract(ids)}
        indexing=true;error=nil;status="Reading saved text locally…";let token=generation,slot=UUID(),store=self.store,canIndex=self.canIndex,indexSource=self.indexSource;indexSlot=slot
        indexTask=Task {[weak self] in
            defer {
                if let self,self.indexSlot==slot {
                    self.indexSlot=nil;self.indexing=false;self.indexTask=nil
                    if self.generation==token {
                        if self.visible || ids==nil {self.reload()}
                        if self.pending {self.pending=false;self.start(ids:nil)}
                        else if !self.pendingIDs.isEmpty {self.start(ids:Array(self.pendingIDs))}
                    }else if !self.pendingIDs.isEmpty {self.start(ids:Array(self.pendingIDs))}
                }
            }
            let report:@Sendable (Int) async->Void = { [weak self] count in await self?.recordProgress(count,token:token) }
            let worker=Task.detached(priority:.utility) {
                try Task.checkCancellation()
                let plan=try store.entityIndexPlan(),processor=EntityExtractor.processor(plan);var cursor="",count=0
                if let ids {
                    for id in ids {try Task.checkCancellation();guard canIndex() else {throw OSwindError.unavailable("Entity indexing deferred for lock, power or temperature. Build / resume to catch up.")};if try indexSource(id,plan) {count+=1;if count%64==0 {await report(count)}}}
                }else {
                    while true {
                        try Task.checkCancellation();guard canIndex() else {throw OSwindError.unavailable("Entity indexing deferred for lock, power or temperature. Build / resume to catch up.")}
                        let batch=try store.pendingEntitySourceIDs(processor:processor,after:cursor,limit:16)
                        if batch.isEmpty {break}
                        for id in batch {try Task.checkCancellation();guard canIndex() else {throw OSwindError.unavailable("Entity indexing deferred for lock, power or temperature. Build / resume to catch up.")};if try indexSource(id,plan) {count+=1;if count%64==0 {await report(count)}};cursor=id}
                    }
                }
                return count
            }
            do {
                let count=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
                guard let self,self.generation==token,!Task.isCancelled else {return}
                self.status="Updated \(count) sources. Suggested names need your review."
            }catch {
                guard let self,self.generation==token,!Task.isCancelled else {return}
                self.pending=false;self.pendingIDs.removeAll();self.status=error.localizedDescription
            }
        }
    }
    private func recordProgress(_ count:Int,token:UUID) {guard generation==token else {return};status="Indexed \(count) sources in this run…"}
    func mutate(_ action:@escaping @Sendable (MemoryStore)throws->Void) {
        guard !editing else {return};editing=true;error=nil;let token=generation,store=self.store
        editTask=Task {[weak self] in
            let worker=Task.detached(priority:.utility) {try Task.checkCancellation();try action(store)}
            do {try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}}
            catch {guard let self,self.generation==token,!Task.isCancelled else {return};self.error=error.localizedDescription}
            guard let self,self.generation==token,!Task.isCancelled else {return};self.editing=false;self.editTask=nil;self.reload()
        }
    }
    func cancel() {generation=UUID();indexTask?.cancel();editTask?.cancel();editTask=nil;editing=false;pending=false;pendingIDs.removeAll();status="Stopped. Completed source indexes can be resumed."}
    func clear() {clearing=true;defer {clearing=false};cancel();readGeneration=UUID();readTask?.cancel();readTask=nil;entities=[];sources=[];selected=nil;selectedID=nil;query="";error=nil;progress = .init(eligible:0,indexed:0,limited:0)}
    deinit {readTask?.cancel();indexTask?.cancel();editTask?.cancel()}
}
