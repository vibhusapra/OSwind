import XCTest
import Darwin
import MachO
@testable import OSwindCore

/// Own-child process death, not a simulated power cut or a production-library test.
final class SyncCaptureCrashTests:XCTestCase {
    private enum FixtureError:Error {case invalidOwnership}

    func testDeathBeforeCommitRollsBackSourceCaptureAndSequence()throws {try crash(at:"before")}
    func testDeathAfterCommitRetainsSourceCaptureAndSequence()throws {try crash(at:"after")}

    private func crash(at phase:String)throws {
        let fm=FileManager.default,nonce=UUID().uuidString
        let root=fm.temporaryDirectory.appendingPathComponent("oswind-capture-crash-"+nonce,isDirectory:true)
        try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? fm.removeItem(at:root)}
        let authority=root.appendingPathComponent("owner"),gate=root.appendingPathComponent("ready")
        try Data(nonce.utf8).write(to:authority,options:.withoutOverwriting)
        try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:authority.path)
        let child=Process(),log=root.appendingPathComponent("child.log")
        XCTAssertTrue(fm.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600]))
        let output=try FileHandle(forWritingTo:log);defer {try? output.close()}
        let runner=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard runner.lastPathComponent=="xctest",fm.isExecutableFile(atPath:runner.path) else {throw FixtureError.invalidOwnership}
        child.executableURL=runner
        child.arguments=["-XCTest","OSwindCoreTests.SyncCaptureCrashTests/testCrashWorker",Bundle(for:Self.self).bundleURL.path]
        var environment=["PATH":"/usr/bin:/bin","LANG":"en_US.UTF-8",
            "TMPDIR":fm.temporaryDirectory.path,"OSWIND_CAPTURE_CRASH_ROOT":root.path,
            "OSWIND_CAPTURE_CRASH_NONCE":nonce,"OSWIND_CAPTURE_CRASH_PHASE":phase]
        // Preload only the TSan runtime already loaded by this test host. An
        // instrumented test bundle cannot dlopen its runtime after host startup.
        // Launch xctest directly: the protected /usr/bin/xcrun strips DYLD vars.
        for index in 0..<_dyld_image_count() {
            guard let name=_dyld_get_image_name(index) else {continue}
            let image=URL(fileURLWithPath:String(cString:name)).resolvingSymlinksInPath()
            if image.lastPathComponent=="libclang_rt.tsan_osx_dynamic.dylib" {environment["DYLD_INSERT_LIBRARIES"]=image.path}
        }
        child.environment=environment
        child.standardOutput=output;child.standardError=output
        try child.run()
        // This exact Process is our child. No process-name matching or other process is signalled.
        defer {if child.isRunning {_=Darwin.kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        let deadline=ProcessInfo.processInfo.systemUptime+30
        while child.isRunning && !fm.fileExists(atPath:gate.path) && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard child.isRunning,(try? String(contentsOf:gate,encoding:.utf8))==phase else {
            XCTFail("Owned crash worker failed to reach its gate: "+((try? String(contentsOf:log,encoding:.utf8)) ?? "no log"));return
        }
        XCTAssertEqual(Darwin.kill(child.processIdentifier,SIGKILL),0)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason,.uncaughtSignal);XCTAssertEqual(child.terminationStatus,SIGKILL)
        let store=try MemoryStore(root:root.appendingPathComponent("library"));defer {try? store.close()}
        let committed=phase=="after"
        XCTAssertEqual(try store.get("crash-owned-note")?.text,committed ? "authored crash recovery evidence":nil)
        let scope=try store.withRoutineDatabase {try SyncChangeCapture.scope($0)}
        let changes=try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:scope)}
        XCTAssertEqual(changes.count,committed ? 1:0);XCTAssertEqual(changes.first?.sequence,committed ? 1:nil)
        try store.insert(Memory(id:"next",text:"next"))
        let next=try store.withRoutineDatabase {try SyncChangeCapture.changes($0,scope:scope)}
        XCTAssertEqual(next.last?.sequence,committed ? 2:1)
    }

    func testCrashWorker()throws {
        let env=ProcessInfo.processInfo.environment,fm=FileManager.default
        guard let path=env["OSWIND_CAPTURE_CRASH_ROOT"],let nonce=env["OSWIND_CAPTURE_CRASH_NONCE"],let phase=env["OSWIND_CAPTURE_CRASH_PHASE"] else {throw XCTSkip("Only run as the owned crash-test subprocess")}
        guard UUID(uuidString:nonce)?.uuidString==nonce,["before","after"].contains(phase) else {throw FixtureError.invalidOwnership}
        let root=URL(fileURLWithPath:path,isDirectory:true),expected=fm.temporaryDirectory.appendingPathComponent("oswind-capture-crash-"+nonce,isDirectory:true)
        guard root.resolvingSymlinksInPath().standardizedFileURL==expected.resolvingSymlinksInPath().standardizedFileURL,
              try String(contentsOf:root.appendingPathComponent("owner"),encoding:.utf8)==nonce else {throw FixtureError.invalidOwnership}
        let store=try MemoryStore(root:root.appendingPathComponent("library"))
        func hold()throws {
            try Data(phase.utf8).write(to:root.appendingPathComponent("ready"),options:.atomic)
            Thread.sleep(forTimeInterval:60)
            XCTFail("Parent did not stop its owned child at the crash gate")
        }
        _=try store.withRoutineDatabase {try SyncChangeCapture.activate($0)}
        try store.withRoutineDatabase {db in try db.transaction {
            try store.insert(Memory(id:"crash-owned-note",text:"authored crash recovery evidence"))
            if phase=="before" {try hold()}
        }}
        if phase=="after" {try hold()}
        try store.close()
    }
}
