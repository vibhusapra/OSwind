import Foundation

/// Additive, rebuildable cache metadata. Existing schema-5 writers preserve these
/// triggers, so their metadata writes invalidate masks too. The nonce is read in
/// the same SQLite snapshot as the candidate scope, never from a process clock.
enum SearchScopeSchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS search_scope_revision (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision BLOB NOT NULL CHECK(length(revision)=16)
    );
    INSERT INTO search_scope_revision(singleton,revision) VALUES(1,randomblob(16)) ON CONFLICT(singleton) DO NOTHING;
    CREATE TRIGGER IF NOT EXISTS scope_insert AFTER INSERT ON memories BEGIN
        UPDATE search_scope_revision SET revision=randomblob(16) WHERE singleton=1;
    END;
    CREATE TRIGGER IF NOT EXISTS scope_delete AFTER DELETE ON memories BEGIN
        UPDATE search_scope_revision SET revision=randomblob(16) WHERE singleton=1;
    END;
    CREATE TRIGGER IF NOT EXISTS scope_update AFTER UPDATE OF app,kind,timestamp,favorite,payload ON memories
    WHEN old.app IS NOT new.app OR old.kind IS NOT new.kind OR old.timestamp IS NOT new.timestamp OR old.favorite IS NOT new.favorite OR old.payload IS NOT new.payload
    BEGIN
        UPDATE search_scope_revision SET revision=randomblob(16) WHERE singleton=1;
    END;
    """
}
struct MetalScopeKey: Equatable {
    var identity: String
    var model: String
    var sequence: Int64
    var revision: String
    var predicate: String
    var values: [String]
    var expression: String? = nil
    static func ==(a:Self,b:Self)->Bool {
        func same(_ x:String,_ y:String)->Bool {x.utf8.elementsEqual(y.utf8)}
        let expressionSame:Bool
        switch (a.expression,b.expression) {case (nil,nil):expressionSame=true;case let (x?,y?):expressionSame=same(x,y);default:expressionSame=false}
        return a.sequence==b.sequence && same(a.identity,b.identity) && same(a.model,b.model) && same(a.revision,b.revision) && same(a.predicate,b.predicate) && a.values.count==b.values.count && zip(a.values,b.values).allSatisfy {same($0.0,$0.1)} && expressionSame
    }
}
struct MetalScopeSnapshot {
    var key: MetalScopeKey
    var allowed: Set<UInt64>
}

/// A few recent scopes support fast app/date switching without retaining an
/// unbounded set for every combination. Revision changes discard all old masks.
struct MetalScopeCache {
    private var snapshots = [MetalScopeSnapshot]()
    mutating func lookup(_ key: MetalScopeKey) -> Set<UInt64>? {
        snapshots.removeAll { $0.key.identity != key.identity || $0.key.model != key.model || $0.key.sequence != key.sequence || $0.key.revision != key.revision }
        guard let index = snapshots.firstIndex(where:{$0.key == key}) else { return nil }
        let found = snapshots.remove(at:index); snapshots.append(found); return found.allowed
    }
    mutating func insert(_ snapshot: MetalScopeSnapshot) {
        snapshots.removeAll { $0.key == snapshot.key }
        snapshots.append(snapshot)
        while snapshots.count > 4 || snapshots.reduce(0,{$0+$1.allowed.count}) > 2_000_000 { snapshots.removeFirst() }
    }
}
