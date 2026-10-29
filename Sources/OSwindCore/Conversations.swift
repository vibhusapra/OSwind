import Foundation

public struct ChatSession: Identifiable, Codable, Sendable {
    public var id: String
    public var title: String
    public var created: Date
    public var updated: Date
    public var turnCount: Int
}
public struct ChatTurn: Identifiable, Codable, Sendable {
    public var id: String
    public var sessionID: String
    public var timestamp: Date
    public var question: String
    public var answer: Answer
    public var filter: SearchFilter
    public var timeZone: String? = nil
}
/// No source text snapshots: source links are hydrated from the live memory store.
struct ChatPayload: Codable {
    var question: String
    var text: String
    var provider: String
    var duration: Double
    var warnings: [String]
    var filter: SearchFilter
    var timeZone: String? = nil
}
public enum ConversationContext {
    public static func questions(_ turns: [ChatTurn]) -> [String] { turns.suffix(3).map { String($0.question.prefix(500)) } }
    public static func retrievalQuery(_ question: String, previousQuestions: [String]) -> String {
        // Earlier questions resolve subjects such as "its deadline". They are
        // never evidence and never override the current explicit filter.
        (previousQuestions.suffix(2).map { String($0.prefix(300)) } + [String(question.prefix(2000))]).joined(separator:"\n")
    }
    public static func markdown(_ session: ChatSession, turns: [ChatTurn]) -> String {
        func stamp(_ date: Date) -> String { (try? ISOTime.string(date)) ?? "invalid time" }
        func quoted(_ text: String) -> String { text.split(separator:"\n",omittingEmptySubsequences:false).map { "> " + $0 }.joined(separator:"\n") }
        var sections = ["# OSwind conversation", "Title: \(session.title.replacingOccurrences(of:"\n",with:" "))", "Exported \(stamp(Date())). Source numbers restart for each answer."]
        for turn in turns {
            sections.append("## \(stamp(turn.timestamp))\n\n### Question\n\n\(quoted(turn.question))\n\n### Answer\n\n\(quoted(turn.answer.text))")
            sections.append("Provider: \(turn.answer.provider). Scope: \(turn.filter.app ?? "all apps"); \(turn.filter.kind?.rawValue ?? "all kinds"); \(turn.filter.start.map { stamp($0) } ?? "any start") to \(turn.filter.end.map { stamp($0) } ?? "any end") (end exclusive). Time zone: \(turn.timeZone ?? "not recorded"). Saved only: \(turn.filter.favoritesOnly). Tag: \(turn.filter.tag ?? "any"). Entity: \(turn.filter.entityID ?? "any").")
            if !turn.answer.warnings.isEmpty { sections.append(turn.answer.warnings.map { "Warning: " + $0 }.joined(separator:"\n\n")) }
            sections.append(turn.filter.sourceStartsOnly==true ? "Time matching: source starts only.":"Time matching: source starts and sampled text span overlaps; gaps are unobserved.")
            sections.append(turn.answer.sources.enumerated().map { i,hit in
                "[\(i+1)] \(hit.memory.title.replacingOccurrences(of:"\n",with:" ")) · \(hit.memory.app) · \(stamp(hit.memory.timestamp))\n\nMemory ID: `\(hit.id)`"
            }.joined(separator:"\n\n"))
        }
        return sections.joined(separator:"\n\n") + "\n"
    }
}
