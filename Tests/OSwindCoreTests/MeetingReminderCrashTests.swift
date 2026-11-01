import XCTest
import Foundation
import CSQLite
import Darwin
import MachO
@testable import OSwindCore

private final class MeetingCommitGate {
    let root:URL,phase:String
    init(root:URL,phase:String) {self.root=root;self.phase=phase}
    func hold() {
        do {try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)}catch {return}
        Thread.sleep(forTimeInterval:60)
    }
}
final class MeetingReminderCrashTests:XCTestCase {
    private let date=Date(timeIntervalSince1970:1_793_490_000)
    private func event()throws->MeetingOccurrence {try .init(calendarID:"owned-calendar",seriesID:"owned-series",start:date.addingTimeInterval(60),end:date.addingTimeInterval(1800),title:"Owned private calendar title",joinURL:URL(string:"https://meeting.example/?token=OwnedSecret"))}
    private func configuration(_ identity:String)->MeetingContextConfiguration {var c=MeetingContextConfiguration();c.enabled=true;c.reminders=true;c.calendarIDs=["owned-calendar"];c.boundLibrary=identity;return c}
    private func crash(_ phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString,root=fm.temporaryDirectory.appendingPathComponent("owned-meeting-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
        try Data(nonce.utf8).write(to:root.appendingPathComponent("owner"),options:.withoutOverwriting)
        let setup=try MemoryStore(root:root.appendingPathComponent("library")),identity=try setup.authorizeMeetingLibrary();try setup.close()
        let child=Process(),runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath(),log=root.appendingPathComponent("worker.log")
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path),fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]) else {throw OSwindError.invalid("Invalid owned reminder crash runner")}
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        child.executableURL=runner;child.arguments=["-XCTest","OSwindCoreTests.MeetingReminderCrashTests/testMeetingReminderCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var env=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8","TMPDIR":fm.temporaryDirectory.path,"OSWIND_MEETING_CRASH_ROOT":root.path,"OSWIND_MEETING_CRASH_NONCE":nonce,"OSWIND_MEETING_CRASH_PHASE":phase]
        for i in 0..<_dyld_image_count() {guard let name=_dyld_get_image_name(i) else {continue};let url=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath();if url.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {env["DYLD_INSERT_LIBRARIES"]=url.path}}
        child.environment=env;child.standardOutput=output;child.standardError=output;try child.run()
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let gate=root.appendingPathComponent("ready"),deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning,!fm.fileExists(atPath:gate.path),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {return XCTFail("Owned reminder worker missed gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "missing log"))}
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0);child.waitUntilExit();XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let database=root.appendingPathComponent("library/memory.sqlite")
        guard let canonical=realpath(database.path,nil) else {throw OSwindError.invalid("Missing owned reminder database")};defer {free(canonical)}
        var handle:OpaquePointer?;let opened=sqlite3_open_v2(canonical,&handle,SQLITE_OPEN_READONLY|SQLITE_OPEN_FULLMUTEX|SQLITE_OPEN_NOFOLLOW,nil)
        guard opened==SQLITE_OK,let handle else {sqlite3_close(handle);throw OSwindError.invalid("Cannot inspect owned reminder database")}
        do {
            let db=RoutineDatabase(handle:handle);XCTAssertEqual(try db.eraseCount("SELECT count(*) FROM store_metadata WHERE key='meeting-reminder-receipts-v1'"),phase=="after" ? 1:0)
            let check=try db.statement("PRAGMA integrity_check");defer {sqlite3_finalize(check)};XCTAssertEqual(sqlite3_step(check),SQLITE_ROW);XCTAssertEqual(db.text(check,0),"ok")
        }catch {sqlite3_close(handle);throw error};sqlite3_close(handle)
        let reopened=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? reopened.close()}
        let keys=try reopened.claimMeetingReminders([event()],configuration:configuration(identity),expectedLibrary:identity,now:date)
        XCTAssertEqual(keys.count,phase=="after" ? 0:1);XCTAssertTrue(try reopened.claimMeetingReminders([event()],configuration:configuration(identity),expectedLibrary:identity,now:date).isEmpty)
        print("MEETING_REMINDER_CRASH phase=\(phase) rawSQLiteCheckedBeforeStoreOpen=true retryDeduplicated=true")
        if let path=ProcessInfo.processInfo.environment["OSWIND_TEST_MEETING_LOG_ROOT"] {
            let base=URL(fileURLWithPath:path,isDirectory:true)
            guard base.path==path,base.resolvingSymlinksInPath().path==path,try String(contentsOf:base.appendingPathComponent("owned-fixture"),encoding:.utf8)=="OSwind authored meeting crash logs v1" else {throw OSwindError.invalid("Invalid owned reminder log destination")}
            try fm.copyItem(at:log,to:base.appendingPathComponent("meeting-"+phase+"-"+nonce+".log"))
        }
    }
    func testDeathBeforeReminderCommitAllowsOneRetry()throws {try crash("before")}
    func testDeathAfterReminderCommitDoesNotRepeatAttempt()throws {try crash("after")}
    func testMeetingReminderCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_MEETING_CRASH_ROOT"],let nonce=env["OSWIND_MEETING_CRASH_NONCE"],let phase=env["OSWIND_MEETING_CRASH_PHASE"] else {throw XCTSkip("Only run as an owned reminder crash child")}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("owned-meeting-crash-"+nonce,isDirectory:true)
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase),root.resolvingSymlinksInPath()==expected.resolvingSymlinksInPath(),try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw OSwindError.invalid("Invalid owned reminder crash root")}
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let identity=try store.authorizeMeetingLibrary(),probe=MeetingCommitGate(root:root,phase:phase),pointer=Unmanaged.passUnretained(probe).toOpaque()
        try store.withRoutineDatabase {db in
            sqlite3_trace_v2(db.handle,UInt32(SQLITE_TRACE_STMT|SQLITE_TRACE_PROFILE),{kind,context,statement,_ in
                guard let context,let statement,let text=sqlite3_sql(OpaquePointer(statement)),String(cString:text)=="COMMIT" else {return 0}
                let probe=Unmanaged<MeetingCommitGate>.fromOpaque(context).takeUnretainedValue()
                if (probe.phase=="before" && kind==UInt32(SQLITE_TRACE_STMT)) || (probe.phase=="after" && kind==UInt32(SQLITE_TRACE_PROFILE)) {probe.hold()};return 0
            },pointer)
        }
        defer {try? store.withRoutineDatabase {sqlite3_trace_v2($0.handle,0,nil,nil)}}
        withExtendedLifetime(probe) {_ = try? store.claimMeetingReminders([event()],configuration:configuration(identity),expectedLibrary:identity,now:date)}
        XCTFail("Parent did not stop the owned reminder worker at COMMIT")
    }
}
