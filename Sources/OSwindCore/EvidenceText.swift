import Foundation

/// Lexical excerpts of the original text. Ellipses mark omitted source ranges;
/// no generated text is substituted for evidence. This is not semantic chunking.
public enum EvidenceText {
    private struct Match { var range: NSRange; var term: Int }
    private static func terms(_ query: String) -> [String] {
        Array(Set(MemoryStore.queryTerms(query).map { term in
            // Small English plural normalization for follow-ups such as
            // “deadlines”. Other scripts and short/code tokens stay literal.
            guard term.count > 3, term.allSatisfy({ $0.isASCII && $0.isLetter }) else { return term }
            if term.hasSuffix("ies") { return String(term.dropLast(3))+"y" }
            if term.hasSuffix("sses") || term.hasSuffix("ches") || term.hasSuffix("shes") || term.hasSuffix("xes") { return String(term.dropLast(2)) }
            if term.hasSuffix("s") && !term.hasSuffix("ss") && !term.hasSuffix("us") && !term.hasSuffix("is") { return String(term.dropLast()) }
            return term
        })).sorted()
    }
    private static func matches(_ text: NSString, terms: [String], perTerm: Int = 256) -> [Match] {
        var result = [Match]()
        for (index,term) in terms.enumerated() {
            if Task.isCancelled { break }
            var cursor = 0, accepted = 0
            while cursor < text.length && accepted < perTerm && !Task.isCancelled {
                let range = text.range(of:term,options:[.caseInsensitive,.diacriticInsensitive],range:NSRange(location:cursor,length:text.length-cursor))
                guard range.location != NSNotFound, range.length > 0 else { break }
                cursor = NSMaxRange(range)
                // Match word prefixes for Latin/code terms; permit substring
                // matches in scripts without spaces, including CJK.
                if term.first?.isASCII == true, range.location > 0, let scalar = UnicodeScalar(text.character(at:range.location-1)), CharacterSet.alphanumerics.contains(scalar) { continue }
                result.append(Match(range:range,term:index)); accepted += 1
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }
    public static func matchRanges(in text: String, query: String, limit: Int = 128) -> [NSRange] {
        let value = text as NSString
        let ranges = matches(value,terms:terms(query),perTerm:min(256,max(1,limit)))
        var merged = [NSRange]()
        for match in ranges.prefix(max(0,min(4096,limit))) {
            let aligned = value.rangeOfComposedCharacterSequences(for:match.range)
            if let last = merged.last, NSMaxRange(last) >= aligned.location { merged[merged.count-1] = NSUnionRange(last,aligned) }
            else { merged.append(aligned) }
        }
        return merged
    }
    private static func bestRange(length: Int, width: Int, matches: [Match], weights: [Double], avoiding: NSRange? = nil) -> NSRange? {
        let starts = Set(matches.map { min(max(0,$0.range.location-width/3),max(0,length-width)) }).sorted()
        var left = 0, right = 0, counts = [Int](repeating:0,count:weights.count), score = 0.0, best = -Double.infinity, selected: NSRange?
        for start in starts {
            if Task.isCancelled { break }
            let range = NSRange(location:start,length:min(width,length-start)), end = NSMaxRange(range)
            while right < matches.count && matches[right].range.location < end {
                let term = matches[right].term
                if counts[term] == 0 { score += weights[term] }; if counts[term] < 3 { score += 0.02 }
                counts[term] += 1; right += 1
            }
            while left < right && matches[left].range.location < start {
                let term = matches[left].term
                counts[term] -= 1; if counts[term] == 0 { score -= weights[term] }; if counts[term] < 3 { score -= 0.02 }
                left += 1
            }
            if let avoiding, NSIntersectionRange(range,avoiding).length > 0 { continue }
            if right > left && (score > best+1e-9 || abs(score-best) <= 1e-9 && start > (selected?.location ?? -1)) { best = score; selected = range }
        }
        return selected
    }
    static func excerptRanges(_ text: String, query: String = "", budget: Int = 800, summary: Bool = false, anchors:[NSRange]=[]) -> [NSRange] {
        let value = text as NSString, size = max(40,min(12000,budget))
        guard value.length > size else { return value.length == 0 ? []:[NSRange(location:0,length:value.length)] }
        let terms = terms(query), found = (matches(value,terms:terms) + anchors.prefix(256).map { Match(range:$0,term:terms.count) }).sorted {$0.range.location < $1.range.location}
        var ranges = [NSRange]()
        if !summary && !found.isEmpty {
            var frequency = [Int](repeating:0,count:terms.count+(anchors.isEmpty ? 0:1))
            for match in found { frequency[match.term] += 1 }
            let weights = frequency.map { $0 > 0 ? 1/sqrt(Double($0)) : 0 }
            if let whole = bestRange(length:value.length,width:size,matches:found,weights:weights) {
                let covered = Set(found.filter { NSIntersectionRange($0.range,whole).length == $0.range.length }.map(\.term))
                if covered.count < Set(found.map(\.term)).count,
                   let first = bestRange(length:value.length,width:size/2,matches:found,weights:weights) {
                    let firstTerms = Set(found.filter { NSIntersectionRange($0.range,first).length == $0.range.length }.map(\.term))
                    let remainingWeights = weights.enumerated().map { firstTerms.contains($0.offset) ? $0.element*0.1 : $0.element*4 }
                    if let second = bestRange(length:value.length,width:size-size/2,matches:found,weights:remainingWeights,avoiding:first) { ranges = [first,second] }
                }
                if ranges.isEmpty { ranges = [whole] }
            }
        }
        if ranges.isEmpty {
            // No lexical anchor (or a recap): preserve both the opening and the
            // end, where meeting decisions often occur, within the same budget.
            let head = size/2
            ranges = [NSRange(location:0,length:head),NSRange(location:value.length-(size-head),length:size-head)]
        }
        var merged = [NSRange]()
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            var aligned = value.rangeOfComposedCharacterSequences(for:range)
            if aligned.location > 0, let before = UnicodeScalar(value.character(at:aligned.location-1)), let first = UnicodeScalar(value.character(at:aligned.location)), CharacterSet.alphanumerics.contains(before), CharacterSet.alphanumerics.contains(first) {
                let separator = value.rangeOfCharacter(from:.whitespacesAndNewlines,range:NSRange(location:aligned.location,length:min(24,aligned.length)))
                if separator.location != NSNotFound, NSMaxRange(aligned)-NSMaxRange(separator) >= 40 {
                    let end = NSMaxRange(aligned); aligned.location = NSMaxRange(separator); aligned.length = end-aligned.location
                }
            }
            if let last = merged.last, NSMaxRange(last) >= aligned.location { merged[merged.count-1] = NSUnionRange(last,aligned) }
            else { merged.append(aligned) }
        }
        return merged
    }
    public static func excerpt(_ text: String, query: String = "", budget: Int = 800, summary: Bool = false) -> String {
        if (text as NSString).length<=max(40,min(12000,budget)) { return text }
        let value=text as NSString, merged=excerptRanges(text,query:query,budget:budget,summary:summary)
        guard !merged.isEmpty else { return "" }
        let fragments = merged.map { value.substring(with:$0).trimmingCharacters(in:.whitespacesAndNewlines) }
        return (merged.first!.location > 0 ? "… " : "") + fragments.joined(separator:"\n…\n") + (NSMaxRange(merged.last!) < value.length ? " …" : "")
    }
}
