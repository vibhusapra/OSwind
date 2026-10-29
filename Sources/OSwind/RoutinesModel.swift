import Foundation
import Combine
import OSwindCore

@MainActor final class RoutinesModel:ObservableObject {
    @Published private(set) var items=[StoredRoutine]()
    @Published private(set) var history=[RoutineRun]()
    @Published private(set) var busy=false
    @Published private(set) var activeRoutineID:String?
    @Published var error:String?
    private let store:MemoryStore
    private var settings:AppSettings
    private let due:@Sendable (AppSettings,Date) async throws -> RoutineRun?
    private let manual:@Sendable (String,AppSettings,Date) async throws -> RoutineRun?
    private let now:() -> Date
    private let interval:Double
    private var timer:Timer?
    var schedulingActive:Bool {timer != nil}
    private var task:Task<Void,Never>?
    var onChange:(() -> Void)?
    init(store:MemoryStore,embedder:LocalEmbedder,settings:AppSettings) {
        self.store=store;self.settings=settings;now={Date()};interval=30
        let runner=RoutineRunner(store:store,embedder:embedder)
        due={try await runner.runDue(settings:$0,now:$1)};manual={try await runner.runNow($0,settings:$1,now:$2)}
        reload()
    }
    init(store:MemoryStore,settings:AppSettings,interval:Double=30,now:@escaping () -> Date={Date()},due:@escaping @Sendable (AppSettings,Date) async throws -> RoutineRun?,manual:@escaping @Sendable (String,AppSettings,Date) async throws -> RoutineRun?) {
        self.store=store;self.settings=settings;self.interval=interval;self.now=now;self.due=due;self.manual=manual;reload()
    }
    func apply(_ value:AppSettings) {
        if settings.routinesEnabled && !value.routinesEnabled || settings.privacy != value.privacy || settings.ai.allowRemote && !value.ai.allowRemote {task?.cancel()}
        let enabled = !settings.routinesEnabled && value.routinesEnabled;settings=value
        if enabled {tickIfStarted()}
    }
    func start() {
        guard timer==nil else {return}
        timer=Timer.scheduledTimer(withTimeInterval:interval,repeats:true) {[weak self] _ in Task {@MainActor in self?.tickIfStarted()}}
        timer?.tolerance=min(15,interval/2);tickIfStarted()
    }
    func stop() {timer?.invalidate();timer=nil;task?.cancel()}
    func clearForLock() {stop();items.removeAll();history.removeAll();onChange=nil}
    func tick() {guard settings.routinesEnabled else {return};execute(id:nil)}
    func tickIfStarted() {guard timer != nil else {return};tick()}
    func runNow(_ id:String) {execute(id:id)}
    func cancel() {task?.cancel()}
    private func execute(id:String?) {
        guard !busy else {return};busy=true;activeRoutineID=id;error=nil
        let config=settings,date=now(),due=self.due,manual=self.manual
        task=Task { [weak self] in
            do {
                let run:RoutineRun?
                if let id {run=try await manual(id,config,date)} else {run=try await due(config,date)}
                guard let self else {return}
                if let run {self.activeRoutineID=run.routineID;if run.status == .failed {self.error=run.message}}
                else if id != nil {self.error="Another routine is already running in this library."}
            } catch is CancellationError {} catch {self?.error="Routine could not run. Check the library and model settings."}
            guard let self else {return};self.busy=false;self.activeRoutineID=nil;self.task=nil;self.reload();self.onChange?()
        }
    }
    func reload() {do {items=try store.routines();history=try store.routineRuns()} catch {self.error="Could not load routines from this library."}}
    @discardableResult func save(_ value:RoutineDefinition,revision:Int?) -> Bool {
        do {_ = try store.saveRoutine(value,expectedRevision:revision,now:now(),policy:settings.privacy);let running=try store.routineRuns(value.id).contains(where:{$0.status == .running});if activeRoutineID==value.id || running {task?.cancel()};reload();error=nil;return true} catch {self.error=error.localizedDescription;return false}
    }
    func toggle(_ routine:StoredRoutine) {var d=routine.definition;d.enabled.toggle();_ = save(d,revision:routine.revision)}
    func delete(_ id:String) {do {let running=try store.routineRuns(id).contains(where:{$0.status == .running});if activeRoutineID==id || running {task?.cancel()};try store.deleteRoutine(id);reload();onChange?()} catch {self.error="Routine could not be deleted."}}
}
