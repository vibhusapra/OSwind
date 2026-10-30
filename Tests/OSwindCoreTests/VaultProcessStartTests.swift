import XCTest
import Foundation
import Darwin
@testable import OSwindCore

private final class OwnedProcessStartGate:@unchecked Sendable {
    let entered:XCTestExpectation
    private let condition=NSCondition()
    private var released=false,pid:Int32=0,timedOut=false
    init(_ entered:XCTestExpectation) {self.entered=entered}
    func started(_ pid:Int32) {
        condition.lock();self.pid=pid;entered.fulfill()
        let deadline=Date().addingTimeInterval(20)
        while !released {if !condition.wait(until:deadline) {timedOut=true;break}}
        condition.unlock()
    }
    func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
    var result:(Int32,Bool) {condition.lock();defer {condition.unlock()};return(pid,timedOut)}
}
private final class OwnedProcessStartCount:@unchecked Sendable {
    private let lock=NSLock();private var count=0
    func record(_ pid:Int32) {lock.lock();count+=1;lock.unlock()}
    var value:Int {lock.lock();defer {lock.unlock()};return count}
}
final class VaultProcessStartTests:XCTestCase {
    func testStartedObserverPrecedesStdinAndNativeCancellationStillFinishesAndReaps() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-start-"+UUID().uuidString);try Paths.ensure(root)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("owned.py"),ready=root.appendingPathComponent("ready"),consumed=root.appendingPathComponent("consumed")
        let program="""
        import pathlib,os,sys
        root=pathlib.Path(\(String(reflecting:root.path)))
        (root/'ready').write_text(str(os.getpid()))
        payload=sys.stdin.buffer.read()
        assert len(payload)>1 and payload[-1]==0
        (root/'consumed').write_text(str(len(payload)))
        print('owned-finished',flush=True)
        """
        try program.write(to:file,atomically:true,encoding:.utf8)
        let gate=OwnedProcessStartGate(expectation(description:"Owned helper launched before stdin")),secret=Data("owned test credential".utf8)
        let worker=Task {try await VaultProcess.run("/usr/bin/python3",[file.path],secret:secret,cancellation:.finishNativeAction,started:{gate.started($0)})}
        do {
            await fulfillment(of:[gate.entered],timeout:10)
            let deadline=ContinuousClock.now.advanced(by:.seconds(10))
            while !FileManager.default.fileExists(atPath:ready.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
            let actualPID=try XCTUnwrap(Int32(String(contentsOf:ready,encoding:.utf8)))
            XCTAssertEqual(gate.result.0,actualPID);XCTAssertEqual(kill(actualPID,0),0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:consumed.path),"Credential delivery preceded the start observation")
            worker.cancel();gate.release()
            do {_ = try await worker.value;XCTFail("Cancelled native action published success")}
            catch is CancellationError {}
            XCTAssertFalse(gate.result.1)
            XCTAssertEqual(try String(contentsOf:consumed,encoding:.utf8),String(secret.count+1))
            errno=0;XCTAssertEqual(kill(actualPID,0),-1);XCTAssertEqual(errno,ESRCH)
        } catch {worker.cancel();gate.release();_ = try? await worker.value;throw error}
    }
    func testLaunchFailureDoesNotPublishAStartedEvent() async {
        let count=OwnedProcessStartCount()
        do {_ = try await VaultProcess.run("/oswind-owned-nonexistent-helper",[],started:{count.record($0)},inputClosed:{count.record($0)});XCTFail("Missing helper launched")}
        catch {}
        XCTAssertEqual(count.value,0)
    }
    func testAlreadyCancelledOperationDoesNotPublishAStartedEvent() async {
        let count=OwnedProcessStartCount(),worker=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            return try await VaultProcess.run("/usr/bin/true",[],cancellation:.finishNativeAction,started:{count.record($0)},inputClosed:{count.record($0)})
        }
        do {_ = try await worker.value;XCTFail("Already-cancelled operation launched")}
        catch is CancellationError {} catch {XCTFail("Unexpected error")}
        XCTAssertEqual(count.value,0)
    }
    func testInputClosedObservationHasDeliveredCredentialsBeforeNativeCompletion() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-input-"+UUID().uuidString);try Paths.ensure(root)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("owned.py"),consumed=root.appendingPathComponent("consumed"),release=root.appendingPathComponent("release")
        let program="""
        import pathlib,os,sys,time
        root=pathlib.Path(\(String(reflecting:root.path)))
        payload=sys.stdin.buffer.read()
        assert len(payload)>1 and payload[-1]==0
        (root/'consumed').write_text(str(len(payload)))
        deadline=time.monotonic()+20
        while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.005)
        assert (root/'release').exists()
        (root/'completed').write_text('owned-finished')
        """
        try program.write(to:file,atomically:true,encoding:.utf8)
        let gate=OwnedProcessStartGate(expectation(description:"Owned helper received EOF")),secret=Data("owned test credential".utf8)
        let worker=Task {try await VaultProcess.run("/usr/bin/python3",[file.path],secret:secret,cancellation:.finishNativeAction,inputClosed:{gate.started($0)})}
        do {
            await fulfillment(of:[gate.entered],timeout:10)
            let deadline=ContinuousClock.now.advanced(by:.seconds(10))
            while !FileManager.default.fileExists(atPath:consumed.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
            XCTAssertEqual(try String(contentsOf:consumed,encoding:.utf8),String(secret.count+1))
            let pid=gate.result.0;XCTAssertGreaterThan(pid,0);XCTAssertEqual(kill(pid,0),0)
            XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("completed").path))
            worker.cancel();try Data().write(to:release);gate.release()
            do {_ = try await worker.value;XCTFail("Cancelled native action published success")}
            catch is CancellationError {}
            XCTAssertFalse(gate.result.1);XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("completed").path))
            errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)
        } catch {worker.cancel();try? Data().write(to:release);gate.release();_ = try? await worker.value;throw error}
    }
}
