import XCTest
import CSQLite
import CryptoKit
import Darwin
@testable import OSwindCore

extension SyncNativeWriterAdmissionTests {
    func testOwnedActualKeychainRetirementReopensCleansAndRenewsOriginalAccounts()throws {
        guard ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE_SYNC_KEYCHAIN"]=="1" else {throw XCTSkip("Explicit owned Keychain retirement fixture")}
        let backend=NativeWriterKeychainFixture(),state=root.appendingPathComponent("native-retirement-state"),mac=MacSyncMachineFingerprint()
        let native=SyncNativeWriterEnvironment(stateRoot:state,machine:mac,storage:{_ in backend})
        defer {do {try backend.cleanup()}catch{XCTFail("Owned retirement Keychain accounts could not be removed")}}
        let file=library.root.appendingPathComponent("images/native-retirement.jpg");try Data("Owned native retirement media".utf8).write(to:file)
        try library.insert(Memory(id:"owned",text:"Owned actual Keychain retirement",imagePath:"images/native-retirement.jpg"))
        let owner=try PersonalSyncPairing(store:library,stateRoot:state,machine:mac,storage:backend);pairing=owner
        _=try owner.createGroup(deviceName:"Owned native retirement")
        service=try owner.prepareAnchoredService(shared:root.appendingPathComponent("shared"),createShared:true)
        try service!.installNativeWriterAdmission();try ready();_=try service!.stageLocalRetirement()
        try stop();try library.close()
        let recovery=try SyncRetirementCleanupOwner.open(root:library.root,environment:native);defer {try? recovery.close()}
        XCTAssertTrue(try recovery.cleanup().cleanupComplete);XCTAssertEqual(try recovery.completeLocalRetirement().counter,1)
        try recovery.close();library=try MemoryStore(root:library.root,recoveryReadOnly:false,nativeWriterEnvironment:native)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path));XCTAssertEqual(backend.accounts.count,2)
        try library.insert(Memory(id:"native-renewed",text:"Original account renewal verified"));XCTAssertNotNil(try library.get("native-renewed"))
        try library.close();try backend.cleanup();XCTAssertTrue(backend.accounts.isEmpty)
    }
    func testActualFrozen34ClientCannotWrite35FreshOrAfterWaitingBeforeEnrollment()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_NATIVE34_CLI"] else {throw XCTSkip("Requires the exact frozen sourceff native34 CLI")}
        let binary=URL(fileURLWithPath:path),expected="be363108102b5308a7325375e8aa6a4f6597cfd2d92091a195b995ed1484e644"
        func hash()throws->String {SHA256.hash(data:try Data(contentsOf:binary)).map{String(format:"%02x",$0)}.joined()}
        guard FileManager.default.isExecutableFile(atPath:path),try hash()==expected else {throw OSwindError.invalid("Use the exact frozen sourceff CLI without overwriting it")}
        var env=ProcessInfo.processInfo.environment;env["OSWIND_DATA_DIR"]=library.root.path;env.removeValue(forKey:"DYLD_INSERT_LIBRARIES")
        func freshStats()throws->(Int32,String) {
            let child=Process(),errors=Pipe();child.executableURL=binary;child.arguments=["--data",library.root.path,"stats"];child.environment=env
            child.standardInput=FileHandle.nullDevice;child.standardOutput=FileHandle.nullDevice;child.standardError=errors
            try child.run();let bytes=errors.fileHandleForReading.readDataToEndOfFile();child.waitUntilExit();return (child.terminationStatus,String(decoding:bytes,as:UTF8.self))
        }
        XCTAssertEqual(try freshStats().0,0,"The exact old binary must positively open the ordinary33 fixture first")
        let child=Process(),input=Pipe(),errors=Pipe();child.executableURL=binary;child.arguments=["--data",library.root.path,"collect","--stdin"];child.environment=env
        child.standardInput=input;child.standardOutput=FileHandle.nullDevice;child.standardError=errors
        try child.run()
        defer {
            try? input.fileHandleForWriting.close()
            if child.isRunning {child.terminate();for _ in 0..<100 where child.isRunning {Thread.sleep(forTimeInterval:0.01)};if child.isRunning {kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()}
        }
        var observed=false;let deadline=ProcessInfo.processInfo.systemUptime+15
        while child.isRunning,!observed,ProcessInfo.processInfo.systemUptime<deadline {
            do {let media=try MediaAdmissionLease.acquire(root:library.root,exclusive:true,timeout:0,onBusy:{observed=true});media.release()}
            catch {if !observed {throw error}}
            if !observed {Thread.sleep(forTimeInterval:0.02)}
        }
        guard observed else {return XCTFail("The actual sourceff collector never held its media reservation")}
        try prepare();try service!.installNativeWriterAdmission()
        let batch="""
        {"format":"OSwind collector batch","version":1,"collectorID":"dev.example.old34","records":[{"key":"owned-34","timestamp":"2026-10-25T05:23:45.123456-07:00","app":"Owned","bundleID":"dev.example.old34","title":"Owned old34","text":"Must not enter the new native generation"}]}
        """
        try input.fileHandleForWriting.write(contentsOf:Data(batch.utf8));try input.fileHandleForWriting.close()
        let end=ProcessInfo.processInfo.systemUptime+20
        while child.isRunning,ProcessInfo.processInfo.systemUptime<end {Thread.sleep(forTimeInterval:0.02)}
        guard !child.isRunning else {return XCTFail("Old34 collector did not terminate")}
        child.waitUntilExit();XCTAssertNotEqual(child.terminationStatus,0)
        let error=String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
        XCTAssertTrue(error.contains("oswind_native_sync_epoch_v1") || error.contains("writer admission"),error)
        XCTAssertEqual(try library.stats(includeDiskUsage:false).count,1)
        let reopened=try freshStats();XCTAssertNotEqual(reopened.0,0);XCTAssertTrue(reopened.1.contains("newer OSwind version"))
        try library.insert(Memory(id:"current35",text:"Current writer survives old34 refusal"));XCTAssertNotNil(try library.get("current35"))
        XCTAssertEqual(try hash(),expected)
        print("NATIVE35_FROZEN34_FENCE positive33=true alreadyWaitingRefused=true fresh35Refused=true currentWriter=true originalBinaryUnchanged=true")
    }
}
