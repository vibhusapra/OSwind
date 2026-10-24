import Foundation
import CSQLite

public struct ActivityCalendarDay:Codable,Equatable,Sendable,Identifiable {
    public var key:String
    public var day:Int
    public var start:Date?
    public var end:Date?
    public var sources:Int=0
    public var id:String {key}
    public var available:Bool {start != nil && end != nil}
}
public struct ActivityCalendarHour:Codable,Equatable,Sendable,Identifiable {
    public var ordinal:Int
    public var start:Date
    public var end:Date
    public var hour:Int
    public var minute:Int
    public var utcOffsetSeconds:Int
    public var sources:Int=0
    public var id:Int {ordinal}
}
public struct ActivitySourceScope:Codable,Equatable,Sendable {
    public var app:String?
    public var kind:MemoryKind?
    public var favoritesOnly:Bool
    public var tag:String?
    public var speaker:String?
    public var start:Date?
    public var end:Date?
    public init(_ filter:SearchFilter) {app=filter.app;kind=filter.kind;favoritesOnly=filter.favoritesOnly;tag=filter.tag;speaker=filter.speaker;start=filter.start;end=filter.end}
    public var filter:SearchFilter {SearchFilter(app:app,kind:kind,start:start,end:end,favoritesOnly:favoritesOnly,tag:tag,speaker:speaker)}
}
public struct ActivityCalendarRequest:Equatable,Sendable {
    public var month:String
    public var timeZone:TimeZone
    public var firstWeekday:Int
    public var selectedDay:String?
    public var filter:SearchFilter
    public init(month:String,timeZone:TimeZone = .current,firstWeekday:Int=1,selectedDay:String?=nil,filter:SearchFilter=SearchFilter()) {self.month=month;self.timeZone=timeZone;self.firstWeekday=firstWeekday;self.selectedDay=selectedDay;self.filter=filter}
    public static func monthKey(_ date:Date=Date(),timeZone:TimeZone = .current)->String {
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        let c=calendar.dateComponents([.year,.month],from:date);return String(format:"%04d-%02d",c.year ?? 0,c.month ?? 0)
    }
}
public struct ActivityCalendarSnapshot:Codable,Equatable,Sendable {
    public var month:String
    public var timeZone:String
    public var firstWeekday:Int
    public var leadingEmptyDays:Int
    public var start:Date
    public var end:Date
    public var scope:ActivitySourceScope
    public var selectedDay:String?
    public var days:[ActivityCalendarDay]
    public var hours:[ActivityCalendarHour]
    public var totalSources:Int {days.reduce(0){$0+$1.sources}}
    public var recordedDays:Int {days.filter {$0.sources>0}.count}
}
public struct ActivityCalendarRevision:Equatable,Sendable {
    public var ownChanges:Int64
    public var externalVersion:Int64
}
private struct ActivityBucket {var kind:Int;var slot:Int;var start:Date;var end:Date}
extension ActivityCalendarRequest {
    func layout() throws -> ActivityCalendarSnapshot {
        let raw=Array(month.utf8)
        guard raw.count==7,raw[4]==45,raw.enumerated().allSatisfy({$0.offset==4 || (48...57).contains($0.element)}),let year=Int(month.prefix(4)),(1...9998).contains(year),let number=Int(month.suffix(2)),(1...12).contains(number),(1...7).contains(firstWeekday) else {throw OSwindError.invalid("Use a Gregorian month YYYY-MM (years 0001–9998), with weekday 1–7")}
        guard filter.query.isEmpty else {throw OSwindError.invalid("Calendar counts saved sources by metadata, not search relevance; remove the query")}
        guard filter.start?.timeIntervalSince1970.isFinite != false,filter.end?.timeIntervalSince1970.isFinite != false else {throw OSwindError.invalid("Invalid calendar scope timestamp")}
        if let start=filter.start,let end=filter.end,start>=end {throw OSwindError.invalid("Calendar time filters do not overlap")}
        for value in [filter.app,filter.tag,filter.speaker].compactMap({$0}) {guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.count<=4000,!value.utf8.contains(0) else {throw OSwindError.invalid("Invalid calendar metadata filter")}}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=timeZone
        guard let anchor=calendar.date(from:DateComponents(year:year,month:number,day:15,hour:12)),let interval=calendar.dateInterval(of:.month,for:anchor),let range=calendar.range(of:.day,in:.month,for:anchor),interval.duration>0,interval.duration<35*86400 else {throw OSwindError.invalid("The requested calendar month is unavailable")}
        var days=[ActivityCalendarDay]()
        for day in range {
            try Task.checkCancellation()
            let key=String(format:"%04d-%02d-%02d",year,number,day)
            if let candidate=calendar.date(from:DateComponents(year:year,month:number,day:day,hour:12)),calendar.component(.year,from:candidate)==year,calendar.component(.month,from:candidate)==number,calendar.component(.day,from:candidate)==day,let span=calendar.dateInterval(of:.day,for:candidate),span.start>=interval.start,span.end<=interval.end {
                days.append(.init(key:key,day:day,start:span.start,end:span.end))
            } else {days.append(.init(key:key,day:day,start:nil,end:nil))}
        }
        var hours=[ActivityCalendarHour]()
        if let selectedDay {
            guard let day=days.first(where:{$0.key==selectedDay}),let start=day.start,let end=day.end else {throw OSwindError.invalid("Choose an available date in the requested month")}
            var cursor=start
            while cursor<end {
                try Task.checkCancellation()
                guard hours.count<72,let span=calendar.dateInterval(of:.hour,for:cursor) else {throw OSwindError.invalid("Hourly calendar boundaries are unavailable")}
                // Repeated hours remain distinct. Partial-hour transitions and
                // unusually long historical clock changes cannot create a gap.
                let next=min(end,min(span.end,cursor.addingTimeInterval(3600)))
                guard next>cursor else {throw OSwindError.invalid("Hourly calendar boundaries did not advance")}
                hours.append(.init(ordinal:hours.count,start:cursor,end:next,hour:calendar.component(.hour,from:cursor),minute:calendar.component(.minute,from:cursor),utcOffsetSeconds:timeZone.secondsFromGMT(for:cursor)))
                cursor=next
            }
        }
        var civil=Calendar(identifier:.gregorian);civil.timeZone=TimeZone(secondsFromGMT:0)!
        guard let first=civil.date(from:DateComponents(year:year,month:number,day:1)) else {throw OSwindError.invalid("Calendar weekday is unavailable")}
        return ActivityCalendarSnapshot(month:month,timeZone:timeZone.identifier,firstWeekday:firstWeekday,leadingEmptyDays:(civil.component(.weekday,from:first)-firstWeekday+7)%7,start:interval.start,end:interval.end,scope:ActivitySourceScope(filter),selectedDay:selectedDay,days:days,hours:hours)
    }
}
extension MemoryStore {
    public func activityCalendarRevision() throws -> ActivityCalendarRevision {
        try Task.checkCancellation()
        return try withRoutineDatabase {database in
            try Task.checkCancellation();let row=try database.statement("PRAGMA data_version");defer {sqlite3_finalize(row)}
            guard sqlite3_step(row)==SQLITE_ROW else {throw database.error()}
            return .init(ownChanges:sqlite3_total_changes64(database.handle),externalVersion:sqlite3_column_int64(row,0))
        }
    }
    /// A single bounded statement counts all records in indexed UTC ranges;
    /// embeddings, media and the result limit are unused. Tag predicates may
    /// inspect JSON tags in SQLite; complete sources are never hydrated.
    public func activityCalendar(_ request:ActivityCalendarRequest) throws -> ActivityCalendarSnapshot {
        try Task.checkCancellation();var snapshot=try request.layout(),buckets=[ActivityBucket]()
        for (slot,day) in snapshot.days.enumerated() {if let start=day.start,let end=day.end {buckets.append(.init(kind:0,slot:slot,start:start,end:end))}}
        for (slot,hour) in snapshot.hours.enumerated() {buckets.append(.init(kind:1,slot:slot,start:hour.start,end:hour.end))}
        guard !buckets.isEmpty,buckets.count<=128 else {throw OSwindError.invalid("Calendar bucket limit exceeded")}
        let predicate=conditions(request.filter)
        return try withRoutineDatabase {database in
            try Task.checkCancellation()
            sqlite3_progress_handler(database.handle,1000,{_ in Task.isCancelled ? 1:0},nil);defer {sqlite3_progress_handler(database.handle,0,nil,nil)}
            let rows=Array(repeating:"(?,?,?,?)",count:buckets.count).joined(separator:",")
            let sql="WITH buckets(kind,slot,start,end) AS (VALUES "+rows+") SELECT b.kind,b.slot,COUNT(m.timestamp) FROM buckets b LEFT JOIN memories m ON m.timestamp>=b.start AND m.timestamp<b.end AND "+predicate.0+" GROUP BY b.kind,b.slot ORDER BY b.kind,b.slot"
            let row=try database.statement(sql);defer {sqlite3_finalize(row)}
            var index:Int32=1
            for bucket in buckets {
                sqlite3_bind_int(row,index,Int32(bucket.kind));sqlite3_bind_int(row,index+1,Int32(bucket.slot));sqlite3_bind_double(row,index+2,bucket.start.timeIntervalSince1970);sqlite3_bind_double(row,index+3,bucket.end.timeIntervalSince1970);index+=4
            }
            for value in predicate.1 {database.bind(row,index,value);index+=1}
            var code=sqlite3_step(row)
            while code==SQLITE_ROW {
                try Task.checkCancellation();let kind=sqlite3_column_int(row,0),slot=Int(sqlite3_column_int(row,1)),count=Int(sqlite3_column_int64(row,2))
                if kind==0 {snapshot.days[slot].sources=count}else {snapshot.hours[slot].sources=count}
                code=sqlite3_step(row)
            }
            if Task.isCancelled {throw CancellationError()};guard code==SQLITE_DONE else {throw database.error()};return snapshot
        }
    }
}
