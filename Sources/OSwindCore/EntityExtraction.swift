import Foundation
import NaturalLanguage
import CSQLite

/// Native name tagging and explicit project-alias rules. Labels are suggestions,
/// not identity resolution or biographies. Each candidate retains a source span.
public enum EntityExtractor {
    public static let maximumEntitiesPerSource=256
    public static var version:String {let os=ProcessInfo.processInfo.operatingSystemVersion;return "apple-nameType-v1:\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"}
    public static func processor(_ plan:EntityIndexPlan)->String {version+":"+plan.revision}
    fileprivate final class Node {var children=[String:Node](),rules=[ProjectEntityRule]()}
    /// Immutable rule trie shared by a single indexing run. Native taggers remain
    /// source-local; no captured text is retained in the prepared rules.
    public final class Prepared:@unchecked Sendable {
        public let plan:EntityIndexPlan
        fileprivate let root:Node
        fileprivate init(plan:EntityIndexPlan,root:Node) {self.plan=plan;self.root=root}
    }
    public static func prepare(_ plan:EntityIndexPlan)throws->Prepared {
        try Task.checkCancellation()
        guard plan.projects.count<=1000,plan.projects.allSatisfy({$0.aliases.count<=32}) else {throw OSwindError.invalid("Use at most 1,000 projects with 32 aliases each")}
        let root=Node();var nodes=1
        for rule in plan.projects {try Task.checkCancellation();for alias in rule.aliases {
            let words=words(alias);guard !words.isEmpty,words.count<=128 else {continue};var node=root
            for word in words {let key=EntityLabel.key(word.0);if node.children[key]==nil {nodes+=1;guard nodes<=262144 else {throw OSwindError.invalid("Project rules exceed the 262,144-token trie budget; reduce aliases")};node.children[key]=Node()};node=node.children[key]!};node.rules.append(rule)
        }}
        return Prepared(plan:plan,root:root)
    }
    public static func extract(_ text:String,plan:EntityIndexPlan)throws->EntityExtraction {try extract(text,prepared:prepare(plan))}
    public static func extract(_ text:String,prepared:Prepared)throws->EntityExtraction {
        try Task.checkCancellation();let root=prepared.root
        let source=text as NSString;var cursor=0,found=[String:EntityCandidate](),limited=false
        while cursor<source.length {
            try Task.checkCancellation()
            let requested=NSRange(location:max(0,cursor-256),length:min(24000,source.length-max(0,cursor-256)))
            let range=source.rangeOfComposedCharacterSequences(for:requested)
            guard range.length<=96000 else {throw OSwindError.invalid("An entity source has an oversized Unicode cluster")}
            let chunk=source.substring(with:range)
            try autoreleasepool {
                let tagger=NLTagger(tagSchemes:[.nameType]);tagger.string=chunk
                tagger.enumerateTags(in:chunk.startIndex..<chunk.endIndex,unit:.word,scheme:.nameType,options:[.omitWhitespace,.omitPunctuation,.joinNames]) {tag,span in
                    if Task.isCancelled {return false}
                    let kind:EntityKind?
                    switch tag {case .personalName:kind = .person;case .organizationName:kind = .organization;case .placeName:kind = .place;default:kind=nil}
                    if let kind,let name=try? EntityLabel.clean(String(chunk[span])),!name.contains("[REDACTED]"),NSRange(span,in:chunk).length<=2048 {
                        let local=NSRange(span,in:chunk),key=kind.rawValue+":"+EntityLabel.key(name)
                        if found[key]==nil {if found.count>=maximumEntitiesPerSource {limited=true;return false};found[key] = .init(kind:kind,name:name,start:range.location+local.location,length:local.length)}
                    };return true
                }
                try Task.checkCancellation()
                let tokens=words(chunk)
                for offset in tokens.indices {
                    if offset%128==0 {try Task.checkCancellation()}
                    var node=root
                    for index in offset..<min(tokens.count,offset+128) {
                        guard let next=node.children[EntityLabel.key(tokens[index].0)] else {break};node=next
                        for rule in node.rules {
                            let key="project:"+rule.id
                            if found[key]==nil {
                                if found.count>=maximumEntitiesPerSource {limited=true;break}
                                let start=tokens[offset].1.location,end=NSMaxRange(tokens[index].1)
                                guard end-start<=2048 else {continue}
                                found[key] = .init(kind:.project,name:rule.name,start:range.location+start,length:end-start,method:"project-alias",projectID:rule.id)
                            }
                        }
                    }
                    if limited {break}
                }
            }
            if limited {break}
            let end=NSMaxRange(range);guard end>cursor else {throw OSwindError.invalid("Entity text cursor did not advance")};cursor=end
        }
        try Task.checkCancellation();return .init(candidates:found.values.sorted {$0.start==$1.start ? $0.name<$1.name:$0.start<$1.start},limited:limited)
    }
    static func matchesProjectSurface(_ surface:String,rule:ProjectEntityRule)->Bool {
        let candidate=words(surface).map {EntityLabel.key($0.0)}
        return !candidate.isEmpty && rule.aliases.contains {words($0).map {EntityLabel.key($0.0)}==candidate}
    }
    private static func words(_ text:String)->[(String,NSRange)] {
        var result=[(String,NSRange)]()
        text.enumerateSubstrings(in:text.startIndex..<text.endIndex,options:[.byWords,.substringNotRequired]) {_,range,_,_ in result.append((String(text[range]),NSRange(range,in:text)))}
        return result
    }
}

extension MemoryStore {
    /// One plaintext source reservation spans native work and cancellation. A
    /// fresh write admission at save refuses an already-closing library.
    @discardableResult public func indexEntities(_ id:String,plan:EntityIndexPlan)throws->Bool {
        try indexEntities(id,prepared:EntityExtractor.prepare(plan))
    }
    @discardableResult public func indexEntities(_ id:String,prepared:EntityExtractor.Prepared)throws->Bool {
        let activity=try mediaWriteLease();defer {activity.release()}
        guard let memory=try get(id),memory.kind != .summary else {return false}
        try Task.checkCancellation();let result=try EntityExtractor.extract(memory.text,prepared:prepared)
        try saveEntityExtraction(memory:memory,plan:prepared.plan,result:result);return true
    }
    public func saveEntityExtraction(memory:Memory,plan:EntityIndexPlan,result:EntityExtraction)throws {
        guard memory.searchPreview==nil,memory.originalEvidence==nil,memory.kind != .summary,result.candidates.count<=EntityExtractor.maximumEntitiesPerSource else {throw OSwindError.invalid("Use a complete non-summary source and bounded entity results")}
        let source=memory.text as NSString
        for candidate in result.candidates {
            guard candidate.start>=0,candidate.length>0,candidate.length<=2048,["apple-nameType","project-alias"].contains(candidate.method),candidate.start<=source.length,candidate.length<=source.length-candidate.start,PassageRange(start:candidate.start,length:candidate.length).text(in:memory.text) != nil else {throw OSwindError.invalid("Entity span is outside its source")}
            _ = try EntityLabel.clean(candidate.name)
            if candidate.projectID==nil {guard candidate.method == "apple-nameType", try EntityLabel.clean(source.substring(with:NSRange(location:candidate.start,length:candidate.length)))==candidate.name,candidate.kind != .project else {throw OSwindError.invalid("Automatic entity name must match its recorded text")}}
        }
        let activity=try mediaWriteLease();defer {activity.release()};try validateDirectoryIdentity()
        try withRoutineDatabase {db in try db.transaction {
            try Task.checkCancellation()
            guard let current=try get(memory.id),current.entityRevision==memory.entityRevision,try db.entityRuleRevision()==plan.revision else {throw OSwindError.unavailable("Entity source or project rules changed; rebuild to refresh")}
            let old=try db.statement("SELECT entity_id FROM entity_mentions WHERE memory_id=? AND origin='automatic'");defer {sqlite3_finalize(old)};db.bind(old,1,memory.id);var oldIDs=[String](),oldCode=sqlite3_step(old);while oldCode==SQLITE_ROW {oldIDs.append(db.text(old,0));oldCode=sqlite3_step(old)};guard oldCode==SQLITE_DONE else {throw db.error()}
            let clear=try db.statement("DELETE FROM entity_mentions WHERE memory_id=? AND origin='automatic'");defer {sqlite3_finalize(clear)};db.bind(clear,1,memory.id);try db.done(clear)
            for candidate in result.candidates {
                try Task.checkCancellation();let key=EntityLabel.key(candidate.name),id:String
                if let project=candidate.projectID {
                    let actual=try db.entityDefinition(project),aliases=try db.entityAliases(project)
                    guard candidate.method == "project-alias",candidate.kind == .project,actual.kind == .project,actual.curated,actual.name==candidate.name,EntityExtractor.matchesProjectSurface(source.substring(with:NSRange(location:candidate.start,length:candidate.length)),rule:.init(id:project,name:actual.name,aliases:aliases)) else {throw OSwindError.invalid("Project rule no longer matches")}
                    if try db.projectIsIgnored(project,source:memory.id) {continue};id=project
                } else {
                    let ignored=try db.statement("SELECT 1 FROM entity_ignored WHERE memory_id=? AND kind=? AND key=?");db.bind(ignored,1,memory.id);db.bind(ignored,2,candidate.kind.rawValue);db.bind(ignored,3,key);let ignoredCode=sqlite3_step(ignored);sqlite3_finalize(ignored);guard ignoredCode==SQLITE_ROW || ignoredCode==SQLITE_DONE else {throw db.error()};if ignoredCode==SQLITE_ROW {continue}
                    if let found=try db.entityID(kind:candidate.kind,key:key) {id=found}
                    else {
                    id=UUID().uuidString.lowercased();let row=try db.statement("INSERT INTO memory_entities VALUES(?,?,?,'',0,?)");defer {sqlite3_finalize(row)};db.bind(row,1,id);db.bind(row,2,candidate.kind.rawValue);db.bind(row,3,candidate.name);sqlite3_bind_double(row,4,Date().timeIntervalSince1970);try db.done(row);try db.addEntityAlias(id:id,kind:candidate.kind,name:candidate.name)
                }
                }
                let mention=try db.statement("INSERT OR IGNORE INTO entity_mentions VALUES(?,?,'automatic',?,?,?,?,?)");defer {sqlite3_finalize(mention)};db.bind(mention,1,memory.id);db.bind(mention,2,id);db.bind(mention,3,memory.entityRevision);sqlite3_bind_int64(mention,4,Int64(candidate.start));sqlite3_bind_int64(mention,5,Int64(candidate.length));db.bind(mention,6,source.substring(with:NSRange(location:candidate.start,length:candidate.length)));db.bind(mention,7,candidate.method);try db.done(mention)
            }
            let prune=try db.statement("DELETE FROM memory_entities WHERE id=? AND curated=0 AND NOT EXISTS(SELECT 1 FROM entity_mentions WHERE entity_id=?) AND NOT EXISTS(SELECT 1 FROM entity_project_ignored WHERE entity_id=?)");defer {sqlite3_finalize(prune)}
            for id in Set(oldIDs) {sqlite3_reset(prune);sqlite3_clear_bindings(prune);db.bind(prune,1,id);db.bind(prune,2,id);db.bind(prune,3,id);try db.done(prune)}
            let state=try db.statement("INSERT INTO entity_index_state VALUES(?,?,?) ON CONFLICT(memory_id) DO UPDATE SET processor=excluded.processor,limited=excluded.limited");defer {sqlite3_finalize(state)};db.bind(state,1,memory.id);db.bind(state,2,EntityExtractor.processor(plan));sqlite3_bind_int(state,3,result.limited ? 1:0);try db.done(state)
        }}
    }
}
