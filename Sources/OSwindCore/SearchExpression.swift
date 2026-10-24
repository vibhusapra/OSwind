import Foundation

/// Ordinary questions retain soft token ranking. Double-quoted phrases are
/// required; uppercase Boolean operators opt into explicit content constraints.
/// This type only creates bound FTS operands, never caller-supplied SQL.
public struct SearchExpressionPlan: Sendable {
    struct Atom: Hashable, Sendable {
        var text: String
        var phrase: Bool
        var fts: String { "\""+text.replacingOccurrences(of:"\"",with:"\"\"")+"\""+(phrase ? "":"*") }
    }
    indirect enum Node: Sendable {
        case atom(Atom), not(Node), and(Node,Node), or(Node,Node)
        func normalized(negated: Bool = false) -> Node {
            switch self {
            case .atom: return negated ? .not(self):self
            case .not(let child): return child.normalized(negated:!negated)
            case .and(let a,let b): return negated ? .or(a.normalized(negated:true),b.normalized(negated:true)):.and(a.normalized(),b.normalized())
            case .or(let a,let b): return negated ? .and(a.normalized(negated:true),b.normalized(negated:true)):.or(a.normalized(),b.normalized())
            }
        }
        var anchored: Bool {
            switch self { case .atom: return true; case .not: return false; case .and(let a,let b): return a.anchored || b.anchored; case .or(let a,let b): return a.anchored && b.anchored }
        }
        var positive: [Atom] {
            switch self { case .atom(let atom): return [atom]; case .not: return []; case .and(let a,let b),.or(let a,let b): return a.positive+b.positive }
        }
        func predicate(prefix: String, values: inout [String]) -> String {
            switch self {
            case .atom(let atom):
                values += [atom.fts,atom.fts]
                return "(\(prefix)id IN (SELECT id FROM memory_fts WHERE memory_fts MATCH ?) OR \(prefix)id IN (SELECT memory_id FROM speaker_fts WHERE speaker_fts MATCH ?))"
            case .not(let child): return "NOT ("+child.predicate(prefix:prefix,values:&values)+")"
            case .and(let a,let b): return "("+a.predicate(prefix:prefix,values:&values)+" AND "+b.predicate(prefix:prefix,values:&values)+")"
            case .or(let a,let b): return "("+a.predicate(prefix:prefix,values:&values)+" OR "+b.predicate(prefix:prefix,values:&values)+")"
            }
        }
    }
    enum Token: Equatable { case word(String), phrase(String), and, or, not, open, close }
    var constraint: Node?
    var keywordFTS: String
    var speakerFTS: String
    var semanticText: String
    var materialized = false
    public var summary: String?
    public var hasConstraints: Bool { constraint != nil }
    var positivePhrases: [String] { (constraint?.positive ?? []).filter(\.phrase).map(\.text) }
    var cacheIdentity: String? {
        guard let constraint else { return nil }
        var values = [String](); let sql = constraint.predicate(prefix:"m.",values:&values)
        return BackupSHA256.hex(Data(sql.utf8)+(try! JSONEncoder().encode(values)))
    }
    /// Previous questions are subject cues, never new syntax or constraints.
    /// Keep their words available for ranking without importing old filters.
    func addingRankingContext(_ context: String) -> Self {
        guard !context.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return self }
        var copy = self
        let text = String(context.prefix(600)).replacingOccurrences(of:"\0",with:" ")
        copy.keywordFTS = [keywordFTS,MemoryStore.ftsQuery(text)].filter {!$0.isEmpty}.map { "("+$0+")" }.joined(separator:" OR ")
        copy.speakerFTS = [speakerFTS,SpeakerLabel.ftsQuery(text)].filter {!$0.isEmpty}.map { "("+$0+")" }.joined(separator:" OR ")
        copy.semanticText = text+"\n"+semanticText
        return copy
    }

    public static func make(_ input: String, interpret: Bool = true) throws -> Self {
        guard input.count <= 4000,!input.utf8.contains(0) else { throw QuerySyntaxError("Keep the query within 4,000 characters, without NUL characters.") }
        var result = Self(constraint:nil,keywordFTS:MemoryStore.ftsQuery(input),speakerFTS:SpeakerLabel.ftsQuery(input),semanticText:input,summary:nil)
        guard interpret else { return result }
        let operatorWord = input.split(whereSeparator:{$0.isWhitespace || $0 == "(" || $0 == ")"}).contains { ["AND","OR","NOT"].contains(String($0)) }
        guard operatorWord || input.contains("\"") || input.contains("“") else { return result }
        let tokens = try lex(input)
        let boolean = tokens.contains(.and) || tokens.contains(.or) || tokens.contains(.not)
        if boolean {
            guard tokens.count <= 192 else { throw QuerySyntaxError("Simplify the expression to at most 64 words/phrases and 12 nested groups.") }
            var parser = Parser(tokens:tokens)
            let tree = try parser.parse().normalized()
            guard tree.anchored else { throw QuerySyntaxError("Each OR branch needs a positive word or phrase. Combine NOT with an AND condition.") }
            result.constraint = tree
            let positive = unique(tree.positive)
            result.keywordFTS = positive.map(\.fts).joined(separator:" OR "); result.speakerFTS = result.keywordFTS
            result.semanticText = positive.map(\.text).joined(separator:" ")
            result.summary = "Boolean content filter"
        } else {
            let phrases = try tokens.compactMap { token -> Atom? in
                guard case .phrase(let text) = token else { return nil }; return try phrase(text)
            }
            guard !phrases.isEmpty else { return result }
            guard phrases.count <= 32 else { throw QuerySyntaxError("Use at most 32 required phrases.") }
            result.constraint = phrases.dropFirst().reduce(.atom(phrases[0])) { .and($0,.atom($1)) }
            // Stopword removal must never drop the only positive phrase anchor.
            let anchors = unique(phrases).map(\.fts).joined(separator:" OR ")
            result.keywordFTS = [result.keywordFTS,anchors].filter {!$0.isEmpty}.map { "("+$0+")" }.joined(separator:" OR ")
            result.speakerFTS = [result.speakerFTS,anchors].filter {!$0.isEmpty}.map { "("+$0+")" }.joined(separator:" OR ")
            result.summary = phrases.count == 1 ? "Required phrase":"\(phrases.count) required phrases"
        }
        return result
    }
    private static func phrase(_ text: String) throws -> Atom {
        guard text.contains(where:{$0.isLetter || $0.isNumber}) else { throw QuerySyntaxError("A quoted phrase needs a word or number.") }
        return Atom(text:text,phrase:true)
    }
    private static func unique(_ atoms: [Atom]) -> [Atom] { var seen = Set<Atom>(); return atoms.filter { seen.insert($0).inserted } }
    private static func lex(_ input: String) throws -> [Token] {
        var tokens = [Token](), cursor = input.startIndex
        while cursor < input.endIndex {
            let character = input[cursor]
            if character.isWhitespace { cursor = input.index(after:cursor); continue }
            if character == "(" || character == ")" { tokens.append(character == "(" ? .open:.close); cursor = input.index(after:cursor); continue }
            if character == "\"" || character == "“" {
                let end: Character = character == "“" ? "”":"\""; cursor = input.index(after:cursor)
                var value = "", closed = false
                while cursor < input.endIndex {
                    let item = input[cursor]; cursor = input.index(after:cursor)
                    if item == end { closed = true; break }
                    if item == "\\",cursor < input.endIndex {
                        let next = input[cursor]
                        if next == end || next == "\\" { value.append(next); cursor = input.index(after:cursor); continue }
                    }
                    value.append(item)
                }
                guard closed else { throw QuerySyntaxError("Close the quoted phrase, or turn Query filters off to search it as ordinary text.") }
                tokens.append(.phrase(value)); continue
            }
            let start = cursor
            while cursor < input.endIndex,!input[cursor].isWhitespace,!"()\"“".contains(input[cursor]) { cursor = input.index(after:cursor) }
            let text = String(input[start..<cursor])
            switch text {
            case "AND": tokens.append(.and)
            case "OR": tokens.append(.or)
            case "NOT": tokens.append(.not)
            default:
                let words = text.lowercased().split(whereSeparator:{!$0.isLetter && !$0.isNumber}).map(String.init)
                tokens += words.map(Token.word)
            }
        }
        return tokens
    }
    private struct Parser {
        let tokens: [Token]
        var index = 0, atoms = 0
        mutating func parse() throws -> Node {
            let value = try disjunction(depth:0)
            guard index == tokens.count else { throw QuerySyntaxError("Check the parentheses and Boolean operators.") }
            return value
        }
        mutating func disjunction(depth: Int) throws -> Node {
            var value = try conjunction(depth:depth)
            while take(.or) { value = .or(value,try conjunction(depth:depth)) }
            return value
        }
        mutating func conjunction(depth: Int) throws -> Node {
            var value = try unary(depth:depth)
            while index < tokens.count {
                if tokens[index] == .or || tokens[index] == .close { break }
                _ = take(.and)
                value = .and(value,try unary(depth:depth))
            }
            return value
        }
        mutating func unary(depth: Int) throws -> Node {
            guard depth <= 12,index < tokens.count else { throw QuerySyntaxError("An operator needs a word/phrase; use at most 12 nested groups or NOT operators.") }
            if take(.not) { return .not(try unary(depth:depth+1)) }
            if take(.open) {
                let value = try disjunction(depth:depth+1)
                guard take(.close) else { throw QuerySyntaxError("Close the search group with a parenthesis.") }; return value
            }
            let token = tokens[index]; index += 1; atoms += 1
            guard atoms <= 64 else { throw QuerySyntaxError("Use at most 64 expression words or phrases.") }
            switch token {
            case .word(let text): return .atom(Atom(text:text,phrase:false))
            case .phrase(let text): return .atom(try SearchExpressionPlan.phrase(text))
            default: throw QuerySyntaxError("Place a word or phrase between Boolean operators.")
            }
        }
        mutating func take(_ token: Token) -> Bool { guard index < tokens.count,tokens[index] == token else { return false }; index += 1; return true }
    }
}
