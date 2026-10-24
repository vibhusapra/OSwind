import Foundation

public struct QuerySyntaxError: LocalizedError, Sendable {
    public var message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
public struct QueryClause: Codable, Equatable, Sendable {
    public var kind: String
    public var label: String
    public var startUTF16: Int
    public var lengthUTF16: Int
}
public struct QueryResolution: Codable, Equatable, Sendable {
    public var originalQuery: String
    public var filter: SearchFilter
    public var clauses: [QueryClause]
    public var timeZone: String
    public func removing(_ clause: QueryClause) -> String {
        guard let range = Range(NSRange(location:clause.startUTF16,length:clause.lengthUTF16),in:originalQuery) else { return originalQuery }
        var copy = originalQuery; copy.removeSubrange(range)
        return copy.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}
/// Deterministic scope extraction, without a model or network request. All date
/// bounds intersect explicit controls; conflicts fail rather than broadening a
/// query. Quoted text, URLs and path-like date words remain searchable content.
public enum QueryScopeResolver {
    private struct Token { var raw: String; var range: NSRange; var quoted: Bool }
    private static let relative = try! NSRegularExpression(pattern:"(?<![\\p{L}\\p{N}_/.-])(?:this morning|this afternoon|this evening|last night|this week|last week|this month|last month|(?:this|last) (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)|(?:past|last) [0-9]{1,4} (?:hours?|days?|weeks?|months?)|today|yesterday)(?![\\p{L}\\p{N}_'’/\\-]|\\.[\\p{L}\\p{N}_])",options:.caseInsensitive)
    public static func resolve(_ input: SearchFilter, now: Date = Date(), timeZone: TimeZone = .current, interpret: Bool = true, canonicalApp: ((String) throws -> String)? = nil) throws -> QueryResolution {
        guard input.query.count <= 4000 else { throw QuerySyntaxError("Keep the search query within 4,000 characters.") }
        var filter = input
        if let app = filter.app, !app.isEmpty { filter.app = try canonicalApp?(app) ?? app }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        func validateBounds() throws {
            guard filter.start?.timeIntervalSinceReferenceDate.isFinite != false, filter.end?.timeIntervalSinceReferenceDate.isFinite != false else { throw QuerySyntaxError("The time range is invalid.") }
            if let start = filter.start, let end = filter.end, start >= end { throw QuerySyntaxError("These time filters do not overlap. Adjust the query or selected range.") }
        }
        try validateBounds()
        guard interpret else { return QueryResolution(originalQuery:input.query,filter:filter,clauses:[],timeZone:timeZone.identifier) }
        var clauses = [QueryClause](), removals = [NSRange]()
        let tokens = lex(input.query), masked = NSMutableString(string:input.query)
        func clause(_ kind: String,_ label: String,_ range: NSRange) {
            clauses.append(QueryClause(kind:kind,label:label,startUTF16:range.location,lengthUTF16:range.length)); removals.append(range)
            masked.replaceCharacters(in:range,with:String(repeating:" ",count:range.length))
        }
        func intersect(_ start: Date?,_ end: Date?) throws {
            if let start { filter.start = max(filter.start ?? start,start) }
            if let end { filter.end = min(filter.end ?? end,end) }
            try validateBounds()
        }
        for token in tokens {
            if token.quoted { masked.replaceCharacters(in:token.range,with:String(repeating:" ",count:token.range.length)); continue }
            guard let separator = token.raw.firstIndex(of:":") else { continue }
            let name = String(token.raw[..<separator]).lowercased()
            guard ["app","kind","tag","speaker","entity","is","on","date","since","until"].contains(name) else {
                masked.replaceCharacters(in:token.range,with:String(repeating:" ",count:token.range.length)); continue
            }
            var rawValue = String(token.raw[token.raw.index(after:separator)...])
            while let last = rawValue.last, ",;!?.".contains(last) { rawValue.removeLast() }
            let value: String
            if rawValue.hasPrefix("“") {
                guard rawValue.hasSuffix("”"), rawValue.count >= 2 else { throw QuerySyntaxError("Close the quoted filter value.") }
                value = String(rawValue.dropFirst().dropLast())
            } else if rawValue.hasPrefix("\"") {
                guard let decoded = try? JSONDecoder().decode(String.self,from:Data(rawValue.utf8)) else { throw QuerySyntaxError("Close the quoted filter value and escape quotes with a backslash.") }; value = decoded
            } else { value = rawValue }
            guard !value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw QuerySyntaxError("Enter a value after \(name): or remove that filter.") }
            switch name {
            case "app":
                let requested = try canonicalApp?(value) ?? value
                if let existing = filter.app, !existing.isEmpty, existing != requested { throw QuerySyntaxError("The query and selected application filters conflict.") }
                filter.app = requested; clause(name,requested,token.range)
            case "kind":
                guard let kind = MemoryKind(rawValue:value.lowercased()) else { throw QuerySyntaxError("kind: must be screen, audio, note or summary.") }
                if let existing = filter.kind, existing != kind { throw QuerySyntaxError("The query and selected memory kinds conflict.") }
                filter.kind = kind; clause(name,kind.rawValue.capitalized,token.range)
            case "tag":
                if let existing = filter.tag, !existing.isEmpty, existing != value { throw QuerySyntaxError("The query and selected tags conflict.") }
                filter.tag = value; clause(name,"#"+value,token.range)
            case "entity":
                try Integration.validateEntityID(value)
                if let existing=filter.entityID,existing != value {throw QuerySyntaxError("The query and selected entity scopes conflict.")}
                filter.entityID=value;clause(name,"Entity: "+value,token.range)
            case "speaker":
                guard value.count<=128,!value.utf8.contains(0) else { throw QuerySyntaxError("Keep speaker labels within 128 characters.") }
                if let existing=filter.speaker,SpeakerLabel.key(existing) != SpeakerLabel.key(value) { throw QuerySyntaxError("The query and selected speaker labels conflict.") }
                filter.speaker=value; clause(name,"Speaker: "+value,token.range)
            case "is":
                guard ["favorite","favourite","saved"].contains(value.lowercased()) else { throw QuerySyntaxError("Use is:favorite to search saved memories.") }
                filter.favoritesOnly = true; clause(name,"Saved",token.range)
            case "on","date":
                let interval = try window(value,now:now,calendar:calendar)
                try intersect(interval.start,interval.end); clause("time",value,token.range)
            case "since","until":
                let boundary = try timestamp(value,calendar:calendar)
                try intersect(name == "since" ? boundary : nil,name == "until" ? boundary : nil)
                clause("time",name.capitalized+" "+value,token.range)
            default: break
            }
        }
        let text = masked as String
        for match in relative.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
            guard let range = Range(match.range,in:text) else { continue }
            let phrase = String(text[range]), interval = try window(phrase,now:now,calendar:calendar)
            try intersect(interval.start,interval.end); clause("time",phrase,match.range)
        }
        let cleaned = NSMutableString(string:input.query)
        for range in removals.sorted(by:{$0.location > $1.location}) { cleaned.replaceCharacters(in:range,with:" ") }
        filter.query = (cleaned as String).split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")
        if !clauses.isEmpty, filter.query.trimmingCharacters(in:.whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty { filter.query = "" }
        return QueryResolution(originalQuery:input.query,filter:filter,clauses:clauses.sorted {$0.startUTF16 < $1.startUTF16},timeZone:timeZone.identifier)
    }
    public static func canonicalAppName(_ requested: String, names: [String]) throws -> String {
        if names.contains(requested) { return requested }
        let matches = names.filter { $0.caseInsensitiveCompare(requested) == .orderedSame }
        guard matches.count < 2 else { throw QuerySyntaxError("More than one application matches that name. Use its exact spelling.") }
        return matches.first ?? requested
    }
    private static func lex(_ text: String) -> [Token] {
        var result = [Token](), cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor].isWhitespace { cursor = text.index(after:cursor); continue }
            let start = cursor; var quoteEnd: Character?, escaped = false
            while cursor < text.endIndex {
                let character = text[cursor]
                if escaped { escaped = false }
                else if quoteEnd != nil && character == "\\" { escaped = true }
                else if let end = quoteEnd { if character == end { quoteEnd = nil } }
                else if character == "\"" { quoteEnd = "\"" }
                else if character == "“" { quoteEnd = "”" }
                else if character.isWhitespace { break }
                cursor = text.index(after:cursor)
            }
            let raw = String(text[start..<cursor])
            // An unterminated whole quoted phrase is protected while typing.
            result.append(Token(raw:raw,range:NSRange(start..<cursor,in:text),quoted:raw.hasPrefix("\"") || raw.hasPrefix("“")))
        }
        return result
    }
    private static func day(_ value: String, calendar: Calendar) throws -> Date {
        let parts = value.split(separator:"-",omittingEmptySubsequences:false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({$0.utf8.allSatisfy { (48...57).contains($0) }}),
              let year = Int(parts[0]), (1...9999).contains(year), let month = Int(parts[1]), let day = Int(parts[2]),
              let date = calendar.date(from:DateComponents(year:year,month:month,day:day)) else { throw QuerySyntaxError("Use a valid YYYY-MM-DD date, or today/yesterday for on:.") }
        let actual = calendar.dateComponents([.year,.month,.day],from:date)
        guard actual.year == year, actual.month == month, actual.day == day else { throw QuerySyntaxError("That date does not exist in the selected time zone.") }
        return calendar.startOfDay(for:date)
    }
    public static func instant(_ value: String) throws -> Date {
        guard (20...64).contains(value.count), value.contains("T") else { throw QuerySyntaxError("Use a complete ISO 8601 calendar timestamp with a time zone.") }
        var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(secondsFromGMT:0)!
        return try timestamp(value,calendar:calendar)
    }
    private static func timestamp(_ value: String, calendar: Calendar) throws -> Date {
        if value.count == 10 { return try day(value,calendar:calendar) }
        var utc = calendar; utc.timeZone = TimeZone(secondsFromGMT:0)!
        _ = try day(String(value.prefix(10)),calendar:utc)
        do { return try Date.ISO8601FormatStyle(includingFractionalSeconds:value.contains(".")).parse(value) }
        catch { throw QuerySyntaxError("Use YYYY-MM-DD or a complete ISO 8601 timestamp for since:/until:.") }
    }
    private static func window(_ value: String, now: Date, calendar: Calendar) throws -> DateInterval {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw QuerySyntaxError("The current time is unavailable.") }
        let phrase = value.lowercased(), today = calendar.startOfDay(for:now)
        func shifted(_ component: Calendar.Component,_ amount: Int,_ date: Date) throws -> Date {
            guard let result = calendar.date(byAdding:component,value:amount,to:date) else { throw QuerySyntaxError("That time range is unavailable.") }; return result
        }
        func clock(_ hour: Int,_ base: Date) throws -> Date {
            guard let date = calendar.date(bySettingHour:hour,minute:0,second:0,of:base,matchingPolicy:.nextTime,repeatedTimePolicy:.first) else { throw QuerySyntaxError("That local time is unavailable.") }; return date
        }
        func hours(_ start: Int,_ end: Int,_ base: Date) throws -> DateInterval { try DateInterval(start:clock(start,base),end:clock(end,base)) }
        switch phrase {
        case "today": return try DateInterval(start:today,end:shifted(.day,1,today))
        case "yesterday": return try DateInterval(start:shifted(.day,-1,today),end:today)
        case "this week","last week","this month","last month":
            let component: Calendar.Component = phrase.hasSuffix("week") ? .weekOfYear : .month
            guard let current = calendar.dateInterval(of:component,for:now) else { throw QuerySyntaxError("That calendar range is unavailable.") }
            if phrase.hasPrefix("this") { return current }
            let preceding = try shifted(component,-1,current.start)
            guard let previous = calendar.dateInterval(of:component,for:preceding) else { throw QuerySyntaxError("That calendar range is unavailable.") }; return previous
        case "this morning": return try hours(0,12,today)
        case "this afternoon": return try hours(12,18,today)
        case "this evening": return try DateInterval(start:clock(18,today),end:shifted(.day,1,today))
        case "last night": return try DateInterval(start:clock(18,shifted(.day,-1,today)),end:clock(6,today))
        default:
            let words = phrase.split(separator:" ")
            let weekdays = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]
            if words.count == 2, ["this","last"].contains(words[0]), let target = weekdays.firstIndex(of:String(words[1])) {
                let current = (calendar.component(.weekday,from:today)+5)%7
                let offset: Int
                if words[0] == "this" { offset = target-current }
                else { let elapsed = (current-target+7)%7; offset = -(elapsed == 0 ? 7 : elapsed) }
                let start = try shifted(.day,offset,today)
                return try DateInterval(start:start,end:shifted(.day,1,start))
            }
            if words.count == 3, ["past","last"].contains(words[0]), let count = Int(words[1]) {
                guard (1...3650).contains(count) else { throw QuerySyntaxError("Choose between 1 and 3650 time units.") }
                let unit = words[2], component: Calendar.Component
                if unit == "hour" || unit == "hours" { component = .hour }
                else if unit == "day" || unit == "days" { component = .day }
                else if unit == "week" || unit == "weeks" { component = .weekOfYear }
                else if unit == "month" || unit == "months" { component = .month }
                else { throw QuerySyntaxError("Use hours, days, weeks or months.") }
                return try DateInterval(start:shifted(component,-count,now),end:now)
            }
            let start = try day(value,calendar:calendar)
            return try DateInterval(start:start,end:shifted(.day,1,start))
        }
    }
}
