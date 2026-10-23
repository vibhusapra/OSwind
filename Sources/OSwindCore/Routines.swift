import Foundation

public enum RoutineWindow:String,Codable,CaseIterable,Sendable {
    case today,yesterday,lastHour,last24Hours,last7Days
    public var title:String {switch self {case .today:return "Today so far";case .yesterday:return "Yesterday";case .lastHour:return "Last hour";case .last24Hours:return "Last 24 hours";case .last7Days:return "Last 7 days"}}
}
public enum RoutineCadence:String,Codable,CaseIterable,Sendable {case calendar,interval}
public struct RoutineSchedule:Codable,Equatable,Sendable {
    public var cadence:RoutineCadence = .calendar
    public var intervalMinutes=60
    public var hour=17,minute=0
    public var weekdays=[1,2,3,4,5,6,7]
    public var timeZone=TimeZone.current.identifier
    public init() {}
    enum CodingKeys:CodingKey {case cadence,intervalMinutes,hour,minute,weekdays,timeZone}
    public init(from decoder:Decoder) throws {
        self.init();let values=try decoder.container(keyedBy:CodingKeys.self)
        cadence=try values.decodeIfPresent(RoutineCadence.self,forKey:.cadence) ?? cadence
        intervalMinutes=try values.decodeIfPresent(Int.self,forKey:.intervalMinutes) ?? intervalMinutes
        hour=try values.decodeIfPresent(Int.self,forKey:.hour) ?? hour;minute=try values.decodeIfPresent(Int.self,forKey:.minute) ?? minute
        weekdays=try values.decodeIfPresent([Int].self,forKey:.weekdays) ?? weekdays;timeZone=try values.decodeIfPresent(String.self,forKey:.timeZone) ?? timeZone
    }
    public func validated() throws -> Self {
        guard (0...23).contains(hour),(0...59).contains(minute),(cadence == .interval || !weekdays.isEmpty),(1...10080).contains(intervalMinutes),Set(weekdays).count==weekdays.count,weekdays.allSatisfy({(1...7).contains($0)}),TimeZone(identifier:timeZone) != nil else {throw OSwindError.invalid("Choose a valid time, weekdays and time zone")}
        var copy=self;copy.weekdays.sort();return copy
    }
    public var calendar:Calendar {var value=Calendar(identifier:.gregorian);value.timeZone=TimeZone(identifier:timeZone) ?? .gmt;return value}
    private func occurrence(on day:Date) -> Date? {
        let c=calendar
        guard weekdays.contains(c.component(.weekday,from:day)),let value=c.date(bySettingHour:hour,minute:minute,second:0,of:day,matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward),c.isDate(value,inSameDayAs:day) else {return nil}
        return value
    }
    public func occurrence(relativeTo date:Date,next:Bool) throws -> Date {
        _ = try validated();try RoutineDefinition.validateDate(date)
        if cadence == .interval {let seconds=Double(intervalMinutes)*60,slot=floor(date.timeIntervalSince1970/seconds);return Date(timeIntervalSince1970:(slot+(next ? 1:0))*seconds)}
        let c=calendar,start=c.startOfDay(for:date)
        for offset in 0...14 {
            guard let day=c.date(byAdding:.day,value:next ? offset : -offset,to:start),let candidate=occurrence(on:day) else {continue}
            if next ? candidate>date : candidate<=date {return candidate}
        }
        throw OSwindError.invalid("No routine occurrence in the supported calendar range")
    }
}
public struct RoutineDefinition:Identifiable,Codable,Equatable,Sendable {
    public var id=UUID().uuidString
    public var title="Day recap"
    public var prompt="Summarize recorded work, decisions and action items. Cite evidence; mark missing details."
    public var enabled=true
    public var schedule=RoutineSchedule()
    public var window:RoutineWindow = .today
    public var app:String?=nil
    public var kind:MemoryKind?=nil
    public var tag:String?=nil
    public var ai=AIConfiguration()
    public var allowRemote=false
    public init() {}
    static func validateDate(_ date:Date) throws {guard date.timeIntervalSince1970.isFinite,(0...7_258_118_400).contains(date.timeIntervalSince1970) else {throw OSwindError.invalid("Invalid routine time")}}
    public func validated(policy:PrivacyPolicy=PrivacyPolicy()) throws -> Self {
        guard !id.isEmpty,id.utf8.count<=128,!id.utf8.contains(0),!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count<=160,!prompt.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,prompt.utf8.count<=8000,ai.model.utf8.count<=300,ai.endpoint.utf8.count<=2048 else {throw OSwindError.invalid("Invalid routine name, prompt or model")}
        for value in [app,tag].compactMap({$0}) {guard !value.isEmpty,value.utf8.count<=300,!value.utf8.contains(0) else {throw OSwindError.invalid("Invalid routine source scope")}}
        if ai.provider == .compatible || ai.provider == .anthropic || ai.provider == .ollama {
            var check=ai;check.allowRemote=true;_ = try check.validatedURL(path:"")
        }
        var copy=self;copy.schedule=try schedule.validated();copy.title=policy.sanitize(title).text;copy.prompt=policy.sanitize(prompt).text;copy.app=app.map{policy.sanitize($0).text};copy.tag=tag.map{policy.sanitize($0).text};return copy
    }
    public func filter(at slot:Date) throws -> SearchFilter {
        try Self.validateDate(slot);_ = try schedule.validated()
        let c=schedule.calendar,day=c.startOfDay(for:slot);let start:Date,end:Date
        switch window {
        case .today:start=day;end=slot
        case .yesterday:end=day;start=c.date(byAdding:.day,value:-1,to:day)!
        case .lastHour:start=slot.addingTimeInterval(-3600);end=slot
        case .last24Hours:start=slot.addingTimeInterval(-86400);end=slot
        case .last7Days:start=slot.addingTimeInterval(-7*86400);end=slot
        }
        return SearchFilter(app:app,kind:kind,start:start,end:end,tag:tag,limit:24)
    }
}
public struct StoredRoutine:Identifiable,Codable,Sendable {
    public var definition:RoutineDefinition
    public var revision:Int
    public var nextDue:Date
    public var id:String {definition.id}
}
public enum RoutineRunStatus:String,Codable,Sendable {case running,completed,failed,cancelled,interrupted,skipped}
public enum RoutineTrigger:String,Codable,Sendable {case scheduled,manual}
public struct RoutineRun:Identifiable,Codable,Sendable {
    public var id:String
    public var routineID:String
    public var revision:Int
    public var scheduledAt:Date
    public var started:Date
    public var finished:Date?
    public var trigger:RoutineTrigger
    public var status:RoutineRunStatus
    public var chatID:String?
    public var message:String?
    public var filter:SearchFilter
    public var resultAvailable:Bool=false
}
struct RoutineClaim:Sendable {var routine:StoredRoutine;var run:RoutineRun}

/// Runs only selected recorded evidence through the existing answer path. Each
/// claimed schedule slot is consumed once, including failures/interruption.
public final class RoutineRunner {
    private let store:MemoryStore
    private let generate:@Sendable (RoutineDefinition,SearchFilter,AppSettings,Date) async throws -> Answer
    public init(store:MemoryStore,embedder:LocalEmbedder) {
        self.store=store
        generate={ definition,filter,settings,slot in
            try await AnswerEngine(store:store,embedder:embedder).answer(definition.prompt,configuration:definition.ai,filter:filter,summarize:true,searchConfiguration:settings.search,interpretQuery:false,now:slot,timeZone:definition.schedule.calendar.timeZone)
        }
    }
    init(store:MemoryStore,generate:@escaping @Sendable (RoutineDefinition,SearchFilter,AppSettings,Date) async throws -> Answer) {self.store=store;self.generate=generate}
    public func runDue(settings:AppSettings,now:Date=Date()) async throws -> RoutineRun? {
        try Task.checkCancellation();guard settings.routinesEnabled else {return nil}
        guard let claim=try store.claimRoutine(now:now) else {return nil};return try await perform(claim,settings:settings)
    }
    public func runNow(_ id:String,settings:AppSettings,now:Date=Date()) async throws -> RoutineRun? {
        try Task.checkCancellation();guard let claim=try store.claimRoutine(id:id,now:now) else {return nil};return try await perform(claim,settings:settings)
    }
    private func perform(_ claim:RoutineClaim,settings:AppSettings) async throws -> RoutineRun? {
        guard claim.run.status == .running else {return claim.run}
        do {
            let definition=try claim.routine.definition.validated(policy:settings.privacy)
            let ai=definition.ai
            if ai.provider == .compatible || ai.provider == .anthropic {
                let host=URL(string:ai.endpoint)?.host?.lowercased() ?? ""
                if !["localhost","127.0.0.1","::1","[::1]"].contains(host),!(definition.allowRemote && settings.ai.allowRemote && ai.allowRemote) {
                    return try store.finishRoutine(claim.run.id,status:.failed,message:"Remote processing is disabled. Allow it for this routine and in Models settings to run.")
                }
            }
            try Task.checkCancellation()
            let answer=try await generate(definition,claim.run.filter,settings,claim.run.scheduledAt)
            try Task.checkCancellation()
            return try store.completeRoutine(claim,answer:answer,policy:settings.privacy)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                _ = try store.finishRoutine(claim.run.id,status:.cancelled,message:"Run cancelled; this occurrence will not retry automatically.")
                throw CancellationError()
            }
            return try store.finishRoutine(claim.run.id,status:.failed,message:"Run could not complete. Check model settings and remaining source evidence, then run manually.")
        }
    }
}
