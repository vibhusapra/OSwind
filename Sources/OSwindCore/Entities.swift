import Foundation
import CryptoKit

public enum EntityKind:String,Codable,CaseIterable,Sendable {case person,organization,project,place}
public struct MemoryEntity:Identifiable,Codable,Equatable,Sendable {
    public var id:String,kind:EntityKind,name:String,detail:String,curated:Bool,aliases:[String],sourceCount:Int
    public var lastSeen:Date?
}
public struct EntityCandidate:Codable,Equatable,Sendable {
    public var kind:EntityKind,name:String,start:Int,length:Int,method:String
    public var projectID:String?
    public init(kind:EntityKind,name:String,start:Int,length:Int,method:String="apple-nameType",projectID:String?=nil) {self.kind=kind;self.name=name;self.start=start;self.length=length;self.method=method;self.projectID=projectID}
}
public struct EntityExtraction:Sendable {
    public var candidates:[EntityCandidate],limited:Bool
    public init(candidates:[EntityCandidate],limited:Bool=false){self.candidates=candidates;self.limited=limited}
}
public struct EntitySource:Identifiable,Codable,Sendable {
    public var id:String,title:String,app:String,timestamp:Date,origin:String,surface:String,revision:String,passage:PassageRange?
}
public struct EntityIndexProgress:Codable,Sendable {
    public var eligible:Int,indexed:Int,limited:Int
    public init(eligible:Int,indexed:Int,limited:Int){self.eligible=eligible;self.indexed=indexed;self.limited=limited}
}
public struct ProjectEntityRule:Codable,Sendable {public var id:String,name:String,aliases:[String]}
public struct EntityIndexPlan:Sendable {public var revision:String,projects:[ProjectEntityRule]}
public enum EntityLabel {
    public static func clean(_ value:String) throws ->String {
        let result=value.components(separatedBy:.whitespacesAndNewlines).filter {!$0.isEmpty}.joined(separator:" ").precomposedStringWithCanonicalMapping
        guard !result.isEmpty,result.utf8.count<=240,!result.unicodeScalars.contains(where:{$0.properties.generalCategory == .control}) else {throw OSwindError.invalid("Use an entity name of 1–240 UTF-8 bytes")}
        return result
    }
    public static func key(_ value:String)->String {value.precomposedStringWithCanonicalMapping.lowercased(with:Locale(identifier:"en_US_POSIX"))}
}
extension Memory {
    var entityRevision:String {contentHash+":"+String(timestamp.timeIntervalSinceReferenceDate.bitPattern)+":"+kind.rawValue}
}
enum EntitySchema {
    static let sql="""
    CREATE TABLE IF NOT EXISTS memory_entities(id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind IN ('person','organization','project','place')),name TEXT NOT NULL,detail TEXT NOT NULL DEFAULT '',curated INTEGER NOT NULL CHECK(curated IN (0,1)),created REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS entity_aliases(entity_id TEXT NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE,kind TEXT NOT NULL,key TEXT NOT NULL,label TEXT NOT NULL,PRIMARY KEY(kind,key));
    CREATE INDEX IF NOT EXISTS entity_alias_owner ON entity_aliases(entity_id);
    CREATE TABLE IF NOT EXISTS entity_mentions(memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,entity_id TEXT NOT NULL REFERENCES memory_entities(id) ON DELETE CASCADE,origin TEXT NOT NULL CHECK(origin IN ('automatic','manual')),revision TEXT NOT NULL,start INTEGER NOT NULL,length INTEGER NOT NULL,surface TEXT NOT NULL,method TEXT NOT NULL,PRIMARY KEY(memory_id,entity_id,origin));
    CREATE INDEX IF NOT EXISTS entity_mention_owner ON entity_mentions(entity_id,memory_id);
    CREATE TRIGGER IF NOT EXISTS entity_scope_insert AFTER INSERT ON entity_mentions BEGIN UPDATE search_scope_revision SET revision=randomblob(16) WHERE singleton=1; END;
    CREATE TRIGGER IF NOT EXISTS entity_scope_delete AFTER DELETE ON entity_mentions BEGIN UPDATE search_scope_revision SET revision=randomblob(16) WHERE singleton=1; END;
    CREATE TRIGGER IF NOT EXISTS entity_scope_update AFTER UPDATE ON entity_mentions BEGIN UPDATE search_scope_revision SET revision=randomblob(16) WHERE singleton=1; END;
    CREATE TABLE IF NOT EXISTS entity_index_state(memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,processor TEXT NOT NULL,limited INTEGER NOT NULL CHECK(limited IN (0,1)));
    CREATE TABLE IF NOT EXISTS entity_ignored(memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,kind TEXT NOT NULL,key TEXT NOT NULL,PRIMARY KEY(memory_id,kind,key));
    INSERT INTO store_metadata(key,value) VALUES('entity_rules_revision',lower(hex(randomblob(16)))) ON CONFLICT(key) DO NOTHING;
    CREATE TRIGGER IF NOT EXISTS entity_source_delete BEFORE DELETE ON memories BEGIN
        DELETE FROM memory_entities WHERE curated=0 AND id IN (SELECT entity_id FROM entity_mentions WHERE memory_id=old.id) AND NOT EXISTS(SELECT 1 FROM entity_mentions e WHERE e.entity_id=memory_entities.id AND e.memory_id<>old.id);
        DELETE FROM entity_mentions WHERE memory_id=old.id;
        DELETE FROM entity_index_state WHERE memory_id=old.id;
        DELETE FROM entity_ignored WHERE memory_id=old.id;
    END;
    CREATE TRIGGER IF NOT EXISTS entity_source_revision BEFORE UPDATE OF id,title,app,text,url,timestamp,kind ON memories
    WHEN old.id IS NOT new.id OR old.title IS NOT new.title OR old.app IS NOT new.app OR old.text IS NOT new.text OR old.url IS NOT new.url OR old.timestamp IS NOT new.timestamp OR old.kind IS NOT new.kind
    BEGIN
        DELETE FROM memory_entities WHERE curated=0 AND id IN (SELECT entity_id FROM entity_mentions WHERE memory_id=old.id) AND NOT EXISTS(SELECT 1 FROM entity_mentions e WHERE e.entity_id=memory_entities.id AND e.memory_id<>old.id);
        DELETE FROM entity_mentions WHERE memory_id=old.id;
        DELETE FROM entity_index_state WHERE memory_id=old.id;
        DELETE FROM entity_ignored WHERE memory_id=old.id;
    END;
    """
}
