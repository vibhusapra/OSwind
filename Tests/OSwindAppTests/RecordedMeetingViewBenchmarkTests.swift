import XCTest
import Combine
import CSQLite
@testable import OSwindCore
@testable import OSwind

private struct RecordingPageTiming:Codable,Sendable {
    let seconds:Double
    let rows:Int
}
private final class RecordingPageReadProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var values=[RecordingPageTiming]()
    func append(_ value:RecordingPageTiming) {lock.lock();defer {lock.unlock()};values.append(value)}
    func snapshot()->[RecordingPageTiming] {lock.lock();defer {lock.unlock()};return values}
}
@MainActor private final class RecordingPublicationProbe {
    private var waiting=false,started:ContinuousClock.Instant?
    private(set) var seconds=[Double]()
    func busy(_ value:Bool) {
        if value {waiting=true;started=nil}
        else if waiting {waiting=false;started = .now}
    }
    func status(_ value:String) {
        guard let started,value.contains(" loaded") else {return}
        seconds.append(Self.interval(started.duration(to:.now)));self.started=nil
    }
    nonisolated static func interval(_ value:Duration)->Double {Double(value.components.seconds)+Double(value.components.attoseconds)/1e18}
}

/// Opt-in authored corpus measurements, against the actual app model. These
/// brackets do not measure SwiftUI layout, vsync, input latency, energy or speech.
@MainActor final class RecordedMeetingViewBenchmarkTests:XCTestCase {
    func testOwnedArchivePublicationAndMetricReads()async throws {
        let environment=ProcessInfo.processInfo.environment
        guard let path=environment["OSWIND_RECORDING_VIEW_ROOT"],let corpus=environment["OSWIND_RECORDING_VIEW_CORPUS"],let trial=environment["OSWIND_RECORDING_VIEW_TRIAL"] else {throw XCTSkip("Explicit owned recording-view performance fixture")}
        let root=URL(fileURLWithPath:path).standardizedFileURL
        guard root.lastPathComponent=="recording-view-performance-v1",FileManager.default.fileExists(atPath:root.appendingPathComponent("owned-benchmark.json").path),["live20k","imports256"].contains(corpus),trial.range(of:#"^[a-z0-9-]+$"#,options:.regularExpression) != nil else {throw OSwindError.invalid("Use a new owned recording-view trial")}
        let expected=corpus=="live20k" ? 20_000:256,directory=root.appendingPathComponent("trials/"+trial),destination=directory.appendingPathComponent("result.json")
        guard !FileManager.default.fileExists(atPath:destination.path) else {throw OSwindError.invalid("Keep every previous recording-view observation")}
        let library=directory.appendingPathComponent("library"),store=try MemoryStore(root:library),work=LibraryWorkRegistry()
        let probe=RecordingPageReadProbe(),publication=RecordingPublicationProbe()
        let model=RecordedMeetingsModel(store:store,work:work,readPage:{store,cursor in
            let started=ContinuousClock.now,page=try store.recordedMeetingPage(before:cursor)
            probe.append(.init(seconds:RecordingPublicationProbe.interval(started.duration(to:.now)),rows:page.examined));return page
        })
        model.allowed={true}
        let busy=model.$busy.sink {publication.busy($0)},status=model.$status.sink {publication.status($0)}
        defer {busy.cancel();status.cancel()}
        do {
            // Prepare the copied corpus's derived cache outside all publication
            // and SQL-page measurements. Never open the immutable original.
            let warmStarted=ContinuousClock.now
            _=try await Task.detached(priority:.utility) {try store.recordedMeetingPage()}.value
            let warmSeconds=RecordingPublicationProbe.interval(warmStarted.duration(to:.now))
            try store.withRoutineDatabase {db in
                XCTAssertEqual(sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                    if action==SQLITE_INSERT || action==SQLITE_UPDATE || action==SQLITE_DELETE {return SQLITE_DENY}
                    if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY}
                    return SQLITE_OK
                },nil),SQLITE_OK)
            }
            var completion=[Double](),metricSweeps=[Double](),loaded=[Int](),checksums=[Double]()
            func settle()async throws {
                let deadline=SuspendingClock.now.advanced(by:.seconds(120))
                while work.count(kinds:[.recordedMeetings])>0,SuspendingClock.now<deadline {try await Task.sleep(for:.milliseconds(1))}
                XCTAssertEqual(work.count(kinds:[.recordedMeetings]),0);XCTAssertFalse(model.busy);XCTAssertNil(model.error)
            }
            func metrics() {
                let started=ContinuousClock.now
                var sum=0.0,count=0
                for session in model.sessions {
                    sum+=session.first.timeIntervalSince1970+session.latest.timeIntervalSince1970+session.observedSeconds+session.clipSeconds
                    if session.hasUnobservedTimes {sum+=1}
                    count+=session.sources.count
                }
                metricSweeps.append(RecordingPublicationProbe.interval(started.duration(to:.now)));loaded.append(count);checksums.append(sum)
            }
            var started=ContinuousClock.now;model.activate();try await settle();completion.append(RecordingPublicationProbe.interval(started.duration(to:.now)));metrics()
            while model.hasOlder {
                started = .now;model.loadOlder();try await settle();completion.append(RecordingPublicationProbe.interval(started.duration(to:.now)));metrics()
            }
            let ids=model.sessions.flatMap(\.sources).map(\.memoryID),wanted=Set((0..<expected).map {String(format:"authored-%08d",$0)})
            XCTAssertEqual(ids.count,expected);XCTAssertEqual(Set(ids),wanted);XCTAssertEqual(probe.snapshot().count,completion.count);XCTAssertEqual(publication.seconds.count,completion.count)
            let clearStarted=ContinuousClock.now;model.deactivate();await work.cancelAndWait();let clearSeconds=RecordingPublicationProbe.interval(clearStarted.duration(to:.now))
            try store.withRoutineDatabase {db in XCTAssertEqual(sqlite3_set_authorizer(db.handle,nil,nil),SQLITE_OK)}
            XCTAssertEqual(try store.matchingCount(.init(kind:.audio)),expected);try store.close()
            struct Result:Codable {
                let corpus:String,trial:String,expected:Int,uniqueSources:Int,warmSeconds:Double,pages:[RecordingPageTiming],publicationSeconds:[Double],completionWallSeconds:[Double],allGroupMetricSweepSeconds:[Double],loadedSources:[Int],metricChecksums:[Double],clearAndJoinSeconds:Double
                let scope:String
            }
            let result=Result(corpus:corpus,trial:trial,expected:expected,uniqueSources:Set(ids).count,warmSeconds:warmSeconds,pages:probe.snapshot(),publicationSeconds:publication.seconds,completionWallSeconds:completion,allGroupMetricSweepSeconds:metricSweeps,loadedSources:loaded,metricChecksums:checksums,clearAndJoinSeconds:clearSeconds,scope:"Authored copied corpus, warm derived cache, real app model. Publication brackets busy=false emission through loaded-status emission, excluding deferred cleanup/rendering. Completion includes worker, actor callback and 1ms polling; metric sweep reads every loaded group's computed properties. No canonical writes/payload reads allowed during traversal. Not frame/vsync/input latency, OS-cold, speech, power or competitive evidence.")
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(result).write(to:destination,options:.withoutOverwriting)
        }catch {
            model.deactivate();await work.cancelAndWait();try? store.withRoutineDatabase {db in sqlite3_set_authorizer(db.handle,nil,nil)};try? store.close();throw error
        }
    }
}
