import Foundation
import CSQLite

/// A bounded operational rescan hint, never authority for source content or a
/// journal revision. Erasure changes one small value, even if work is full.
/// Canonical indexed rows select candidates; ordinary outgoing preparation still
/// admits every current owner, policy, dependency and immutable version.
enum SyncRecordingReconciliation {
    static let key="recording_wire_reconciliation_v1"
    struct Cursor:Codable {let target:String,id:String}
    struct State:Codable {let nonce:String,pending:Bool,cursor:Cursor?}
    struct Progress {let scanned:Int,queued:Int}
    private static func encoded(_ value:State)throws->String {
        try SyncProtocolLimits.uuid(value.nonce)
        guard value.pending || value.cursor==nil else {throw OSwindError.database("Completed recording revalidation has a cursor")}
        if let cursor=value.cursor {
            guard !cursor.target.isEmpty,!cursor.id.isEmpty,cursor.target.utf8.count<=32768,cursor.id.utf8.count<=32768 else {throw OSwindError.database("Recording revalidation cursor exceeds its bounds")}
        }
        let data=try SyncProtocolLimits.encode(value)
        guard data.count<=65536,let text=String(data:data,encoding:.utf8) else {throw OSwindError.database("Recording revalidation metadata exceeds its bounds")}
        return text
    }
    private static func read(_ db:RoutineDatabase)throws->(State,String)? {
        guard try db.eraseCount("PRAGMA user_version")>=33 else {return nil}
        let row=try db.statement("SELECT value FROM store_metadata WHERE key=?");defer {sqlite3_finalize(row)};db.bind(row,1,key)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil}
        guard code==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_TEXT,sqlite3_column_bytes(row,0)<=65536 else {throw OSwindError.database("Recording revalidation metadata differs")}
        let text=db.text(row,0),value=try JSONDecoder().decode(State.self,from:Data(text.utf8))
        guard Data(try encoded(value).utf8)==Data(text.utf8) else {throw OSwindError.database("Recording revalidation metadata is not canonical")}
        return(value,text)
    }
    /// Explicit outgoing installation only; normal opening does not activate it.
    static func install(_ db:RoutineDatabase)throws {
        guard try db.eraseCount("PRAGMA user_version")>=33 else {return}
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Install recording revalidation in the outgoing transaction")}
        if try read(db) != nil {return}
        let pending=try db.eraseCount("SELECT EXISTS(SELECT 1 FROM historical_scope_revoked_versions)")==1
        let state=try encoded(State(nonce:UUID().uuidString.lowercased(),pending:pending,cursor:nil))
        let row=try db.statement("INSERT INTO store_metadata(key,value) VALUES(?,?)");defer {sqlite3_finalize(row)};db.bind(row,1,key);db.bind(row,2,state);try db.done(row)
    }
    static func markErasure(_ db:RoutineDatabase)throws {
        guard let (_,before)=try read(db) else {return} // A later first install checks durable revocations.
        guard sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.invalid("Mark recording revalidation in the owning erasure transaction")}
        try replace(db,before:before,with:State(nonce:UUID().uuidString.lowercased(),pending:true,cursor:nil))
    }
    private static func replace(_ db:RoutineDatabase,before:String,with value:State)throws {
        let row=try db.statement("UPDATE store_metadata SET value=? WHERE key=? AND value=? COLLATE BINARY");defer {sqlite3_finalize(row)};db.bind(row,1,try encoded(value));db.bind(row,2,key);db.bind(row,3,before);try db.done(row)
        guard sqlite3_changes(db.handle)==1 else {throw OSwindError.invalid("Recording revalidation changed during its transaction")}
    }
    /// Existing canonical expression index supplies a two-field UTF-8 keyset.
    /// No transcript/media read, full-memory scan or mutable display-cache edge.
    static func query(after:Bool)->String {
        let target=RecordingRelationshipIndexes.scopeID("m"),selector=RecordingRelationshipIndexes.selector("m")
        return "SELECT m.id,\(target) FROM memories m INDEXED BY \(RecordingRelationshipIndexes.names) WHERE m.kind='recording-metadata' AND \(selector)='source'"+(after ? " AND (\(target),m.id)>(?,?)":"")+" ORDER BY \(target),m.id LIMIT ?"
    }
    static func step(queue:SyncOutgoingWorkQueue,cache:SyncVersionStore,limit:Int)throws->Progress? {
        let db=queue.database
        guard sqlite3_get_autocommit(db.handle)==0,db.handle==cache.database.handle,(1...256).contains(limit) else {throw OSwindError.invalid("Use the owning bounded recording revalidation transaction")}
        guard let (state,before)=try read(db),state.pending else {return nil}
        try RecordingRelationshipIndexes.ensureNames(db)
        let row=try db.statement(query(after:state.cursor != nil));defer {sqlite3_finalize(row)}
        var parameter:Int32=1
        if let cursor=state.cursor {db.bind(row,parameter,cursor.target);parameter+=1;db.bind(row,parameter,cursor.id);parameter+=1}
        sqlite3_bind_int(row,parameter,Int32(limit));var positions=[Cursor](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            try Task.checkCancellation()
            guard sqlite3_column_type(row,0)==SQLITE_TEXT,sqlite3_column_type(row,1)==SQLITE_TEXT else {throw OSwindError.database("Canonical recording revalidation key differs")}
            positions.append(Cursor(target:db.text(row,1),id:db.text(row,0)));code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE else {throw db.error()}
        var identities=[SyncObjectIdentity]()
        for cursor in positions {
            try Task.checkCancellation()
            guard let identity=try cache.catalog.preparedIdentity(.source,primary:[.text(Data(cursor.id.utf8))]) else {continue}
            let heads=try cache.journal.state(for:identity.key)
            if heads.isDeleted || heads.heads.isEmpty {continue}
            var revoked=false
            for head in heads.heads {
                if let content=head.content,try HistoricalErasureSchema.isRevoked(db,.init(identity:identity,content:content)) {revoked=true;break}
            }
            // An evicted old metadata body may not appear in the reverse cache
            // graph. Its separately checked exact affiliation still detects
            // an erased dependency; it never reconstructs that dependency.
            if !revoked,let binding=try RecordingAffiliationStore.read(db,id:cursor.id),binding.owner==identity,let reference=binding.reference {
                revoked=try HistoricalErasureSchema.isRevoked(db,reference)
            }
            if revoked {identities.append(identity)}
        }
        try queue.requeueLive(identities)
        let next=State(nonce:state.nonce,pending:positions.count==limit,cursor:positions.count==limit ? positions.last:nil)
        try replace(db,before:before,with:next)
        return Progress(scanned:positions.count,queued:identities.count)
    }
}
