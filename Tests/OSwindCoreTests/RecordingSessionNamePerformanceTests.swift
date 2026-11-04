import XCTest
import CSQLite
@testable import OSwindCore

/// Opt-in authored lookup measurements, not UI frames, energy or competition.
final class RecordingSessionNamePerformanceTests:XCTestCase {
    private final class Counter {
        var statements=0
    }
    private struct Observation:Codable {let iteration:Int,warmup:Bool,seconds:Double}
    private struct CaseResult:Codable {let name:String,expectedNames:Int,statementCount:Int,observations:[Observation]}
    func testOwnedSessionNameLookupCostAtDifferentDensities()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_SESSION_NAME_BENCH_DIR"] else {throw XCTSkip("Explicit fresh owned session-name benchmark output required")}
        let output=URL(fileURLWithPath:path),fm=FileManager.default
        guard output.path==path,output.standardizedFileURL.path==path,output.resolvingSymlinksInPath().path==path,!fm.fileExists(atPath:path),fm.fileExists(atPath:output.deletingLastPathComponent().path) else {throw OSwindError.invalid("Use a fresh absolute owned session-name benchmark directory")}
        try fm.createDirectory(at:output,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try Data("OSwind authored session name lookup v1".utf8).write(to:output.appendingPathComponent("owned-fixture"),options:.withoutOverwriting)
        let store=try MemoryStore(root:output.appendingPathComponent("library"));defer {try? store.close()}
        let count=5000,text=String(repeating:"Authored benchmark text without microphone or ASR. ",count:80)
        try store.withRoutineDatabase {db in try db.transaction {
            for index in 0..<count {
                var value=Memory(id:"lookup-audio-\(index)",timestamp:Date(timeIntervalSince1970:Double(index)),kind:.audio,app:"Owned",title:"Authored capture",text:text)
                value.audioSessionID="lookup-session-\(index)";try store.insert(value)
            }
        }}
        let sources=try store.recordedMeetingPage().sources;XCTAssertEqual(sources.count,512)
        func insertLabel(_ index:Int)throws {
            var value=Memory(id:"lookup-name-\(index)",kind:.recordingMetadata,app:"OSwind",bundleID:"com.oswind.desktop",title:"Authored name \(index)",text:"User-authored benchmark label")
            value.recordingDetails = .init(scope:try .init(sessionID:"lookup-session-\(index)"));try store.insert(value)
        }
        var results=[CaseResult]()
        func measure(_ name:String,expected:Int)throws {
            let revision=try store.recordedMeetingRevision()
            try store.withRoutineDatabase {db in
                sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                    if [SQLITE_INSERT,SQLITE_UPDATE,SQLITE_DELETE].contains(action) {return SQLITE_DENY}
                    if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY};return SQLITE_OK
                },nil)
            }
            defer {_ = try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)}}
            var observations=[Observation]()
            for iteration in 0..<25 {
                let started=ContinuousClock.now,values=try store.recordedMeetingSessionNames(for:sources,at:revision),elapsed=started.duration(to:.now).components
                observations.append(.init(iteration:iteration,warmup:iteration<2,seconds:Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18))
                XCTAssertEqual(values.count,expected);XCTAssertTrue(values.values.allSatisfy {!$0.hasConflicts && $0.name != nil})
            }
            // Count separately: the trace hook is excluded from all timings.
            let counter=Counter()
            try store.withRoutineDatabase {db in
                sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT),{_,context,_,_ in
                    if let context {Unmanaged<Counter>.fromOpaque(context).takeUnretainedValue().statements+=1};return 0
                },Unmanaged.passUnretained(counter).toOpaque())
            }
            defer {_ = try? store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,0,nil,nil)}}
            _=try store.recordedMeetingSessionNames(for:sources,at:revision)
            try store.withRoutineDatabase {db in sqlite3_trace_v2(db.handle,0,nil,nil)}
            XCTAssertLessThanOrEqual(counter.statements,12,"Ready lookup must batch its bounded representatives")
            results.append(.init(name:name,expectedNames:expected,statementCount:counter.statements,observations:observations))
        }
        try measure("no-names",expected:0)
        try insertLabel(4999);try measure("one-loaded-name",expected:1)
        try store.withRoutineDatabase {db in try db.transaction {for index in 4488..<4999 {try insertLabel(index)}}}
        try measure("all-512-loaded-names",expected:512)
        try store.withRoutineDatabase {db in try db.transaction {for index in 0..<4488 {try insertLabel(index)}}}
        try measure("loaded-names-plus-4488-other-names",expected:512)
        XCTAssertEqual(try store.matchingCount(.init(kind:.audio)),5000)
        XCTAssertEqual(try store.matchingCount(.init(kind:.recordingMetadata)),5000)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        struct Report:Codable {let sources:Int,representatives:Int,cases:[CaseResult],scope:String}
        let report=Report(sources:count,representatives:sources.count,cases:results,scope:"Actual Core API on 5000 authored audio rows and up to 5000 authored session labels. Warm shared host; all samples including two labelled warmups retained. Timings include settings/snapshot/lookup and exclude setup/trace counting. Canonical payload reads and DML denied during lookup. Not UI, OS-cold, energy, ASR or competitive evidence.")
        try encoder.encode(report).write(to:output.appendingPathComponent("result.json"),options:.withoutOverwriting)
    }
}
