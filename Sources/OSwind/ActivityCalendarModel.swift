import AppKit
import OSwindCore

@MainActor final class ActivityCalendarModel:ObservableObject {
    typealias Loader = @Sendable (ActivityCalendarRequest) async throws -> ActivityCalendarSnapshot
    typealias Revision = @Sendable () async throws -> ActivityCalendarRevision
    @Published var month:String {didSet {if month != oldValue {selectedDay=nil;reload()}}}
    @Published var selectedDay:String? {didSet {if selectedDay != oldValue {reload()}}}
    @Published var app:String? {didSet {if app != oldValue {reload()}}}
    @Published var kind:MemoryKind? {didSet {if kind != oldValue {reload()}}}
    @Published var favoritesOnly=false {didSet {if favoritesOnly != oldValue {reload()}}}
    @Published private(set) var timeZone:TimeZone
    @Published private(set) var snapshot:ActivityCalendarSnapshot?
    @Published private(set) var busy=false
    @Published private(set) var error:String?
    private let load:Loader,revision:Revision
    private var firstWeekday:Int
    private var generation=UUID()
    private var job:Task<Void,Never>?,monitor:Task<Void,Never>?
    private var lastRevision:ActivityCalendarRevision?,lastRequest:ActivityCalendarRequest?
    private var active=false,pending=false
    private var loadedAt:ContinuousClock.Instant?
    init(store:MemoryStore,timeZone:TimeZone = .current,now:Date=Date()) {
        self.timeZone=timeZone;month=ActivityCalendarRequest.monthKey(now,timeZone:timeZone);firstWeekday=Calendar.current.firstWeekday
        load={request in try await Integration.activity(request,store:store)}
        revision={
            let worker=Task.detached(priority:.utility) {try store.activityCalendarRevision()}
            return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
        }
    }
    init(month:String,timeZone:TimeZone,firstWeekday:Int=1,load:@escaping Loader,revision:@escaping Revision) {self.month=month;self.timeZone=timeZone;self.firstWeekday=firstWeekday;self.load=load;self.revision=revision}
    var request:ActivityCalendarRequest {.init(month:month,timeZone:timeZone,firstWeekday:firstWeekday,selectedDay:selectedDay,filter:SearchFilter(app:app,kind:kind,favoritesOnly:favoritesOnly))}
    func activate() {
        guard !active else {return};active=true;invalidate()
        monitor=Task {[weak self] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(ProcessInfo.processInfo.isLowPowerModeEnabled ? 10:3))}catch {return}
                guard let self,self.active else {return}
                if NSApp?.isActive == true,!SessionState.locked {await self.checkForChanges()}
            }
        }
    }
    func deactivate(clear:Bool=false) {active=false;monitor?.cancel();monitor=nil;job?.cancel();job=nil;generation=UUID();busy=false;pending=false;if clear {snapshot=nil;lastRequest=nil;lastRevision=nil;error=nil}}
    func resumeAndInvalidate() {if active {invalidate()}else {activate()}}
    func forgetCounts() {job?.cancel();job=nil;generation=UUID();busy=false;pending=false;snapshot=nil;lastRequest=nil;lastRevision=nil;error=nil}
    func invalidate() {
        lastRevision=nil
        if busy {pending=true;return}
        // Capture can arrive twice per second. The visible calendar polls its
        // dirty revision at a human cadence; control changes bypass this gate.
        if active,snapshot != nil,let loadedAt,loadedAt.duration(to:.now) < .seconds(3) {return}
        reload()
    }
    func checkForChanges() async {
        guard !busy else {return};let token=generation,current=request
        do {let value=try await revision();guard generation==token,!Task.isCancelled,request==current else {return};if value != lastRevision || current != lastRequest {reload()}}
        catch {guard generation==token,!Task.isCancelled else {return};self.snapshot=nil;self.lastRevision=nil;self.error=error.localizedDescription}
    }
    func reload() {
        generation=UUID();let token=generation,input=request,load=self.load,revision=self.revision
        job?.cancel();pending=false;busy=true;error=nil
        if let old=lastRequest,old.month != input.month || old.timeZone != input.timeZone || old.filter != input.filter || old.firstWeekday != input.firstWeekday {snapshot=nil}
        job=Task {[weak self] in
            do {
                try await Task.sleep(for:.milliseconds(80));let before=try await revision(),value=try await load(input)
                guard let self,self.generation==token,!Task.isCancelled else {return}
                self.loadedAt = .now;self.snapshot=value;self.lastRequest=input;self.lastRevision=before;self.busy=false;self.job=nil
                if self.pending {self.pending=false;self.reload()}
            }catch {
                guard let self,self.generation==token,!Task.isCancelled else {return};self.busy=false;self.job=nil;self.snapshot=nil;self.lastRevision=nil;self.error=error.localizedDescription
                if self.pending {self.pending=false;self.reload()}
            }
        }
    }
    func moveMonth(_ amount:Int) {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        guard month.count==7,let year=Int(month.prefix(4)),let number=Int(month.suffix(2)),let anchor=calendar.date(from:DateComponents(year:year,month:number,day:15,hour:12)),let next=calendar.date(byAdding:.month,value:amount,to:anchor),(1...9998).contains(calendar.component(.year,from:next)) else {return}
        month=ActivityCalendarRequest.monthKey(next,timeZone:timeZone)
    }
    func thisMonth(now:Date=Date()) {let value=ActivityCalendarRequest.monthKey(now,timeZone:timeZone);if month==value {reload()}else {month=value}}
    func updateTimeZone(_ zone:TimeZone) {guard zone != timeZone else {return};timeZone=zone;reload()}
    deinit {job?.cancel();monitor?.cancel()}
}
