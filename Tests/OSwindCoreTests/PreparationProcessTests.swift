import XCTest
import Darwin
@testable import OSwindCore

final class PreparationProcessTests:XCTestCase {
    let python=URL(fileURLWithPath:"/usr/bin/python3")
    var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-preparation-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    func testBothPipesDrainWithoutDeadlockAndAmbientSecretsAreNotInherited() async throws {
        let result=try await PreparationProcess.run(python,["-c","import os,sys;sys.stdout.write('o'*300000);sys.stderr.write('e'*300000);assert 'HOME' not in os.environ"],environment:[:],timeout:10)
        XCTAssertEqual(result.status,0);XCTAssertEqual(result.stdout.count,300000);XCTAssertEqual(result.stderr.count,300000)
    }
    func testChildSignalsAreUnblockedAndSubprocessExitNotificationWorks() async throws {
        let code="import signal,subprocess,sys,threading;blocked=signal.pthread_sigmask(signal.SIG_BLOCK,[]);assert not ({signal.SIGCHLD,signal.SIGINT,signal.SIGTERM}&blocked),repr(blocked);done=threading.Event();signal.signal(signal.SIGCHLD,lambda *_:done.set());p=subprocess.Popen([sys.executable,'-c','pass']);assert done.wait(3),'missing SIGCHLD';assert p.wait()==0"
        let result=try await PreparationProcess.run(python,["-c",code],environment:[:],timeout:10)
        XCTAssertEqual(result.status,0,String(decoding:result.stderr,as:UTF8.self))
    }
    func testExitCodeAndInvalidExecutableOrArgumentsAreExplicit() async throws {
        let failed=try await PreparationProcess.run(python,["-c","raise SystemExit(17)"],environment:[:],timeout:10);XCTAssertEqual(failed.status,17)
        do {_ = try await PreparationProcess.run(root.appendingPathComponent("missing"),[],environment:[:]);XCTFail("Missing executable started")}catch{}
        do {_ = try await PreparationProcess.run(python,["nul\0argument"],environment:[:]);XCTFail("NUL argument accepted")}catch{}
    }
    func testCancellationStopsParentAndTermIgnoringGrandchildBeforeReturning() async throws {try await stopTest(cancel:true)}
    func testGuardianCancellationStopsTermIgnoringGrandchild() async throws {try await stopTest(cancel:true,guarded:true)}
    func testTimeoutStopsTermIgnoringGrandchildBeforeReturning() async throws {try await stopTest(cancel:false)}
    private func stopTest(cancel:Bool,guarded:Bool=false) async throws {
        let marker=root.appendingPathComponent("child.pid"),heartbeat=root.appendingPathComponent("ticks")
        let child="import os,signal,time,sys;signal.signal(signal.SIGTERM,signal.SIG_IGN);open(sys.argv[1],'w').write(str(os.getpid()));f=open(sys.argv[2],'ab',buffering=0);\nwhile True:f.write(b'x');time.sleep(.01)"
        let parent="import subprocess,sys,time;subprocess.Popen([sys.executable,'-c',sys.argv[1],sys.argv[2],sys.argv[3]]);time.sleep(60)"
        let python=self.python,guardian=guarded ? self.guardian:nil,task=Task {try await PreparationProcess.run(python,["-c",parent,child,marker.path,heartbeat.path],environment:[:],timeout:cancel ? 10:1,guardian:guardian)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while !FileManager.default.fileExists(atPath:marker.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
        if cancel {task.cancel()}
        do {_ = try await task.value;XCTFail("Stopped process succeeded")}catch is CancellationError {XCTAssertTrue(cancel)}catch {XCTAssertFalse(cancel,error.localizedDescription)}
        let bytes=(try? Data(contentsOf:heartbeat).count) ?? 0;try await Task.sleep(for:.milliseconds(150))
        XCTAssertEqual((try? Data(contentsOf:heartbeat).count) ?? 0,bytes,"A descendant kept writing after cancellation/timeout")
        if let pid=try? Int32(String(contentsOf:marker,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)) {
            for _ in 0..<100 {if kill(pid,0) != 0 {break};try await Task.sleep(for:.milliseconds(10))}
            XCTAssertNotEqual(kill(pid,0),0,"Owned descendant remained alive")
        }
    }
    var guardian:URL {URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/oswind-preparation-guardian")}
    func testGuardianPreservesNormalExitStatus() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath:guardian.path))
        let result=try await PreparationProcess.run(python,["-c","print('owned output');raise SystemExit(17)"],environment:[:],timeout:5,guardian:guardian)
        XCTAssertEqual(result.status,17,String(decoding:result.stderr,as:UTF8.self));XCTAssertEqual(String(decoding:result.stdout,as:UTF8.self),"owned output\n")
    }
    func testGuardianStopsDescendantsAndReleasesLeaseAfterAbruptParentDeath() async throws {
        let info=root.appendingPathComponent("parent.json"),childPID=root.appendingPathComponent("child.pid"),heartbeat=root.appendingPathComponent("ticks"),lease=root.appendingPathComponent("lease")
        let child="import os,signal,time,sys;signal.signal(signal.SIGTERM,signal.SIG_IGN);open(sys.argv[1],'w').write(str(os.getpid()));f=open(sys.argv[2],'ab',buffering=0);\nwhile True:f.write(b'x');time.sleep(.01)"
        let harness="import os,sys,time,subprocess,json,fcntl;f=open(sys.argv[5],'w');fcntl.flock(f,fcntl.LOCK_EX);r,w=os.pipe();p=subprocess.Popen([sys.argv[1],str(r),str(os.getpgrp()),'--',sys.executable,'-c',sys.argv[2],sys.argv[3],sys.argv[4]],pass_fds=(r,f.fileno()),preexec_fn=lambda:os.setpgid(0,0));os.close(r);f.close();open(sys.argv[6],'w').write(json.dumps(dict(parent=os.getpid(),guardian=p.pid)));time.sleep(60)"
        let python=self.python,guardian=self.guardian,task=Task {try await PreparationProcess.run(python,["-c",harness,guardian.path,child,childPID.path,heartbeat.path,lease.path,info.path],environment:[:],timeout:10)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(5))
        while (!FileManager.default.fileExists(atPath:info.path) || !FileManager.default.fileExists(atPath:childPID.path)),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
        let metadata=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:info)) as? [String:Int32]),parent=try XCTUnwrap(metadata["parent"]),guardPID=try XCTUnwrap(metadata["guardian"])
        XCTAssertEqual(getpgid(parent),parent);XCTAssertEqual(getpgid(guardPID),guardPID)
        // The harness closed its own lease copy before publishing metadata.
        // The guardian must independently retain it until the group is stopped.
        let held=open(lease.path,O_RDWR);XCTAssertGreaterThanOrEqual(held,0)
        if held>=0 {XCTAssertNotEqual(flock(held,LOCK_EX | LOCK_NB),0,"The guardian must retain the caller's cache lease");close(held)}
        XCTAssertEqual(kill(parent,SIGKILL),0)
        let result=try await task.value;XCTAssertEqual(result.status,128+SIGKILL)
        let pid=try XCTUnwrap(Int32(String(contentsOf:childPID,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)))
        for _ in 0..<200 {if kill(pid,0) != 0 && kill(guardPID,0) != 0 {break};try await Task.sleep(for:.milliseconds(10))}
        XCTAssertNotEqual(kill(pid,0),0);XCTAssertNotEqual(kill(guardPID,0),0)
        let count=try Data(contentsOf:heartbeat).count;try await Task.sleep(for:.milliseconds(100));XCTAssertEqual(try Data(contentsOf:heartbeat).count,count)
        let descriptor=open(lease.path,O_RDWR);XCTAssertGreaterThanOrEqual(descriptor,0);defer {if descriptor>=0 {close(descriptor)}}
        XCTAssertEqual(flock(descriptor,LOCK_EX | LOCK_NB),0);flock(descriptor,LOCK_UN)
    }
    func testAlreadyCancelledRequestCannotSpawnOrCreateFiles() async throws {
        let marker=root.appendingPathComponent("never-created"),python=self.python
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            return try await PreparationProcess.run(python,["-c","import sys;open(sys.argv[1],'w').write('unexpected')",marker.path],environment:[:])
        }
        do {_ = try await task.value;XCTFail("Cancelled work started")}catch is CancellationError{}
        XCTAssertFalse(FileManager.default.fileExists(atPath:marker.path))
    }
    func testOutputOverflowStopsWork() async throws {
        do {_ = try await PreparationProcess.run(python,["-c","import sys,time;sys.stdout.write('x'*100000);sys.stdout.flush();time.sleep(60)"],environment:[:],timeout:5,outputLimit:4096);XCTFail("Unbounded output accepted")}catch {XCTAssertTrue(error.localizedDescription.contains("output"))}
    }
}
