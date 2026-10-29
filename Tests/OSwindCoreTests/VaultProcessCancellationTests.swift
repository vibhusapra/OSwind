import XCTest
import Foundation
import Darwin
@testable import OSwindCore

final class VaultProcessCancellationTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-native-action-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    private func helper() throws ->URL {
        let script=root.appendingPathComponent("owned.py")
        let program="""
        import pathlib,os,time
        root=pathlib.Path(\(String(reflecting:root.path)))
        pending=root/'ready.pending';pending.write_text(str(os.getpid()));pending.replace(root/'ready')
        deadline=time.monotonic()+5
        while not (root/'release').exists() and time.monotonic()<deadline:time.sleep(.005)
        if not (root/'release').exists():raise SystemExit(9)
        time.sleep(.1)
        (root/'completed').write_text('owned native mutation finished')
        print('owned-complete',flush=True)
        """
        try program.write(to:script,atomically:true,encoding:.utf8);return script
    }
    private func ready(_ worker:Task<VaultProcessResult,Error>) async throws ->Int32 {
        do {
            let marker=root.appendingPathComponent("ready"),deadline=ContinuousClock.now.advanced(by:.seconds(5))
            while !FileManager.default.fileExists(atPath:marker.path),ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(10))}
            return try XCTUnwrap(Int32(String(contentsOf:marker,encoding:.utf8)))
        } catch {
            worker.cancel();try? Data().write(to:root.appendingPathComponent("release"));_ = try? await worker.value;throw error
        }
    }
    private func requireExited(_ pid:Int32) {
        errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)
    }
    func testNativeActionFinishesMutationAndReapsBeforeReturningCancellation() async throws {
        let script=try helper(),worker=Task {try await VaultProcess.run("/usr/bin/python3",[script.path],cancellation:.finishNativeAction)}
        let pid=try await ready(worker);worker.cancel()
        try Data().write(to:root.appendingPathComponent("release"))
        do {_ = try await worker.value;XCTFail("Cancelled native action published success")}
        catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        XCTAssertEqual(try String(contentsOf:root.appendingPathComponent("completed"),encoding:.utf8),"owned native mutation finished")
        requireExited(pid)
    }
    func testDefaultPolicyStillTerminatesAnOwnedHelperBeforeMutation() async throws {
        let script=try helper(),worker=Task {try await VaultProcess.run("/usr/bin/python3",[script.path])}
        let pid=try await ready(worker);worker.cancel()
        do {_ = try await worker.value;XCTFail("Cancelled cancellable helper succeeded")}
        catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("completed").path));requireExited(pid)
    }
    func testAlreadyCancelledNativeActionNeverLaunches() async throws {
        let script=try helper(),worker=Task {withUnsafeCurrentTask {$0?.cancel()};return try await VaultProcess.run("/usr/bin/python3",[script.path],cancellation:.finishNativeAction)}
        do {_ = try await worker.value;XCTFail("Already cancelled native action launched")}
        catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("ready").path))
    }
    func testCancelledNativeActionRetainsItsDeadlineAndReapsOnTimeout() async throws {
        // Avoid making Python framework startup part of a subsecond deadline.
        // exec preserves the PID recorded before the blocking native action.
        let program="printf '%s' \"$$\" > \"$1/ready.pending\"; /bin/mv \"$1/ready.pending\" \"$1/ready\"; exec /bin/sleep 60"
        let worker=Task {try await VaultProcess.run("/bin/sh",["-c",program,"owned-timeout",root.path],timeout:3,cancellation:.finishNativeAction)}
        let pid=try await ready(worker);worker.cancel()
        do {_ = try await worker.value;XCTFail("Timed out action succeeded")}
        catch {XCTAssertTrue(error.localizedDescription.contains("timed out"))}
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("completed").path));requireExited(pid)
    }
    func testUncancelledNativeActionReturnsStatusAndBoundedOutput() async throws {
        let result=try await VaultProcess.run("/usr/bin/python3",["-c","import sys;print('owned output');sys.stderr.write('owned error');sys.exit(7)"],cancellation:.finishNativeAction)
        XCTAssertEqual(result.status,7);XCTAssertEqual(String(data:result.stdout,encoding:.utf8),"owned output\n");XCTAssertEqual(String(data:result.stderr,encoding:.utf8),"owned error")
    }
    func testEqualNumberNormalExitAndUncaughtSignalAreNotBothCalledExit() async throws {
        for number in [SIGINT,SIGTERM] {
            let normal=try await VaultProcess.run("/usr/bin/python3",["-c","raise SystemExit(\(number))"])
            let signalled=try await VaultProcess.run("/usr/bin/python3",["-c","import os,signal;signal.signal(\(number),signal.SIG_DFL);os.kill(os.getpid(),\(number));raise SystemExit(99)"])
            XCTAssertEqual(normal.status,number);XCTAssertEqual(signalled.status,number)
            XCTAssertEqual(normal.termination,.exit);XCTAssertEqual(signalled.termination,.signal)
            XCTAssertFalse(normal.succeeded);XCTAssertFalse(signalled.succeeded)
            let normalError=VaultNativeFailure(operation:.attachmentInventory,result:normal),signalError=VaultNativeFailure(operation:.attachmentInventory,result:signalled)
            XCTAssertTrue(normalError.localizedDescription.contains("exit \(number)"))
            XCTAssertTrue(signalError.localizedDescription.contains("signal \(number)"),"signal \(number)")
            XCTAssertFalse(signalError.localizedDescription.contains("exit \(number)"),"signal \(number)")
        }
    }
}
