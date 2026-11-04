import XCTest
import Combine
import CSQLite
@testable import OSwindCore
@testable import OSwind

private final class RefreshWindowReadProbe:@unchecked Sendable {
    private let lock=NSLock()
    private var values=[Double]()
    func add(_ value:Double) {lock.lock();values.append(value);lock.unlock()}
    func snapshot()->[Double] {lock.lock();defer {lock.unlock()};return values}
}
@MainActor private final class RefreshWindowPublicationProbe {
    private var waiting=false,start:ContinuousClock.Instant?
    private(set) var values=[Double]()
    func busy(_ value:Bool) {if value {waiting=true;start=nil}else if waiting {waiting=false;start = .now}}
    func status(_ value:String) {guard let start,value.contains(" loaded") else {return};values.append(Self.seconds(start.duration(to:.now)));self.start=nil}
    nonisolated static func seconds(_ value:Duration)->Double {Double(value.components.seconds)+Double(value.components.attoseconds)/1e18}
}
@MainActor final class RecordedMeetingRefreshBenchmarkTests:XCTestCase {
    func testOwnedFullLoadedWindowRefreshAfterAnAudioChange()async throws {
        let env=ProcessInfo.processInfo.environment
        guard let path=env["OSWIND_RECORDING_VIEW_ROOT"],let corpus=env["OSWIND_RECORDING_VIEW_CORPUS"],let trial=env["OSWIND_RECORDING_VIEW_TRIAL"] else {throw XCTSkip("Explicit owned recording-window performance fixture")}
        let root=URL(fileURLWithPath:path).standardizedFileURL
        guard root.lastPathComponent=="recording-view-performance-v1",FileManager.default.fileExists(atPath:root.appendingPathComponent("owned-benchmark.json").path),["live20k","imports256"].contains(corpus),trial.range(of:#"^[a-z0-9-]+$"#,options:.regularExpression) != nil else {throw OSwindError.invalid("Use a new owned recording-window trial")}
        let directory=root.appendingPathComponent("trials/"+trial),destination=directory.appendingPathComponent("window-result.json"),expected=corpus=="live20k" ? 20_000:256
        guard !FileManager.default.fileExists(atPath:destination.path) else {throw OSwindError.invalid("Preserve every recording-window observation")}
        let store=try MemoryStore(root:directory.appendingPathComponent("library")),work=LibraryWorkRegistry(),reads=RefreshWindowReadProbe(),probe=RefreshWindowPublicationProbe()
        let model=RecordedMeetingsModel(store:store,work:work,foreground:{true},pollSeconds:{10_000},readWindow:{store,pages,refs in let start=ContinuousClock.now,value=try store.recordedMeetingWindow(pages:pages,retaining:refs);reads.add(RefreshWindowPublicationProbe.seconds(start.duration(to:.now)));return value})
        model.allowed={true};let busy=model.$busy.sink {probe.busy($0)},status=model.$status.sink {probe.status($0)};defer {busy.cancel();status.cancel()}
        func settled()async throws {
            let end=SuspendingClock.now.advanced(by:.seconds(120))
            while work.count(kinds:[.recordedMeetings])>0,SuspendingClock.now<end {try await Task.sleep(for:.milliseconds(1))}
            guard work.count(kinds:[.recordedMeetings])==0,!model.busy,model.error==nil else {throw OSwindError.unavailable("Owned window did not finish its current registry work")}
        }
        do {
            var start=ContinuousClock.now;_=try await Task.detached {try store.recordedMeetingPage()}.value;let warm=RefreshWindowPublicationProbe.seconds(start.duration(to:.now))
            start = .now;model.activate();try await settled();while model.hasOlder {model.loadOlder();try await settled()};let traversal=RefreshWindowPublicationProbe.seconds(start.duration(to:.now))
            let originalIDs=Set(model.sessions.flatMap(\.sources).map(\.memoryID)),wanted=Set((0..<expected).map {String(format:"authored-%08d",$0)})
            XCTAssertEqual(originalIDs,wanted)
            let selected=try XCTUnwrap(model.sessions.first {$0.sources.contains {$0.memoryID=="authored-00000000"}});model.selectedID=selected.id
            let latest=model.sessions.map(\.latest).max() ?? Date(timeIntervalSince1970:0)
            let other=try MemoryStore(root:store.root)
            do {
                var changed=try XCTUnwrap(other.get("authored-00000000"));changed.title="Owned refreshed recording source";try other.insert(changed)
                var added=Memory(id:"freshness-added",timestamp:latest.addingTimeInterval(1),endTimestamp:latest.addingTimeInterval(31),kind:.audio,app:"Owned window fixture",title:"Authored added recording",text:"Authored added recording words")
                added.audioSessionID="owned-freshness-added";added.transcript = .init(text:added.text,duration:30,segments:[.init(start:0,end:30,text:added.text)],model:"Authored fixture, no ASR claim");try other.insert(added);try other.close()
            }catch {try? other.close();throw error}
            try store.withRoutineDatabase {db in XCTAssertEqual(sqlite3_set_authorizer(db.handle,{_,action,table,column,_,_ in
                if action==SQLITE_INSERT || action==SQLITE_UPDATE || action==SQLITE_DELETE {return SQLITE_DENY}
                if action==SQLITE_READ,let table,let column,String(cString:table)=="memories",String(cString:column)=="payload" {return SQLITE_DENY};return SQLITE_OK
            },nil),SQLITE_OK)}
            let publicationsBefore=probe.values.count;start = .now;await model.checkForChanges();try await settled();let refresh=RefreshWindowPublicationProbe.seconds(start.duration(to:.now))
            let actualIDs=Set(model.sessions.flatMap(\.sources).map(\.memoryID)),selectionPreserved=model.selectedID==selected.id,titleUpdated=model.sessions.flatMap(\.sources).contains {$0.memoryID=="authored-00000000" && $0.title=="Owned refreshed recording source"}
            XCTAssertEqual(actualIDs,wanted.union(["freshness-added"]));XCTAssertTrue(selectionPreserved);XCTAssertTrue(titleUpdated);XCTAssertEqual(reads.snapshot().count,1);XCTAssertEqual(probe.values.count,publicationsBefore+1)
            struct Result:Codable {
                let corpus:String,trial:String,originalSources:Int,afterSources:Int,warmSeconds:Double,initialTraversalSeconds:Double,refreshCompletionWallSeconds:Double,windowReadSeconds:[Double],publicationSeconds:[Double],allIDsVerified:Bool,selectionPreserved:Bool,changedTitleUpdated:Bool
                let scope:String
            }
            let result=Result(corpus:corpus,trial:trial,originalSources:originalIDs.count,afterSources:actualIDs.count,warmSeconds:warm,initialTraversalSeconds:traversal,refreshCompletionWallSeconds:refresh,windowReadSeconds:reads.snapshot(),publicationSeconds:Array(probe.values.dropFirst(publicationsBefore)),allIDsVerified:actualIDs==wanted.union(["freshness-added"]),selectionPreserved:selectionPreserved,changedTitleUpdated:titleUpdated,scope:"Candidate-only full already-loaded window refresh after two authored canonical audio writes. Warmup and initial traversal separate; mutation and store construction outside refresh clocks. Real app model, explicit foreground=true/pollSeconds=10000 owned fixture, one explicit change check; not OS activation, scheduling cadence, frames, speech, power or competitor evidence. Timed traversal denies writes and canonical payload reads.")
            model.deactivate();await work.cancelAndWait();_ = try store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)};try store.close()
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];try encoder.encode(result).write(to:destination,options:.withoutOverwriting)
        }catch {model.deactivate();await work.cancelAndWait();_ = try? store.withRoutineDatabase {sqlite3_set_authorizer($0.handle,nil,nil)};try? store.close();throw error}
    }
}
