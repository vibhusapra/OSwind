import Foundation
import CryptoKit
import CSQLite

/// Repeated permitted observations of the same text. The interval between
/// samples is unobserved; this is neither attention nor continuous activity.
public struct TextObservationSpan:Codable,Equatable,Sendable {
    public let version:Int
    public let sessionID:String
    public let samples:Int
    public let largestGapSeconds:Double
    public static let maximumDuration:Double=900
    public static let maximumGap:Double=120
    public static let maximumSamples=1000
    public init(sessionID:String=UUID().uuidString,samples:Int=1,largestGapSeconds:Double=0) {
        version=1;self.sessionID=sessionID;self.samples=samples;self.largestGapSeconds=largestGapSeconds
    }
    func validated(for memory:Memory) throws {
        let duration=(memory.endTimestamp ?? memory.timestamp).timeIntervalSince(memory.timestamp)
        guard version==1,UUID(uuidString:sessionID) != nil,(1...Self.maximumSamples).contains(samples),
              largestGapSeconds.isFinite,largestGapSeconds>=0,largestGapSeconds<=Self.maximumGap,
              memory.timestamp.timeIntervalSince1970.isFinite,duration.isFinite,duration>=0,duration<=Self.maximumDuration,
              samples==1 ? (duration==0 && largestGapSeconds==0):(duration>0 && largestGapSeconds>0 && largestGapSeconds<=duration+0.000001 && duration<=Double(samples-1)*largestGapSeconds+0.000001),
              memory.kind == .screen,memory.display==AccessibilityCaptureRecord.display,
              memory.imagePath==nil,memory.audioPath==nil,memory.videoPath==nil,memory.visualRecording==nil,
              memory.transcript==nil,memory.audioSessionID==nil,memory.recap==nil,memory.regions.isEmpty,
              memory.text.count<=16000,memory.text.utf8.count<=65536 else {throw OSwindError.invalid("Invalid sampled text observation span")}
    }
    public func evidenceDescription(for memory:Memory)->String {
        let first=memory.timestamp.formatted(.iso8601),last=(memory.endTimestamp ?? memory.timestamp).formatted(.iso8601)
        return "Sampled text: \(samples) observation\(samples==1 ? "":"s") from \(first) to \(last); largest observed gap \(largestGapSeconds.formatted(.number.precision(.fractionLength(1)))) s. Gaps are unobserved; this does not establish continuous presence, attention or time spent."
    }
}

struct TextObservationCursor:Sendable {
    let id:String,digest:Data,binding:Data,first:Date,last:Date,uptime:Double,span:TextObservationSpan
    func canContinue(digest:Data,binding:Data,at date:Date,uptime now:Double,gapLimit:Double)->Bool {
        let elapsed=date.timeIntervalSince(last),monotonic=now-uptime,total=date.timeIntervalSince(first)
        return self.digest==digest && self.binding==binding && elapsed.isFinite && monotonic.isFinite &&
            elapsed>0 && monotonic>0 && abs(elapsed-monotonic)<=2 && elapsed<=gapLimit && elapsed<=TextObservationSpan.maximumGap &&
            total<=TextObservationSpan.maximumDuration && span.samples<TextObservationSpan.maximumSamples
    }
    func matches(_ memory:Memory)throws->Bool {
        guard memory.id==id,memory.timestamp==first,(memory.endTimestamp ?? memory.timestamp)==last,memory.textObservation==span else {return false}
        try span.validated(for:memory)
        return try AccessibilityCaptureRecord.digest(memory)==digest
    }
    static func binding(_ context:WindowContext)throws->Data {
        // Retain only a digest, not a second raw title/URL/AX-body cache.
        let bounds=context.bounds.map {[Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)].map {String($0.bitPattern)}} ?? []
        return Data(SHA256.hash(data:try JSONEncoder().encode([context.bundle,String(context.pid),context.title,context.url ?? ""]+bounds)))
    }
}
struct PreparedTextObservation:Sendable {
    var memory:Memory
    let digest:Data,binding:Data
    let continuation:TextObservationCursor?
}

/// Sparse, rebuildable time-range projection. Ordinary point sources retain
/// their existing indexed timestamp path; search never scans source JSON.
enum TextObservationSchema {
    private static let valid="""
    new.kind='screen' AND length(new.payload)<=262144
    AND json_extract(CAST(new.payload AS TEXT),'$.display')='accessibility-window'
    AND json_extract(CAST(new.payload AS TEXT),'$.textObservation.version')=1
    AND json_type(CAST(new.payload AS TEXT),'$.endTimestamp') IN ('real','integer')
    AND json_extract(CAST(new.payload AS TEXT),'$.endTimestamp')+978307200>=new.timestamp
    AND json_extract(CAST(new.payload AS TEXT),'$.endTimestamp')+978307200<=new.timestamp+900
    """
    private static let fill="""
    INSERT INTO text_observation_ranges(memory_id,last_observed)
    SELECT new.id,json_extract(CAST(new.payload AS TEXT),'$.endTimestamp')+978307200 WHERE \(valid);
    """
    static let triggers:[String:String]=[
        "text_observation_insert":"CREATE TRIGGER text_observation_insert AFTER INSERT ON memories BEGIN \(fill) END",
        "text_observation_update":"CREATE TRIGGER text_observation_update AFTER UPDATE OF id,payload,timestamp,kind ON memories BEGIN DELETE FROM text_observation_ranges WHERE memory_id=old.id; \(fill) END",
        "text_observation_revision":"""
        CREATE TRIGGER text_observation_revision BEFORE UPDATE OF payload ON memories
        WHEN (json_type(CAST(old.payload AS TEXT),'$.textObservation')='object' OR json_type(CAST(new.payload AS TEXT),'$.textObservation')='object') AND (
            json_extract(CAST(old.payload AS TEXT),'$.endTimestamp') IS NOT json_extract(CAST(new.payload AS TEXT),'$.endTimestamp') OR
            json_extract(CAST(old.payload AS TEXT),'$.textObservation.version') IS NOT json_extract(CAST(new.payload AS TEXT),'$.textObservation.version') OR
            json_extract(CAST(old.payload AS TEXT),'$.textObservation.sessionID') IS NOT json_extract(CAST(new.payload AS TEXT),'$.textObservation.sessionID') OR
            json_extract(CAST(old.payload AS TEXT),'$.textObservation.samples') IS NOT json_extract(CAST(new.payload AS TEXT),'$.textObservation.samples') OR
            json_extract(CAST(old.payload AS TEXT),'$.textObservation.largestGapSeconds') IS NOT json_extract(CAST(new.payload AS TEXT),'$.textObservation.largestGapSeconds'))
        BEGIN
            UPDATE chat_sessions SET title='Conversation' WHERE id IN (SELECT t.session_id FROM chat_turns t JOIN chat_sources s ON s.turn_id=t.id WHERE s.memory_id=old.id);
            DELETE FROM chat_turns WHERE id IN (SELECT turn_id FROM chat_sources WHERE memory_id=old.id);
            DELETE FROM memories WHERE id IN (\(RecapSchema.descendants("old.id")));
        END
        """
    ]
    static func install(_ db:RoutineDatabase,sourceVersion:Int32)throws {
        try Task.checkCancellation()
        let table=try db.statement("SELECT 1 FROM sqlite_master WHERE type='table' AND name='text_observation_ranges'")
        let existed=sqlite3_step(table)==SQLITE_ROW;sqlite3_finalize(table)
        try db.execute("CREATE TABLE IF NOT EXISTS text_observation_ranges(memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,last_observed REAL NOT NULL) WITHOUT ROWID; CREATE INDEX IF NOT EXISTS text_observation_end ON text_observation_ranges(last_observed,memory_id)")
        var current=existed
        for name in triggers.keys.sorted() {
            let row=try db.statement("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?");db.bind(row,1,name)
            if sqlite3_step(row) != SQLITE_ROW || db.text(row,0).trimmingCharacters(in:.whitespacesAndNewlines) != triggers[name]! {current=false}
            sqlite3_finalize(row)
        }
        guard !current else {return}
        sqlite3_progress_handler(db.handle,1000,{_ in Task.isCancelled ? 1:0},nil);defer {sqlite3_progress_handler(db.handle,0,nil,nil)}
        do {
            // Supported pre24 writers cannot encode textObservation. Install
            // their empty projection without reading every source payload.
            // Existing/new-format cache repair still rebuilds from sources.
            if existed || sourceVersion>=24 {try db.execute("DELETE FROM text_observation_ranges; "+fill.replacingOccurrences(of:" WHERE ",with:" FROM memories new WHERE "))}
            for name in triggers.keys.sorted() {try db.execute("DROP TRIGGER IF EXISTS \(name)");try db.execute(triggers[name]!)}
            try Task.checkCancellation()
        } catch {if Task.isCancelled {throw CancellationError()};throw error}
    }
}
