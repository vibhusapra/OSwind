import XCTest
import AppKit
import ApplicationServices
@testable import OSwindCore

/// Opt-in real native capture of one generated fixture. No foreground fallback.
@MainActor final class NativeTargetedCaptureSoakTests:XCTestCase {
    struct Configuration:Codable {
        var nonce:String,root:String,bundle:String,fixturePID:Int32,fixtureExecutable:String
        var seconds:Double,interval:Double
    }
    struct TerminalReport:Codable {
        var state:String,coverageQualified:Bool,uninterruptedCapture:Bool,captureDeferrals:Int,admissionRate:Double,minimumAdmissionRate:Double,expectedMinimumAttempts:Int,tailWallGap:Double,tailUptimeGap:Double,pid:Int32,attempts:Int,saved:Int,unchanged:Int,excluded:Int,errors:Int,sourceCount:Int,oversizeGaps:Int,elapsedWall:Double,elapsedUptime:Double,producersJoinedAndStoreClosed:Bool,scope:String
        func encoded()throws->Data {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];return try encoder.encode(self)}
    }
    func testTerminalReportEncodingDoesNotDependOnNativeCapture()throws {
        for complete in [true,false] {
            let report=TerminalReport(state:complete ? "completed":"completedWithGaps",coverageQualified:complete,uninterruptedCapture:complete,captureDeferrals:complete ? 0:2,admissionRate:complete ? 1:0.5,minimumAdmissionRate:0.9,expectedMinimumAttempts:10,tailWallGap:1,tailUptimeGap:1,pid:12345,attempts:12,saved:complete ? 12:6,unchanged:0,excluded:complete ? 0:2,errors:0,sourceCount:complete ? 12:6,oversizeGaps:complete ? 0:1,elapsedWall:65,elapsedUptime:65,producersJoinedAndStoreClosed:true,scope:"Authored terminal serialization control; no native capture")
            let data=try report.encoded(),decoded=try JSONDecoder().decode(TerminalReport.self,from:data)
            let json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            XCTAssertEqual(json["state"] as? String,report.state);XCTAssertEqual(json["captureDeferrals"] as? Int,report.captureDeferrals);XCTAssertEqual(json["sourceCount"] as? Int,report.sourceCount);XCTAssertEqual(decoded.coverageQualified,complete);XCTAssertEqual(decoded.producersJoinedAndStoreClosed,true)
        }
    }
    static func requireStartupWindow(previousSaved:Int,elapsed:Double,seconds:Double)throws {
        guard previousSaved>=0,elapsed.isFinite,elapsed>=0,seconds.isFinite,seconds>=5 else {throw OSwindError.invalid("Invalid initial-admission timing")}
        guard previousSaved>0 || elapsed<=min(15,seconds) else {throw OSwindError.unavailable("Initial generated source was not admitted within the startup budget; every deferral remains recorded")}
    }
    func testStartupAllowsRecordedDeferralWithinBoundButRejectsLateFirstAdmission()throws {
        XCTAssertNoThrow(try Self.requireStartupWindow(previousSaved:0,elapsed:4,seconds:65))
        XCTAssertThrowsError(try Self.requireStartupWindow(previousSaved:0,elapsed:16,seconds:65))
        XCTAssertNoThrow(try Self.requireStartupWindow(previousSaved:1,elapsed:65,seconds:65))
        XCTAssertThrowsError(try Self.requireStartupWindow(previousSaved:0,elapsed:.nan,seconds:65))
        XCTAssertThrowsError(try Self.requireStartupWindow(previousSaved:0,elapsed:-1,seconds:65))
    }
    func testOwnedPersistentTargetedCapture()async throws {
        guard let name=ProcessInfo.processInfo.environment["OSWIND_TEST_TARGETED_SOAK_CONFIGURATION"] else {throw XCTSkip("Explicit owned native targeted soak only")}
        let configURL=URL(fileURLWithPath:name),config=try JSONDecoder().decode(Configuration.self,from:Data(contentsOf:configURL))
        let root=URL(fileURLWithPath:config.root).standardizedFileURL
        guard root.path==configURL.deletingLastPathComponent().standardizedFileURL.path,root.lastPathComponent=="owned-soak-"+config.nonce,UUID(uuidString:config.nonce) != nil,
              config.seconds.isFinite,(5...86400).contains(config.seconds),config.interval.isFinite,(1...60).contains(config.interval),
              config.bundle=="com.oswind.fixture.soak."+config.nonce.lowercased(),config.fixturePID>0,
              root.resolvingSymlinksInPath()==root,!FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else {throw OSwindError.invalid("Invalid or reused owned soak configuration")}
        let source=NSRunningApplication(processIdentifier:config.fixturePID)
        let sourceMatches=source?.bundleIdentifier==config.bundle && source?.executableURL?.standardizedFileURL.path==config.fixtureExecutable
        let locked=SessionState.locked,screenAccess=CGPreflightScreenCaptureAccess(),axAccess=AXIsProcessTrusted()
        let prerequisites:[String:Any]=["sourceIdentityMatches":sourceMatches,"screenLocked":locked,"screenRecording":screenAccess,"accessibility":axAccess,"ready":sourceMatches && !locked && screenAccess && axAccess,"permissionRequestsMade":false]
        try JSONSerialization.data(withJSONObject:prerequisites,options:[.sortedKeys,.prettyPrinted]).write(to:root.appendingPathComponent("prerequisites.json"),options:.atomic)
        guard sourceMatches else {throw OSwindError.unavailable("Exact owned fixture identity is unavailable; no fallback is permitted")}
        guard !locked else {throw OSwindError.unavailable("Native targeted baseline requires a manually unlocked Mac")}
        guard screenAccess && axAccess else {throw OSwindError.unavailable("Existing screen/AX access required; no permission is requested")}
        var settings=AppSettings();settings.profile = .light;settings.captureOnLaunch=false;settings.automaticMaintenance=false;try settings.save(root:root)
        let store=try MemoryStore(root:root),controller=CaptureController(store:store,embedder:LocalEmbedder(),settings:settings)
        let logURL=root.appendingPathComponent("attempts.jsonl");FileManager.default.createFile(atPath:logURL.path,contents:nil);let log=try FileHandle(forWritingTo:logURL)
        let start=Date().timeIntervalSince1970,uptime=ProcessInfo.processInfo.systemUptime;var previousWall=start,previousUptime=uptime,attempt=0,gaps=0,deferrals=0
        func write(_ value:[String:Any],to url:URL)throws {try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic)}
        let boundary="Persistent actual controller/store; explicit generated app target every interval. Initial source deadline15seconds (or shorter configured run); cold-start deferrals stay in all coverage counters. Manual-request cadence, not automatic foreground/idle/thermal app scheduling. Wall/uptime gaps are reported, never uninterrupted coverage. No power/battery/GPU timing or competitor ranking claim."
        try write(["state":"running","pid":ProcessInfo.processInfo.processIdentifier,"startedWall":start,"startedUptime":uptime,"requestedSeconds":config.seconds,"intervalSeconds":config.interval,"bundle":config.bundle,"scope":boundary],to:root.appendingPathComponent("status.json"))
        do {
            repeat {
                try Task.checkCancellation()
                let wall=Date().timeIntervalSince1970,mono=ProcessInfo.processInfo.systemUptime
                let wallGap=wall-previousWall,monoGap=mono-previousUptime
                guard wallGap >= -5 else {throw OSwindError.unavailable("Wall clock moved backwards during the native baseline")}
                let gap=attempt>0 && (wallGap>config.interval*2+5 || monoGap>config.interval*2+5 || abs(wallGap-monoGap)>5)
                if gap {gaps+=1}
                let begun=ProcessInfo.processInfo.systemUptime,savedBefore=controller.metrics.saved
                await controller.captureOnce(manual:true,targetBundleID:config.bundle);attempt+=1
                let metrics=controller.metrics,count=try store.stats().count
                let admitted=metrics.saved-savedBefore;if admitted==0 {deferrals+=1}
                let row:[String:Any]=["attempt":attempt,"wall":wall,"uptime":mono,"wallGap":wallGap,"uptimeGap":monoGap,"oversizeGap":gap,"latencyMS":(ProcessInfo.processInfo.systemUptime-begun)*1000,"saved":metrics.saved,"unchanged":metrics.unchanged,"excluded":metrics.excluded,"errors":metrics.errors,"sourceCount":count,"admittedThisAttempt":admitted,"deferrals":deferrals,"status":controller.status]
                try log.write(contentsOf:JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]));try log.synchronize()
                try write(["state":"running","pid":ProcessInfo.processInfo.processIdentifier,"attempts":attempt,"saved":metrics.saved,"unchanged":metrics.unchanged,"excluded":metrics.excluded,"errors":metrics.errors,"sourceCount":count,"oversizeGaps":gaps,"captureDeferrals":deferrals,"elapsedWall":Date().timeIntervalSince1970-start,"elapsedUptime":ProcessInfo.processInfo.systemUptime-uptime,"scope":boundary],to:root.appendingPathComponent("status.json"))
                try Self.requireStartupWindow(previousSaved:savedBefore,elapsed:Date().timeIntervalSince1970-start,seconds:config.seconds)
                if FileManager.default.fileExists(atPath:root.appendingPathComponent("stop-requested").path) {throw CancellationError()}
                previousWall=wall;previousUptime=mono
                let remaining=config.seconds-(Date().timeIntervalSince1970-start);if remaining<=0 {break}
                try await Task.sleep(for:.seconds(min(config.interval,remaining)))
            } while Date().timeIntervalSince1970-start<config.seconds
            let endedWall=Date().timeIntervalSince1970,endedUptime=ProcessInfo.processInfo.systemUptime
            let tailWallGap=endedWall-previousWall,tailUptimeGap=endedUptime-previousUptime
            if tailWallGap>config.interval*2+5 || tailUptimeGap>config.interval*2+5 || abs(tailWallGap-tailUptimeGap)>5 {gaps+=1}
            let expectedMinimum=max(1,Int(floor(config.seconds/config.interval*0.8)))
            let admissionRate=Double(controller.metrics.saved)/Double(max(1,attempt))
            let coverageQualified=gaps==0 && attempt>=expectedMinimum && endedWall-start>=config.seconds-1 && admissionRate>=0.9
            await controller.cancelAndWait();let count=try store.stats().count;try store.close();try log.close()
            let terminal=TerminalReport(state:coverageQualified ? "completed":"completedWithGaps",coverageQualified:coverageQualified,uninterruptedCapture:coverageQualified && deferrals==0,captureDeferrals:deferrals,admissionRate:admissionRate,minimumAdmissionRate:0.9,expectedMinimumAttempts:expectedMinimum,tailWallGap:tailWallGap,tailUptimeGap:tailUptimeGap,pid:ProcessInfo.processInfo.processIdentifier,attempts:attempt,saved:controller.metrics.saved,unchanged:controller.metrics.unchanged,excluded:controller.metrics.excluded,errors:controller.metrics.errors,sourceCount:count,oversizeGaps:gaps,elapsedWall:Date().timeIntervalSince1970-start,elapsedUptime:ProcessInfo.processInfo.systemUptime-uptime,producersJoinedAndStoreClosed:true,scope:boundary)
            try terminal.encoded().write(to:root.appendingPathComponent("status.json"),options:.atomic)
            XCTAssertGreaterThan(count,0);XCTAssertEqual(controller.metrics.errors,0);XCTAssertTrue(coverageQualified,"Coverage gaps or missing cadence; see retained status and all attempt rows")
        } catch {
            await controller.cancelAndWait();let closeResult=Result {try store.close()};try? log.close()
            try? write(["state":"failed","pid":ProcessInfo.processInfo.processIdentifier,"attempts":attempt,"error":error.localizedDescription,"elapsedWall":Date().timeIntervalSince1970-start,"elapsedUptime":ProcessInfo.processInfo.systemUptime-uptime,"oversizeGaps":gaps,"producersJoined":true,"storeClosed":(try? closeResult.get()) != nil,"scope":boundary],to:root.appendingPathComponent("status.json"));throw error
        }
    }
}
