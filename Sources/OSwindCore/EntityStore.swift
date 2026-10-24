import Foundation
import CSQLite

extension RoutineDatabase {
    func entityAliases(_ id:String)throws->[String] {
        let row=try statement("SELECT label FROM entity_aliases WHERE entity_id=? ORDER BY key");defer {sqlite3_finalize(row)};bind(row,1,id)
        var result=[String]();var code=sqlite3_step(row)
        while code==SQLITE_ROW {result.append(text(row,0));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw error()};return result
    }
    func entityID(kind:EntityKind,key:String)throws->String? {
        let row=try statement("SELECT entity_id FROM entity_aliases WHERE kind=? AND key=?");defer {sqlite3_finalize(row)};bind(row,1,kind.rawValue);bind(row,2,key)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw error()};return text(row,0)
    }
    func entityRuleRevision()throws->String {
        let row=try statement("SELECT value FROM store_metadata WHERE key='entity_rules_revision'");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw error()};return text(row,0)
    }
    func bumpEntityRules()throws {try execute("UPDATE store_metadata SET value=lower(hex(randomblob(16))) WHERE key='entity_rules_revision'")}
    func addEntityAlias(id:String,kind:EntityKind,name:String)throws {
        let row=try statement("INSERT INTO entity_aliases(entity_id,kind,key,label) VALUES(?,?,?,?)");defer {sqlite3_finalize(row)}
        bind(row,1,id);bind(row,2,kind.rawValue);bind(row,3,EntityLabel.key(name));bind(row,4,name);try done(row)
    }
    func entityDefinition(_ id:String)throws->(kind:EntityKind,name:String,curated:Bool) {
        let row=try statement("SELECT kind,name,curated FROM memory_entities WHERE id=?");defer {sqlite3_finalize(row)};bind(row,1,id)
        guard sqlite3_step(row)==SQLITE_ROW,let kind=EntityKind(rawValue:text(row,0)) else {throw OSwindError.invalid("Entity no longer exists")}
        return(kind,text(row,1),sqlite3_column_int(row,2)==1)
    }
    func entityNotes(_ id:String)throws->String {
        let row=try statement("SELECT detail FROM memory_entities WHERE id=?");defer {sqlite3_finalize(row)};bind(row,1,id)
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Entity no longer exists")};return text(row,0)
    }
    func entityKind(_ id:String)throws->EntityKind {try entityDefinition(id).kind}
    func projectIsIgnored(_ id:String,source:String)throws->Bool {
        let legacy=try statement("SELECT 1 FROM entity_ignored WHERE memory_id=? AND kind='project' LIMIT 1");bind(legacy,1,source)
        let code=sqlite3_step(legacy);sqlite3_finalize(legacy);guard code==SQLITE_ROW || code==SQLITE_DONE else {throw error()}
        if code==SQLITE_ROW {
            // An unmapped legacy name may acquire an explicit alias later.
            // Bind at most this project's 32 aliases to the stable project ID.
            let bindLegacy=try statement("INSERT OR IGNORE INTO entity_project_ignored SELECT ?,a.entity_id FROM entity_aliases a WHERE a.entity_id=? AND a.kind='project' AND EXISTS(SELECT 1 FROM entity_ignored i WHERE i.memory_id=? AND i.kind='project' AND i.key=a.key)");defer {sqlite3_finalize(bindLegacy)}
            bind(bindLegacy,1,source);bind(bindLegacy,2,id);bind(bindLegacy,3,source);try done(bindLegacy)
            let clear=try statement("DELETE FROM entity_ignored WHERE memory_id=? AND kind='project' AND key IN (SELECT key FROM entity_aliases WHERE entity_id=? AND kind='project')");defer {sqlite3_finalize(clear)};bind(clear,1,source);bind(clear,2,id);try done(clear)
        }
        let row=try statement("SELECT 1 FROM entity_project_ignored WHERE memory_id=? AND entity_id=?");defer {sqlite3_finalize(row)};bind(row,1,source);bind(row,2,id)
        let result=sqlite3_step(row);guard result==SQLITE_ROW || result==SQLITE_DONE else {throw error()};return result==SQLITE_ROW
    }
}
extension MemoryStore {
    private func entityWrite<T>(_ body:(RoutineDatabase)throws->T)throws->T {
        let activity=try mediaWriteLease();defer {activity.release()};try validateDirectoryIdentity()
        return try withRoutineDatabase {db in try db.transaction {try body(db)}}
    }
    public func entities(kind:EntityKind?=nil,query:String="",limit:Int=100)throws->[MemoryEntity] {
        guard query.utf8.count<=4096 else {throw OSwindError.invalid("Entity query exceeds 4 KiB")}
        return try withRoutineDatabase {db in
            var values=[String](),whereSQL="1=1"
            if let kind {whereSQL+=" AND e.kind=?";values.append(kind.rawValue)}
            if !query.isEmpty {whereSQL+=" AND (instr(lower(e.name),?)>0 OR EXISTS(SELECT 1 FROM entity_aliases a WHERE a.entity_id=e.id AND instr(a.key,?)>0))";values+=[EntityLabel.key(query),EntityLabel.key(query)]}
            let row=try db.statement("SELECT e.id,e.kind,e.name,e.detail,e.curated,COUNT(DISTINCT s.memory_id),MAX(m.timestamp) FROM memory_entities e LEFT JOIN entity_mentions s ON s.entity_id=e.id LEFT JOIN memories m ON m.id=s.memory_id WHERE \(whereSQL) GROUP BY e.id ORDER BY e.curated DESC,MAX(m.timestamp) DESC,e.name LIMIT ?");defer {sqlite3_finalize(row)}
            for (i,value) in values.enumerated(){db.bind(row,Int32(i+1),value)};sqlite3_bind_int(row,Int32(values.count+1),Int32(min(500,max(1,limit))))
            var result=[MemoryEntity](),code=sqlite3_step(row)
            while code==SQLITE_ROW {
                guard let kind=EntityKind(rawValue:db.text(row,1)) else {throw OSwindError.database("Invalid entity kind")}
                let id=db.text(row,0);result.append(MemoryEntity(id:id,kind:kind,name:db.text(row,2),detail:db.text(row,3),curated:sqlite3_column_int(row,4)==1,aliases:try db.entityAliases(id),sourceCount:Int(sqlite3_column_int64(row,5)),lastSeen:sqlite3_column_type(row,6)==SQLITE_NULL ? nil:Date(timeIntervalSince1970:sqlite3_column_double(row,6))));code=sqlite3_step(row)
            }
            guard code==SQLITE_DONE else {throw db.error()};return result
        }
    }
    public func entity(_ id:String)throws->MemoryEntity? {try entitiesByID(id)}
    private func entitiesByID(_ id:String)throws->MemoryEntity? {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT kind,name,detail,curated,(SELECT COUNT(DISTINCT memory_id) FROM entity_mentions WHERE entity_id=e.id),(SELECT MAX(m.timestamp) FROM entity_mentions s JOIN memories m ON m.id=s.memory_id WHERE s.entity_id=e.id) FROM memory_entities e WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id)
            let code=sqlite3_step(row);if code==SQLITE_DONE{return nil};guard code==SQLITE_ROW,let kind=EntityKind(rawValue:db.text(row,0)) else {throw db.error()}
            return MemoryEntity(id:id,kind:kind,name:db.text(row,1),detail:db.text(row,2),curated:sqlite3_column_int(row,3)==1,aliases:try db.entityAliases(id),sourceCount:Int(sqlite3_column_int64(row,4)),lastSeen:sqlite3_column_type(row,5)==SQLITE_NULL ? nil:Date(timeIntervalSince1970:sqlite3_column_double(row,5)))
        }
    }
    @discardableResult public func createEntity(kind:EntityKind,name:String,detail:String="",aliases:[String]=[])throws->MemoryEntity {
        let name=try EntityLabel.clean(name);guard detail.utf8.count<=8000 else {throw OSwindError.invalid("Entity notes exceed 8 KiB")}
        var supplied=[String:String]();for alias in aliases+[name] {let clean=try EntityLabel.clean(alias);supplied[EntityLabel.key(clean)]=clean};guard supplied.count<=32 else {throw OSwindError.invalid("Use at most 32 aliases")}
        let id=try entityWrite {db in
            if let id=try db.entityID(kind:kind,key:EntityLabel.key(name)) {
                let oldAliases=try db.entityAliases(id),previous=try db.entityDefinition(id);guard Set(oldAliases.map(EntityLabel.key)).union(supplied.keys).count<=32 else {throw OSwindError.invalid("Use at most 32 aliases")}
                for (key,label) in supplied {if let owner=try db.entityID(kind:kind,key:key) {guard owner==id else {throw OSwindError.invalid("Alias belongs to another entity")}}else {try db.addEntityAlias(id:id,kind:kind,name:label)}}
                if kind == .project, !previous.curated || !Set(supplied.keys).isSubset(of:Set(oldAliases.map(EntityLabel.key))) {try db.bumpEntityRules()}
                let row=try db.statement("UPDATE memory_entities SET curated=1,detail=CASE WHEN ?='' THEN detail ELSE ? END WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,detail);db.bind(row,2,detail);db.bind(row,3,id);try db.done(row);return id
            }
            let id=UUID().uuidString.lowercased(),row=try db.statement("INSERT INTO memory_entities VALUES(?,?,?,?,1,?)");defer {sqlite3_finalize(row)}
            for(i,value)in[id,kind.rawValue,name,detail].enumerated(){db.bind(row,Int32(i+1),value)};sqlite3_bind_double(row,5,Date().timeIntervalSince1970);try db.done(row);for label in supplied.values {try db.addEntityAlias(id:id,kind:kind,name:label)}
            if kind == .project {try db.bumpEntityRules()};return id
        };guard let result=try entity(id) else {throw OSwindError.unavailable("Entity changed after creation")};return result
    }
    public func editEntity(_ id:String,name:String,detail:String,aliases:[String])throws {
        let name=try EntityLabel.clean(name);var byKey=[String:String]();for value in aliases+[name] {let label=try EntityLabel.clean(value);byKey[EntityLabel.key(label)]=label};let aliases=byKey.values.sorted();guard aliases.count<=32,detail.utf8.count<=8000 else {throw OSwindError.invalid("Use at most 32 aliases and 8 KiB of notes")}
        try entityWrite {db in
            let previous=try db.entityDefinition(id),kind=previous.kind
            // Notes and display-only alias edits do not change matching rules.
            // Primary renames and newly curated restored projects still add rules.
            let rulesChanged=try kind == .project && (!previous.curated || previous.name != name || Set(db.entityAliases(id).map(EntityLabel.key)) != Set(byKey.keys))
            for alias in aliases {if let owner=try db.entityID(kind:kind,key:EntityLabel.key(alias)),owner != id {throw OSwindError.invalid("An alias belongs to another entity; merge explicitly")}}
            let remove=try db.statement("DELETE FROM entity_aliases WHERE entity_id=?");defer {sqlite3_finalize(remove)};db.bind(remove,1,id);try db.done(remove)
            for alias in aliases {try db.addEntityAlias(id:id,kind:kind,name:alias)}
            let row=try db.statement("UPDATE memory_entities SET name=?,detail=?,curated=1 WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,name);db.bind(row,2,detail);db.bind(row,3,id);try db.done(row)
            if rulesChanged {let clear=try db.statement("DELETE FROM entity_mentions WHERE entity_id=? AND origin='automatic'");defer {sqlite3_finalize(clear)};db.bind(clear,1,id);try db.done(clear);try db.bumpEntityRules()}
        }
    }
    /// Curator-directed same-kind merge. No model infers that two people are identical.
    public func mergeEntity(_ sourceID:String,into destinationID:String)throws {
        guard sourceID != destinationID else {throw OSwindError.invalid("Choose two different entities")}
        try entityWrite {db in
            let kind=try db.entityKind(sourceID)
            guard try db.entityKind(destinationID)==kind else {throw OSwindError.invalid("Merge entities of the same kind")}
            let details=try [db.entityNotes(destinationID),db.entityNotes(sourceID)].filter {!$0.isEmpty};let detail=Array(NSOrderedSet(array:details)).compactMap {$0 as? String}.joined(separator:"\n\n")
            guard detail.utf8.count<=8000 else {throw OSwindError.invalid("Merged notes would exceed 8 KiB; edit notes first")}
            let aliases=try db.entityAliases(sourceID)+db.entityAliases(destinationID)
            guard Set(aliases.map(EntityLabel.key)).count<=32 else {throw OSwindError.invalid("Merged entity would exceed 32 aliases")}
            let mentions=try db.statement("INSERT OR IGNORE INTO entity_mentions SELECT memory_id,?,origin,revision,start,length,surface,method FROM entity_mentions WHERE entity_id=?");defer {sqlite3_finalize(mentions)};db.bind(mentions,1,destinationID);db.bind(mentions,2,sourceID);try db.done(mentions)
            if kind == .project {
                let negatives=try db.statement("INSERT OR IGNORE INTO entity_project_ignored SELECT memory_id,? FROM entity_project_ignored WHERE entity_id=?");defer {sqlite3_finalize(negatives)};db.bind(negatives,1,destinationID);db.bind(negatives,2,sourceID);try db.done(negatives)
            }
            let move=try db.statement("UPDATE entity_aliases SET entity_id=? WHERE entity_id=?");defer {sqlite3_finalize(move)};db.bind(move,1,destinationID);db.bind(move,2,sourceID);try db.done(move)
            let curate=try db.statement("UPDATE memory_entities SET curated=1,detail=? WHERE id=?");defer {sqlite3_finalize(curate)};db.bind(curate,1,detail);db.bind(curate,2,destinationID);try db.done(curate)
            let remove=try db.statement("DELETE FROM memory_entities WHERE id=?");defer {sqlite3_finalize(remove)};db.bind(remove,1,sourceID);try db.done(remove)
            if kind == .project {try db.bumpEntityRules()}
        }
    }
    public func deleteEntity(_ id:String)throws {
        try entityWrite {db in
            let kind=try db.entityKind(id),row=try db.statement("DELETE FROM memory_entities WHERE id=?");defer {sqlite3_finalize(row)};db.bind(row,1,id);try db.done(row);if kind == .project {try db.bumpEntityRules()}
        }
    }
    public func linkEntity(_ id:String,to memoryID:String)throws {
        try entityWrite {db in
            let previous=try db.entityDefinition(id);guard let memory=try get(memoryID),memory.searchPreview==nil else {throw OSwindError.invalid("Source no longer exists")}
            let row=try db.statement("INSERT INTO entity_mentions VALUES(?,?,'manual',?,-1,0,'','manual') ON CONFLICT(memory_id,entity_id,origin) DO UPDATE SET revision=excluded.revision");defer {sqlite3_finalize(row)};db.bind(row,1,memoryID);db.bind(row,2,id);db.bind(row,3,memory.entityRevision);try db.done(row)
            let unignore=try db.statement("DELETE FROM entity_ignored WHERE memory_id=? AND (kind,key) IN (SELECT kind,key FROM entity_aliases WHERE entity_id=?)");defer {sqlite3_finalize(unignore)};db.bind(unignore,1,memoryID);db.bind(unignore,2,id);try db.done(unignore)
            let projectIgnore=try db.statement("DELETE FROM entity_project_ignored WHERE memory_id=? AND entity_id=?");defer {sqlite3_finalize(projectIgnore)};db.bind(projectIgnore,1,memoryID);db.bind(projectIgnore,2,id);try db.done(projectIgnore)
            let curate=try db.statement("UPDATE memory_entities SET curated=1 WHERE id=?");defer {sqlite3_finalize(curate)};db.bind(curate,1,id);try db.done(curate)
            if previous.kind == .project && !previous.curated {try db.bumpEntityRules()}
        }
    }
    public func unlinkEntity(_ id:String,from memoryID:String)throws {
        try entityWrite {db in
            let kind=try db.entityKind(id)
            if kind == .project {
                let ignore=try db.statement("INSERT OR IGNORE INTO entity_project_ignored VALUES(?,?)");defer {sqlite3_finalize(ignore)};db.bind(ignore,1,memoryID);db.bind(ignore,2,id);try db.done(ignore)
            } else {
            let ignore=try db.statement("INSERT OR IGNORE INTO entity_ignored SELECT ?,kind,key FROM entity_aliases WHERE entity_id=?");defer {sqlite3_finalize(ignore)};db.bind(ignore,1,memoryID);db.bind(ignore,2,id);try db.done(ignore)
            }
            let row=try db.statement("DELETE FROM entity_mentions WHERE memory_id=? AND entity_id=?");defer {sqlite3_finalize(row)};db.bind(row,1,memoryID);db.bind(row,2,id);try db.done(row)
            if kind != .project {let prune=try db.statement("DELETE FROM memory_entities WHERE id=? AND curated=0 AND NOT EXISTS(SELECT 1 FROM entity_mentions WHERE entity_id=?)");defer {sqlite3_finalize(prune)};db.bind(prune,1,id);db.bind(prune,2,id);try db.done(prune)}
        }
    }
    public func entitySources(_ id:String,limit:Int=100)throws->[EntitySource] {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT m.id,m.title,m.app,m.timestamp,s.origin,s.surface,s.start,s.length,s.revision FROM entity_mentions s JOIN memories m ON m.id=s.memory_id WHERE s.entity_id=? AND (s.origin='automatic' OR NOT EXISTS(SELECT 1 FROM entity_mentions a WHERE a.memory_id=s.memory_id AND a.entity_id=s.entity_id AND a.origin='automatic')) ORDER BY m.timestamp DESC,m.id LIMIT ?");defer {sqlite3_finalize(row)};db.bind(row,1,id);sqlite3_bind_int(row,2,Int32(min(500,max(1,limit))))
            var result=[EntitySource](),seen=Set<String>(),code=sqlite3_step(row)
            while code==SQLITE_ROW {
                let sourceID=db.text(row,0)
                if !seen.contains(sourceID),let memory=try get(sourceID),memory.entityRevision==db.text(row,8) {
                    seen.insert(sourceID);let start=Int(sqlite3_column_int64(row,6)),length=Int(sqlite3_column_int64(row,7))
                    result.append(.init(id:sourceID,title:db.text(row,1),app:db.text(row,2),timestamp:Date(timeIntervalSince1970:sqlite3_column_double(row,3)),origin:db.text(row,4),surface:db.text(row,5),revision:db.text(row,8),passage:start<0 ? nil:PassageRange(start:start,length:length)))
                };code=sqlite3_step(row)
            };guard code==SQLITE_DONE else {throw db.error()};return result
        }
    }
    public func entitySourceMemory(_ source:EntitySource)throws->Memory {
        guard let memory=try get(source.id),memory.entityRevision==source.revision else {throw OSwindError.unavailable("Entity source changed or was removed; refresh its links")}
        if let passage=source.passage {guard passage.text(in:memory.text)==source.surface else {throw OSwindError.invalid("Entity source span changed")}}
        return memory
    }
    public func entityIndexPlan()throws->EntityIndexPlan {
        try withRoutineDatabase {db in
            let revision=try db.entityRuleRevision(),row=try db.statement("SELECT id,name FROM memory_entities WHERE kind='project' AND curated=1 ORDER BY id LIMIT 1001");defer {sqlite3_finalize(row)}
            var projects=[ProjectEntityRule](),code=sqlite3_step(row)
            while code==SQLITE_ROW {guard projects.count<1000 else {throw OSwindError.invalid("Project alias indexing supports at most 1,000 projects")};let id=db.text(row,0);projects.append(.init(id:id,name:db.text(row,1),aliases:try db.entityAliases(id)));code=sqlite3_step(row)}
            guard code==SQLITE_DONE else {throw db.error()};return .init(revision:revision,projects:projects)
        }
    }
    public func pendingEntitySourceIDs(processor:String,after:String="",limit:Int=32)throws->[String] {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT m.id FROM memories m WHERE m.id>? AND m.kind<>'summary' AND NOT EXISTS(SELECT 1 FROM entity_index_state s WHERE s.memory_id=m.id AND s.processor=?) ORDER BY m.id LIMIT ?");defer {sqlite3_finalize(row)};db.bind(row,1,after);db.bind(row,2,processor);sqlite3_bind_int(row,3,Int32(min(100,max(1,limit))))
            var result=[String](),code=sqlite3_step(row);while code==SQLITE_ROW {result.append(db.text(row,0));code=sqlite3_step(row)};guard code==SQLITE_DONE else {throw db.error()};return result
        }
    }
    public func entityIndexProgress(processor:String)throws->EntityIndexProgress {
        try withRoutineDatabase {db in
            let row=try db.statement("SELECT COUNT(*),COALESCE(SUM(s.memory_id IS NOT NULL),0),COALESCE(SUM(s.limited),0) FROM memories m LEFT JOIN entity_index_state s ON s.memory_id=m.id AND s.processor=? WHERE m.kind<>'summary'");defer {sqlite3_finalize(row)};db.bind(row,1,processor);guard sqlite3_step(row)==SQLITE_ROW else {throw db.error()}
            return .init(eligible:Int(sqlite3_column_int64(row,0)),indexed:Int(sqlite3_column_int64(row,1)),limited:Int(sqlite3_column_int64(row,2)))
        }
    }
}
