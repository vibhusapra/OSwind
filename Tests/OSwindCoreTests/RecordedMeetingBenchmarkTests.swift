import XCTest
import CSQLite
@testable import OSwindCore

/// Opt-in authored-corpus measurements. These are not speech-quality, daemon
/// energy, physical-device or competitor measurements. Keep every trial.
final class RecordedMeetingBenchmarkTests:XCTestCase {
    func testAuthoredArchiveStartupAndPaging()throws {
        let environment=ProcessInfo.processInfo.environment
        guard let path=environment["OSWIND_RECORDED_BENCH_ROOT"],let mode=environment["OSWIND_RECORDED_BENCH_MODE"] else {throw XCTSkip("Opt-in authored recording archive benchmark")}
        let root=URL(fileURLWithPath:path).standardizedFileURL
        guard root.lastPathComponent=="recorded-meeting-startup-v1",FileManager.default.fileExists(atPath:root.appendingPathComponent("owned-benchmark.json").path) else {throw OSwindError.invalid("Use this benchmark's generated archive directory")}
        if mode=="seed" {
            var reports=[[String:Any]]()
            for (name,count,bytes,live) in [("live20k",20000,768,true),("imports256",256,131072,false)] {
                let directory=root.appendingPathComponent("corpora/"+name)
                guard !FileManager.default.fileExists(atPath:directory.path) else {throw OSwindError.invalid("Keep existing authored benchmark archives")}
                let started=ProcessInfo.processInfo.systemUptime,store=try MemoryStore(root:directory)
                let text=String(repeating:"authored source word ",count:bytes/21+1).prefix(bytes)
                try store.withRoutineDatabase {db in try db.transaction {
                    for index in 0..<count {
                        let timestamp=Date(timeIntervalSince1970:1700000000+Double(index*30)),duration=live ? 30.0:3600.0,id=String(format:"authored-%08d",index)
                        var memory=Memory(id:id,timestamp:timestamp,endTimestamp:live ? timestamp.addingTimeInterval(duration):nil,kind:.audio,app:"Authored benchmark",bundleID:"org.oswind.authored-benchmark",title:"Authored recording",text:String(text))
                        memory.audioSessionID=live ? "recording-\(index/120)":"file-\(index)"
                        let middle=text.index(text.startIndex,offsetBy:text.count/2)
                        memory.transcript = .init(text:String(text),duration:duration,segments:[.init(start:0,end:duration/2,text:String(text[..<middle])),.init(start:duration/2,end:duration,text:String(text[middle...]))],model:"Synthetic fixture, not recognized speech")
                        try store.insert(memory)
                    }
                }}
                XCTAssertEqual(try store.stats(includeDiskUsage:false).count,count)
                try store.withRoutineDatabase {db in
                    // Only this generated, unconfigured corpus. Model the exact
                    // predecessor state without the new derived recording cache.
                    for name in RecordedMeetingSchema.triggers.keys {try db.execute("DROP TRIGGER \(name)")}
                    try db.execute("DROP TABLE recorded_meeting_sources; DELETE FROM store_metadata WHERE key='recorded_meeting_index_version'; PRAGMA wal_checkpoint(TRUNCATE)")
                }
                try store.close()
                reports.append(["name":name,"rows":count,"textBytesPerSource":bytes,"liveInterval":live,"seedSeconds":ProcessInfo.processInfo.systemUptime-started,"databaseBytes":try FileManager.default.attributesOfItem(atPath:directory.appendingPathComponent("memory.sqlite").path)[.size] as! UInt64])
            }
            try write(["mode":mode,"corpora":reports],root.appendingPathComponent("seed.json"))
        }else if mode=="page" {
            guard let trial=environment["OSWIND_RECORDED_BENCH_TRIAL"],trial.range(of:#"^[a-z0-9-]+$"#,options:.regularExpression) != nil,let expected=Int(environment["OSWIND_RECORDED_BENCH_COUNT"] ?? "") else {throw OSwindError.invalid("Select an authored trial and source count")}
            let directory=root.appendingPathComponent("trials/"+trial),started=ProcessInfo.processInfo.systemUptime,store=try MemoryStore(root:directory)
            let openSeconds=ProcessInfo.processInfo.systemUptime-started
            var cursor:RecordedMeetingCursor?,ids=Set<String>(),timings=[Double](),counts=[Int]()
            repeat {
                let start=ProcessInfo.processInfo.systemUptime,page=try store.recordedMeetingPage(before:cursor,limit:512)
                timings.append(ProcessInfo.processInfo.systemUptime-start);counts.append(page.examined)
                XCTAssertEqual(page.excluded,0)
                for source in page.sources {XCTAssertTrue(ids.insert(source.memoryID).inserted);XCTAssertTrue(source.memoryID.hasPrefix("authored-"))}
                cursor=page.next
            }while cursor != nil
            XCTAssertEqual(ids.count,expected)
            XCTAssertEqual(ids,Set((0..<expected).map {String(format:"authored-%08d",$0)}))
            // Repeated first page, separately labelled from the full traversal.
            var repeated=[Double]()
            for _ in 0..<11 {let start=ProcessInfo.processInfo.systemUptime,page=try store.recordedMeetingPage(limit:512);repeated.append(ProcessInfo.processInfo.systemUptime-start);XCTAssertEqual(page.sources.count,min(expected,512))}
            try store.close()
            try write(["mode":mode,"trial":trial,"expected":expected,"uniqueSources":ids.count,"openSeconds":openSeconds,"traversalPageSeconds":timings,"traversalExamined":counts,"repeatedFirstPageSeconds":repeated],root.appendingPathComponent("page-"+trial+".json"))
        }else {throw OSwindError.invalid("Unknown recording benchmark mode")}
    }
    private func write(_ value:[String:Any],_ destination:URL)throws {
        guard !FileManager.default.fileExists(atPath:destination.path) else {throw OSwindError.invalid("Preserve prior benchmark output")}
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:destination,options:.atomic)
    }
}
