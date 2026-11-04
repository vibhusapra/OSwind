import Foundation
import CSQLite

/// A session follows its explicit canonical recording ID. An ungrouped clip
/// follows one evidence version, never another source with similar words/time.
public struct RecordingScope:Codable,Equatable,Sendable {
    public enum Selector:String,Codable,Sendable {case session,source,unavailable}
    public let selector:Selector
    public let id:String?,revision:String?
    let session:SyncSessionToken?
    public init(sessionID:String)throws {try self.init(selector:.session,id:sessionID,revision:nil,session:nil)}
    public init(sourceID:String,revision:String)throws {try self.init(selector:.source,id:sourceID,revision:revision,session:nil)}
    public static var unavailable:Self {try! .init(selector:.unavailable,id:nil,revision:nil,session:nil)}
    init(session:SyncSessionToken)throws {try self.init(selector:.session,id:session.localProjection,revision:nil,session:session)}
    private init(selector:Selector,id:String?,revision:String?,session:SyncSessionToken?)throws {
        switch selector {
        case .session:
            guard let id,!id.isEmpty,id.count<=200,revision==nil else {throw OSwindError.invalid("Invalid recording session scope")}
            if let session {try session.validate();guard Data(session.localProjection.utf8)==Data(id.utf8) else {throw OSwindError.invalid("Recording session provenance differs")}}
        case .source:
            guard let id,!id.isEmpty,id.count<200,let revision,!revision.isEmpty,revision.utf8.count<=4096,session==nil else {throw OSwindError.invalid("Invalid recording source scope")}
        case .unavailable:guard id==nil,revision==nil,session==nil else {throw OSwindError.invalid("Unavailable recordings cannot select sources")}
        }
        self.selector=selector;self.id=id;self.revision=revision;self.session=session
    }
    private enum CodingKeys:String,CodingKey {case selector,id,revision,session}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(selector:c.decode(Selector.self,forKey:.selector),id:c.decodeIfPresent(String.self,forKey:.id),revision:c.decodeIfPresent(String.self,forKey:.revision),session:c.decodeIfPresent(SyncSessionToken.self,forKey:.session))
    }
    public static func ==(a:Self,b:Self)->Bool {a.selector==b.selector && a.id.map({Data($0.utf8)})==b.id.map({Data($0.utf8)}) && a.revision==b.revision && a.session==b.session}
    func matches(_ memory:Memory)->Bool {
        guard memory.kind == .audio else {return false}
        switch selector {
        case .session:return memory.audioSessionID.map {Data($0.utf8)}==id.map {Data($0.utf8)}
        case .source:return Data(memory.id.utf8)==Data(id!.utf8) && memory.evidenceHash==revision
        case .unavailable:return false
        }
    }
}
/// Older filters decode kind as a String enum. A typed selector makes them
/// refuse a scoped filter rather than ignore a newly added restriction.
struct RecordingKindSelector:Codable {
    let recordingScopeVersion:Int
    let value:MemoryKind?
    init(_ value:MemoryKind?) {recordingScopeVersion=1;self.value=value}
    func validate()throws {guard recordingScopeVersion==1 else {throw OSwindError.invalid("Unsupported recording scope version")}}
}
enum RecordingScopeSQL {
    static func register(_ db:RoutineDatabase)throws {
        guard sqlite3_create_function_v2(db.handle,"oswind_recording_evidence_v1",1,SQLITE_UTF8|SQLITE_INNOCUOUS|SQLITE_DETERMINISTIC,nil,{context,count,values in
            guard count==1,let value=values?[0],sqlite3_value_bytes(value)>0,Int(sqlite3_value_bytes(value))<=MemoryStore.maximumRecordBytes,let bytes=sqlite3_value_blob(value) else {sqlite3_result_error(context,"Invalid recording source",-1);return}
            do {let memory=try JSONDecoder().decode(Memory.self,from:Data(bytes:bytes,count:Int(sqlite3_value_bytes(value)))),hash=memory.evidenceHash;hash.withCString {sqlite3_result_text(context,$0,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}}
            catch {sqlite3_result_error(context,"Invalid recording source",-1)}
        },nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
}
public extension MemoryStore {
    func recordingScope(for reference:RecordedMeetingSource)throws->RecordingScope {
        let memory=try recordedMeetingEvidence(reference)
        if let session=memory.audioSessionID {return try .init(sessionID:session)}
        return try .init(sourceID:memory.id,revision:memory.evidenceHash)
    }
    func prepareRecordingScope(_ scope:RecordingScope?)throws {
        guard let scope else {return}
        guard scope.selector != .unavailable else {throw OSwindError.unavailable("This recording scope is unavailable. Choose a recording before asking again.")}
        guard scope.selector == .session else {return}
        try withRoutineDatabase {db in
            // A ready cache needs only a read. Do not acquire the single WAL
            // writer slot for every scoped query while capture is inserting.
            let row=try db.statement("SELECT value FROM store_metadata WHERE key='recorded_meeting_index_version'")
            let ready=sqlite3_step(row)==SQLITE_ROW && db.text(row,0)==RecordedMeetingSchema.currentVersion
            sqlite3_finalize(row)
            if ready {return}
            if sqlite3_get_autocommit(db.handle)==0 {try RecordedMeetingSchema.populateIfNeeded(db)}
            else {try db.transaction {try RecordedMeetingSchema.populateIfNeeded(db)}}
        }
    }
    func requireRecordingEvidence(_ hits:[SearchHit],scope:RecordingScope?)throws {
        guard let scope else {return}
        guard scope.selector != .unavailable else {throw OSwindError.unavailable("This recording scope is unavailable")}
        try withRoutineDatabase {db in
            try db.execute("SAVEPOINT recording_evidence")
            defer {try? db.execute("RELEASE recording_evidence")}
            try Task.checkCancellation()
            for hit in hits {
                try Task.checkCancellation()
                guard let current=try get(hit.id),current.evidenceHash==hit.memory.evidenceHash,scope.matches(current) else {throw OSwindError.unavailable("Recording evidence changed or left the selected recording. Refresh before asking again.")}
            }
        }
    }
}
