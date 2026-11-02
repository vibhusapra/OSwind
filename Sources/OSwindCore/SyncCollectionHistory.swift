import Foundation
import CSQLite

/// Internal creation-era capture for collection erasure. Installing this ledger
/// does not enable synchronization or make a collection control an approved peer
/// operation. The journal/transport/admission integration must still be completed.
/// Clocks here count collection wipes, independently of journal operation dots.
struct SyncCollectionHistory {
    let database:RoutineDatabase
    let replica:String
    // Generic control receipt is not proof of full native retirement. Every
    // newly observed frontier invalidates the previous native completion.
    static let nativeCompletionKey="sync-native-collection-completion-v1"

    private static let clockSQL="(SELECT CAST('{'||COALESCE(group_concat('\"'||replica||'\":'||counter,','),'')||'}' AS BLOB) FROM (SELECT replica,counter FROM personal_sync_collection_frontier ORDER BY replica))"
    private static let blobCheck="typeof(era)='blob' AND length(era)>=2 AND length(era)<=1048576"
    private static let schemas:[String:String]=[
        "personal_sync_collection_local":"CREATE TABLE personal_sync_collection_local(singleton INTEGER PRIMARY KEY CHECK(singleton=1),replica TEXT NOT NULL,counter INTEGER NOT NULL CHECK(typeof(counter)='integer' AND counter>=0))",
        "personal_sync_collection_frontier":"CREATE TABLE personal_sync_collection_frontier(replica TEXT PRIMARY KEY,counter INTEGER NOT NULL CHECK(typeof(counter)='integer' AND counter>0))",
        "personal_sync_collection_controls":"CREATE TABLE personal_sync_collection_controls(counter INTEGER PRIMARY KEY CHECK(counter>0),era BLOB NOT NULL CHECK(\(blobCheck)))",
        "personal_sync_collection_births":"CREATE TABLE personal_sync_collection_births(table_name TEXT NOT NULL,key_digest BLOB NOT NULL CHECK(typeof(key_digest)='blob' AND length(key_digest)=32),era BLOB NOT NULL CHECK(\(blobCheck)),PRIMARY KEY(table_name,key_digest))",
        "personal_sync_collection_changes":"CREATE TABLE personal_sync_collection_changes(sequence INTEGER PRIMARY KEY CHECK(sequence>0),era BLOB NOT NULL CHECK(\(blobCheck)))",
        "personal_sync_collection_objects":"CREATE TABLE personal_sync_collection_objects(kind TEXT NOT NULL,digest TEXT NOT NULL,era BLOB NOT NULL CHECK(\(blobCheck)),PRIMARY KEY(kind,digest))",
        "personal_sync_collection_approvals":"CREATE TABLE personal_sync_collection_approvals(counter INTEGER PRIMARY KEY CHECK(counter>0),group_id TEXT NOT NULL,epoch TEXT NOT NULL,digest TEXT NOT NULL CHECK(length(digest)=64),control BLOB NOT NULL CHECK(typeof(control)='blob' AND length(control)>0 AND length(control)<=65536))",
        "personal_sync_collection_received_controls":"CREATE TABLE personal_sync_collection_received_controls(replica TEXT NOT NULL,counter INTEGER NOT NULL CHECK(typeof(counter)='integer' AND counter>0),digest TEXT NOT NULL CHECK(length(digest)=64),control BLOB NOT NULL CHECK(typeof(control)='blob' AND length(control)>0 AND length(control)<=65536),PRIMARY KEY(replica,counter))"
    ]

    static func install(_ db:RoutineDatabase,replica:String)throws->Self {
        try SyncProtocolLimits.uuid(replica)
        return try SyncChangeCapture.transaction(db) {
            let present=try db.statement("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'personal_sync_collection_%'")
            var installed=Set<String>(),code=sqlite3_step(present)
            while code==SQLITE_ROW {installed.insert(db.text(present,0));code=sqlite3_step(present)};sqlite3_finalize(present)
            guard code==SQLITE_DONE,installed.isEmpty || installed==Set(schemas.keys) else {throw OSwindError.database("Collection history schema is incomplete; preserve its state")}
            let fresh=installed.isEmpty
            for (name,sql) in schemas.sorted(by:{$0.key<$1.key}) {try require(db,name:name,sql:sql,allowCreate:fresh)}
            if fresh {
                let row=try db.statement("INSERT INTO personal_sync_collection_local VALUES(1,?,0)");defer {sqlite3_finalize(row)}
                db.bind(row,1,replica);try db.done(row)
            }
            let native=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_capture','personal_sync_changes')");defer {sqlite3_finalize(native)}
            guard sqlite3_step(native)==SQLITE_ROW else {throw db.error()}
            let nativeCount=sqlite3_column_int(native,0)
            guard nativeCount==0 || nativeCount==2 else {throw OSwindError.database("Native collection capture schema is incomplete")}
            if nativeCount==2 {for (name,sql) in triggers.sorted(by:{$0.key<$1.key}) {try require(db,name:name,sql:sql,allowCreate:fresh)}}
            let value=Self(database:db,replica:replica);_ = try value.current();return value
        }
    }

    private static func require(_ db:RoutineDatabase,name:String,sql:String,allowCreate:Bool)throws {
        let row=try db.statement("SELECT sql FROM sqlite_master WHERE name=?");defer {sqlite3_finalize(row)};db.bind(row,1,name)
        let code=sqlite3_step(row)
        if code==SQLITE_ROW {guard db.text(row,0)==sql else {throw OSwindError.database("Collection history schema differs; preserve its state")}}
        else if code==SQLITE_DONE && allowCreate {try db.execute(sql)}
        else {throw OSwindError.database("Collection history schema member is missing; preserve its state")}
    }

    /// A dropped derived pin table also drops its two birth hooks. Ordinary
    /// opening may restore only those hooks in the existing pin-repair
    /// transaction. Recovered rows must use the retained birth/claim metadata,
    /// so call this after reconstruction rather than restamping their births.
    static func repairMissingPinTriggers(_ db:RoutineDatabase)throws {
        let count=try db.eraseCount("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE 'personal_sync_collection_%'")
        guard count>0 else {return}
        guard count==schemas.count,sqlite3_get_autocommit(db.handle)==0 else {throw OSwindError.database("Preserve incomplete collection history during pin repair")}
        let allowed=Set(["insert","update"].map {"sync_collection_birth_text_observation_pins_"+$0})
        for (name,sql) in schemas {try require(db,name:name,sql:sql,allowCreate:false)}
        for (name,sql) in triggers where !allowed.contains(name) {try require(db,name:name,sql:sql,allowCreate:false)}
        for name in allowed {try require(db,name:name,sql:triggers[name]!,allowCreate:true)}
        _=try ifInstalled(db)
    }

    static func ifInstalled(_ db:RoutineDatabase)throws->Self? {
        let exists=try db.statement("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='personal_sync_collection_local'");defer {sqlite3_finalize(exists)}
        guard sqlite3_step(exists)==SQLITE_ROW else {throw db.error()};if sqlite3_column_int(exists,0)==0 {return nil}
        let row=try db.statement("SELECT replica FROM personal_sync_collection_local WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Collection history identity is missing")}
        let replica=db.text(row,0);try SyncProtocolLimits.uuid(replica)
        let value=Self(database:db,replica:replica);_ = try value.current();return value
    }

    func objectEra(_ key:SyncObjectKey)throws->SyncClock? {
        _=try identity();let row=try database.statement("SELECT era FROM personal_sync_collection_objects WHERE kind=? AND digest=?");defer {sqlite3_finalize(row)}
        database.bind(row,1,key.kind.rawValue);database.bind(row,2,key.digest)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()};return try decode(row,0)
    }
    func admittedEra(_ key:SyncObjectKey)throws->SyncClock {
        _=try identity();let row=try database.statement("SELECT state FROM personal_sync_registers WHERE kind=? AND digest=?");defer {sqlite3_finalize(row)}
        database.bind(row,1,key.kind.rawValue);database.bind(row,2,key.digest)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return .empty}
        let size=Int(sqlite3_column_bytes(row,0))
        guard code==SQLITE_ROW,sqlite3_column_type(row,0)==SQLITE_BLOB,(1...SyncProtocolLimits.stateBytes).contains(size),let p=sqlite3_column_blob(row,0) else {throw OSwindError.invalid("Invalid admitted collection lifetime")}
        let state=try SyncRegister.decode(Data(bytes:p,count:size))
        guard state.key==key,!state.isDeleted else {throw OSwindError.invalid("A retired collection lifetime cannot project native content")}
        return state.preferred?.creationEra ?? .empty
    }
    func hasLegacyIdentity(_ key:SyncObjectKey)throws->Bool {
        let exists=try database.statement("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='personal_sync_identities'");defer {sqlite3_finalize(exists)}
        guard sqlite3_step(exists)==SQLITE_ROW else {throw database.error()};if sqlite3_column_int(exists,0)==0 {return false}
        let row=try database.statement("SELECT EXISTS(SELECT 1 FROM personal_sync_identities WHERE object_digest=?)");defer {sqlite3_finalize(row)};database.bind(row,1,key.digest)
        guard sqlite3_step(row)==SQLITE_ROW else {throw database.error()};return sqlite3_column_int(row,0)==1
    }
    /// Share the identity/queue transaction, before its raw claim is consumed.
    /// An existing lifetime's era is immutable; a later edit cannot renew it.
    func recordObject(_ key:SyncObjectKey,era:SyncClock)throws {
        guard sqlite3_get_autocommit(database.handle)==0,try current().covers(era) else {throw OSwindError.invalid("Record an observed creation era in its identity transaction")}
        if let previous=try objectEra(key) {guard previous==era else {throw OSwindError.invalid("A sync lifetime cannot change its creation era")};return}
        let bytes=try SyncProtocolLimits.encode(era),row=try database.statement("INSERT INTO personal_sync_collection_objects(kind,digest,era) VALUES(?,?,?)");defer {sqlite3_finalize(row)}
        database.bind(row,1,key.kind.rawValue);database.bind(row,2,key.digest);bytes.withUnsafeBytes {_=sqlite3_bind_blob(row,3,$0.baseAddress,Int32(bytes.count),database.transient)};try database.done(row)
    }
    func recordPeerBirth(_ key:SyncObjectKey,table:String,nativeKey:Data,era:SyncClock)throws {
        try recordObject(key,era:era)
        guard SyncChangeCapture.tables.contains(where:{$0.name==table}),nativeKey.count==32 else {throw OSwindError.invalid("Invalid peer native birth key")}
        let bytes=try SyncProtocolLimits.encode(era),row=try database.statement("INSERT INTO personal_sync_collection_births(table_name,key_digest,era) VALUES(?,?,?) ON CONFLICT(table_name,key_digest) DO UPDATE SET era=excluded.era");defer {sqlite3_finalize(row)}
        database.bind(row,1,table);nativeKey.withUnsafeBytes {_=sqlite3_bind_blob(row,2,$0.baseAddress,Int32(nativeKey.count),database.transient)}
        bytes.withUnsafeBytes {_=sqlite3_bind_blob(row,3,$0.baseAddress,Int32(bytes.count),database.transient)};try database.done(row)
    }

    private static let triggers:[String:String] = {
        var result=[String:String]()
        let active="(SELECT enabled=1 AND suppressed=0 FROM personal_sync_capture WHERE singleton=1)"
        for table in SyncChangeCapture.tables {
            let key=table.snapshot("new",true)
            // BEFORE INSERT also runs for an upsert. Existing native keys keep
            // their birth era, including keys predating ledger installation.
            let absent="NOT EXISTS(SELECT 1 FROM \(table.name) WHERE \(table.snapshot(table.name,true))=\(key))"
            for operation in ["insert","update"] {
                let name="sync_collection_birth_\(table.name)_\(operation)"
                let changed=operation=="insert" ? absent:"\(table.snapshot("old",true))!=\(key)"
                result[name]="CREATE TRIGGER \(name) BEFORE \(operation.uppercased()) ON \(table.name) WHEN \(active) AND \(changed) BEGIN INSERT INTO personal_sync_collection_births(table_name,key_digest,era) VALUES('\(table.name)',\(key),\(clockSQL)) ON CONFLICT(table_name,key_digest) DO UPDATE SET era=excluded.era; END"
            }
        }
        result["sync_collection_capture_era"]="CREATE TRIGGER sync_collection_capture_era AFTER INSERT ON personal_sync_changes WHEN new.after_row IS NOT NULL BEGIN INSERT INTO personal_sync_collection_changes(sequence,era) VALUES(new.seq,COALESCE((SELECT era FROM personal_sync_collection_births WHERE table_name=new.table_name AND key_digest=new.after_key),CAST('{}' AS BLOB))); END"
        result["sync_collection_capture_removed"]="CREATE TRIGGER sync_collection_capture_removed AFTER DELETE ON personal_sync_changes BEGIN DELETE FROM personal_sync_collection_changes WHERE sequence=old.seq; END"
        result["sync_collection_frontier_bound"]="CREATE TRIGGER sync_collection_frontier_bound BEFORE INSERT ON personal_sync_collection_frontier WHEN NOT EXISTS(SELECT 1 FROM personal_sync_collection_frontier WHERE replica=new.replica) BEGIN SELECT CASE WHEN (SELECT COUNT(*) FROM personal_sync_collection_frontier)>=64 THEN RAISE(ABORT,'Collection frontier exceeds peer bound') END; END"
        for operation in ["insert","update"] {
            let name="sync_collection_native_wipe_"+operation
            // Pure SQL runs in the actual native wipe transaction, including a
            // supported older writing connection. No delayed processor stamps
            // the event with a newer frontier. Retry-cleanup does not set this
            // marker and therefore does not manufacture an additional wipe.
            result[name]="CREATE TRIGGER \(name) AFTER \(operation.uppercased()) ON store_metadata WHEN new.key='library_wipe_dirty' AND new.value='1' BEGIN SELECT CASE WHEN (SELECT counter FROM personal_sync_collection_local WHERE singleton=1)=9223372036854775807 THEN RAISE(ABORT,'Collection wipe sequence exhausted') END; UPDATE personal_sync_collection_local SET counter=counter+1 WHERE singleton=1; INSERT INTO personal_sync_collection_frontier(replica,counter) SELECT replica,counter FROM personal_sync_collection_local WHERE singleton=1 ON CONFLICT(replica) DO UPDATE SET counter=excluded.counter; INSERT INTO personal_sync_collection_controls(counter,era) SELECT counter,\(clockSQL) FROM personal_sync_collection_local WHERE singleton=1; END"
        }
        return result
    }()

    private func identity()throws->Int64 {
        let row=try database.statement("SELECT replica,counter FROM personal_sync_collection_local WHERE singleton=1");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW,database.text(row,0)==replica,sqlite3_column_type(row,1)==SQLITE_INTEGER,sqlite3_column_int64(row,1)>=0 else {throw OSwindError.invalid("Collection history identity differs")}
        let native=try database.statement("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('personal_sync_capture','personal_sync_changes')");defer {sqlite3_finalize(native)}
        guard sqlite3_step(native)==SQLITE_ROW else {throw database.error()}
        let count=sqlite3_column_int(native,0)
        guard count==0 || count==2 else {throw OSwindError.invalid("Native collection capture schema is incomplete")}
        // The generic vector-index identity also changes on ordinary deletions.
        // Validate the actual wipe hooks instead of mistaking those changes for
        // collection erasure. Never silently reinstall a damaged active hook.
        if count==2 {
            for (name,sql) in Self.triggers where name.hasPrefix("sync_collection_native_wipe_") {
                try Self.require(database,name:name,sql:sql,allowCreate:false)
            }
        }
        return sqlite3_column_int64(row,1)
    }
    private func decode(_ row:OpaquePointer,_ column:Int32)throws->SyncClock {
        let size=Int(sqlite3_column_bytes(row,column))
        guard sqlite3_column_type(row,column)==SQLITE_BLOB,(2...SyncProtocolLimits.stateBytes).contains(size),let p=sqlite3_column_blob(row,column) else {throw OSwindError.invalid("Invalid collection era storage")}
        let data=Data(bytes:p,count:size),clock=try JSONDecoder().decode(SyncClock.self,from:data)
        guard try SyncProtocolLimits.encode(clock)==data else {throw OSwindError.invalid("Noncanonical collection era")};return clock
    }
    func current()throws->SyncClock {
        let counter=try identity(),row=try database.statement("SELECT \(Self.clockSQL)");defer {sqlite3_finalize(row)}
        guard sqlite3_step(row)==SQLITE_ROW else {throw database.error()};let clock=try decode(row,0)
        guard clock[replica]==counter else {throw OSwindError.invalid("Collection frontier differs from its local wipe sequence")}
        let unknown=try database.statement("SELECT COUNT(*) FROM personal_sync_collection_frontier f LEFT JOIN personal_sync_peers p ON p.replica=f.replica WHERE p.replica IS NULL");defer {sqlite3_finalize(unknown)}
        guard sqlite3_step(unknown)==SQLITE_ROW,sqlite3_column_int(unknown,0)==0 else {throw OSwindError.invalid("Collection frontier names an unenrolled peer")}
        return clock
    }
    /// Nil is an unstamped legacy lifetime, not proof of a fresh creation.
    func birth(table:String,key:Data)throws->SyncClock? {
        _=try identity();guard SyncChangeCapture.tables.contains(where:{$0.name==table}),key.count==32 else {throw OSwindError.invalid("Invalid collection birth key")}
        let row=try database.statement("SELECT era FROM personal_sync_collection_births WHERE table_name=? AND key_digest=?");defer {sqlite3_finalize(row)};database.bind(row,1,table)
        key.withUnsafeBytes {_=sqlite3_bind_blob(row,2,$0.baseAddress,Int32(key.count),database.transient)}
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()};return try decode(row,0)
    }
    func captured(sequence:Int64)throws->SyncClock? {
        _=try identity();guard sequence>0 else {throw OSwindError.invalid("Invalid collection capture sequence")}
        let row=try database.statement("SELECT era FROM personal_sync_collection_changes WHERE sequence=?");defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,sequence)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()};return try decode(row,0)
    }
    func pendingWipes(limit:Int=128)throws->[(counter:Int64,era:SyncClock)] {
        let frontier=try current();guard (1...256).contains(limit) else {throw OSwindError.invalid("Invalid collection control read bound")}
        let row=try database.statement("SELECT counter,era FROM personal_sync_collection_controls ORDER BY counter LIMIT ?");defer {sqlite3_finalize(row)};sqlite3_bind_int(row,1,Int32(limit))
        var values=[(counter:Int64,era:SyncClock)](),code=sqlite3_step(row)
        while code==SQLITE_ROW {
            let counter=sqlite3_column_int64(row,0),era=try decode(row,1)
            guard sqlite3_column_type(row,0)==SQLITE_INTEGER,counter>0,era[replica]==counter,frontier.covers(era) else {throw OSwindError.invalid("Collection control differs from its recorded frontier")}
            values.append((counter,era));code=sqlite3_step(row)
        }
        guard code==SQLITE_DONE else {throw database.error()};return values
    }

    private func requireJournal(_ journal:SyncJournal)throws {
        guard journal.database.handle==database.handle,journal.replica==replica,try journal.cursor(for:replica) != nil else {throw OSwindError.invalid("Collection review belongs to another owning journal")}
    }
    private func controlBytes(_ row:OpaquePointer,_ column:Int32)throws->Data {
        let size=Int(sqlite3_column_bytes(row,column))
        guard sqlite3_column_type(row,column)==SQLITE_BLOB,(1...SyncProtocolLimits.operationBytes).contains(size),let p=sqlite3_column_blob(row,column) else {throw OSwindError.invalid("Invalid collection control storage")}
        return Data(bytes:p,count:size)
    }
    private func capturedControl(_ counter:Int64,journal:SyncJournal)throws->SyncCollectionControl {
        try requireJournal(journal)
        let row=try database.statement("SELECT era FROM personal_sync_collection_controls WHERE counter=?");defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,counter)
        guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.invalid("Captured native wipe control is missing")}
        return try .init(group:journal.group,epoch:journal.epoch,creator:replica,counter:counter,era:decode(row,0))
    }
    private func approvedControl(_ counter:Int64,journal:SyncJournal)throws->SyncCollectionControl? {
        let row=try database.statement("SELECT group_id,epoch,digest,control FROM personal_sync_collection_approvals WHERE counter=?");defer {sqlite3_finalize(row)};sqlite3_bind_int64(row,1,counter)
        let code=sqlite3_step(row);if code==SQLITE_DONE {return nil};guard code==SQLITE_ROW else {throw database.error()}
        let control=try SyncCollectionControl.decode(controlBytes(row,3))
        guard database.text(row,0)==journal.group,database.text(row,1)==journal.epoch,try database.text(row,2)==control.digest,try control==capturedControl(counter,journal:journal) else {throw OSwindError.invalid("Group review differs from the captured wipe or trusted epoch")}
        return control
    }
    func reviewState(journal:SyncJournal)throws->SyncCollectionReview {
        try requireJournal(journal);let latest=try identity()
        guard latest>0 else {return .ready}
        let control=try capturedControl(latest,journal:journal)
        return try approvedControl(latest,journal:journal)==nil ? .needsGroupReview(control):.ready
    }
    /// Called only for an explicit reviewed group action. Native wipe capture
    /// never calls this, and no transport path automatically approves a frame.
    @discardableResult func approveGroupErase(journal:SyncJournal,counter:Int64,expectedEra:SyncClock)throws->SyncCollectionControl {
        try SyncChangeCapture.transaction(database) {
            try requireJournal(journal)
            guard try identity()==counter,counter>0 else {throw OSwindError.invalid("The local wipe changed after review; review its current group cutoff")}
            let control=try capturedControl(counter,journal:journal)
            guard control.era==expectedEra else {throw OSwindError.invalid("The captured wipe differs from the reviewed cutoff")}
            let bytes=try control.encoded(),row=try database.statement("INSERT INTO personal_sync_collection_approvals VALUES(?,?,?,?,?) ON CONFLICT(counter) DO NOTHING");defer {sqlite3_finalize(row)}
            sqlite3_bind_int64(row,1,counter);database.bind(row,2,journal.group);database.bind(row,3,journal.epoch);database.bind(row,4,try control.digest)
            bytes.withUnsafeBytes {_=sqlite3_bind_blob(row,5,$0.baseAddress,Int32(bytes.count),database.transient)};try database.done(row)
            guard try approvedControl(counter,journal:journal)==control else {throw OSwindError.invalid("The group review could not be retained")};return control
        }
    }
    /// At most one exact authenticated/approved control per enrolled frontier
    /// axis. A raw manually injected frontier cannot authorize publication.
    func knownControls(journal:SyncJournal)throws->[SyncCollectionControl] {
        try requireJournal(journal)
        guard try reviewState(journal:journal) == .ready else {throw OSwindError.unavailable("Review the local wipe before exporting any sync objects")}
        let frontier=try current();var controls=[SyncCollectionControl]()
        for (peer,counter) in frontier.counters.sorted(by:{$0.key<$1.key}) {
            if peer==replica {
                guard let control=try approvedControl(counter,journal:journal) else {throw OSwindError.unavailable("Group erasure has not been approved")};controls.append(control)
            } else {
                let row=try database.statement("SELECT digest,control FROM personal_sync_collection_received_controls WHERE replica=? AND counter=?");defer {sqlite3_finalize(row)}
                database.bind(row,1,peer);sqlite3_bind_int64(row,2,counter)
                guard sqlite3_step(row)==SQLITE_ROW else {throw OSwindError.unavailable("The observed frontier has no authenticated collection control")}
                let control=try SyncCollectionControl.decode(controlBytes(row,1))
                guard control.group==journal.group,control.epoch==journal.epoch,control.creator==peer,control.counter==counter,try database.text(row,0)==control.digest else {throw OSwindError.invalid("Received collection control differs from its trusted frontier")};controls.append(control)
            }
        }
        return controls
    }
    /// The owning receiver authenticates the encrypted control first. Only its
    /// creator's counter advances; claimed foreign context is not independent
    /// evidence that those other devices' erasures have been observed.
    @discardableResult func observeVerifiedGroupControl(_ control:SyncCollectionControl,journal:SyncJournal,retire:(SyncClock)throws->Void)throws->Bool {
        try SyncChangeCapture.transaction(database) {
            try requireJournal(journal)
            guard control.group==journal.group,control.epoch==journal.epoch,try journal.cursor(for:control.creator) != nil else {throw OSwindError.invalid("Collection control belongs to an unenrolled peer or different epoch")}
            for peer in control.era.counters.keys {guard try journal.cursor(for:peer) != nil else {throw OSwindError.invalid("Collection control names an unenrolled peer")}}
            if control.creator==replica {guard try approvedControl(control.counter,journal:journal)==control else {throw OSwindError.invalid("Another writer attempted to approve this device's local wipe")}}
            let bytes=try control.encoded(),digest=try control.digest
            let prior=try database.statement("SELECT digest,control FROM personal_sync_collection_received_controls WHERE replica=? AND counter=?");defer {sqlite3_finalize(prior)}
            database.bind(prior,1,control.creator);sqlite3_bind_int64(prior,2,control.counter)
            let code=sqlite3_step(prior)
            if code==SQLITE_ROW {guard database.text(prior,0)==digest,try controlBytes(prior,1)==bytes else {throw OSwindError.invalid("A collection writer forked its recorded wipe identity")};return false}
            guard code==SQLITE_DONE else {throw database.error()}
            let insert=try database.statement("INSERT INTO personal_sync_collection_received_controls VALUES(?,?,?,?)");defer {sqlite3_finalize(insert)}
            database.bind(insert,1,control.creator);sqlite3_bind_int64(insert,2,control.counter);database.bind(insert,3,digest)
            bytes.withUnsafeBytes {_=sqlite3_bind_blob(insert,4,$0.baseAddress,Int32(bytes.count),database.transient)};try database.done(insert)
            let before=try current()
            guard control.counter>before[control.creator] else {return false}
            let update=try database.statement("INSERT INTO personal_sync_collection_frontier VALUES(?,?) ON CONFLICT(replica) DO UPDATE SET counter=excluded.counter");defer {sqlite3_finalize(update)}
            database.bind(update,1,control.creator);sqlite3_bind_int64(update,2,control.counter);try database.done(update)
            try database.execute("DELETE FROM store_metadata WHERE key='\(Self.nativeCompletionKey)'")
            try retire(current());return true
        }
    }
}
