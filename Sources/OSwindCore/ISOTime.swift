import Foundation

/// Public ISO timestamps keep representable fractional boundaries. Stored chat
/// payloads retain their existing numeric Date coding for backward compatibility.
public enum ISOTime {
    public static func string(_ date: Date) throws -> String {
        let reference = date.timeIntervalSinceReferenceDate
        guard reference.isFinite, abs(reference) < 1_000_000_000_000 else { throw OSwindError.invalid("Cannot encode an invalid timestamp") }
        let whole = floor(reference), fraction = reference-whole
        let base = Date.ISO8601FormatStyle().format(Date(timeIntervalSinceReferenceDate:whole))
        guard fraction != 0 else { return base }
        var digits = 9, units = Int((fraction*1_000_000_000).rounded()), represented = false
        for (precision,scale) in [(3,1_000),(6,1_000_000),(9,1_000_000_000)] {
            let rounded = Int((fraction*Double(scale)).rounded())
            if whole+Double(rounded)/Double(scale) == reference { digits = precision; units = rounded; represented = true; break }
        }
        guard represented else { throw OSwindError.invalid("Timestamp exceeds supported ISO nanosecond precision") }
        let scale = digits == 3 ? 1000 : digits == 6 ? 1_000_000 : 1_000_000_000
        if units == scale { return Date.ISO8601FormatStyle().format(Date(timeIntervalSinceReferenceDate:whole+1)) }
        var suffix = String(units); suffix = String(repeating:"0",count:max(0,digits-suffix.count))+suffix
        while suffix.last == "0" { suffix.removeLast() }
        return String(base.dropLast())+"."+suffix+"Z"
    }
    static func encode(_ date: Date, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(string(date))
    }
    static func decode(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            guard seconds.isFinite else { throw OSwindError.invalid("Invalid legacy timestamp") }
            return Date(timeIntervalSinceReferenceDate:seconds)
        }
        return try QueryScopeResolver.instant(container.decode(String.self))
    }
}
