import XCTest
import Darwin
@testable import OSwindCore

final class VaultReadOnlyQueryTests:XCTestCase {
    private final class Clock:@unchecked Sendable {
        private let lock=NSLock()
        private var instant=ContinuousClock.now
        func now()->ContinuousClock.Instant {lock.lock();defer {lock.unlock()};return instant}
        func advance(_ seconds:Double) {lock.lock();instant=instant.advanced(by:.seconds(seconds));lock.unlock()}
    }
    private final class Counter:@unchecked Sendable {
        private let lock=NSLock();private var value=0
        func next()->Int {lock.lock();defer {lock.unlock()};value+=1;return value}
        var count:Int {lock.lock();defer {lock.unlock()};return value}
    }
    private actor Calls {
        let outputs:[VaultProcessResult],action:@Sendable (Int)throws->Void
        var budgets=[Double]()
        init(_ outputs:[VaultProcessResult],action:@escaping @Sendable (Int)throws->Void={_ in}) {self.outputs=outputs;self.action=action}
        func next(_ budget:Double)throws->VaultProcessResult {
            budgets.append(budget);try action(budgets.count)
            guard budgets.count<=outputs.count else {throw OSwindError.invalid("Unexpected third query")}
            return outputs[budgets.count-1]
        }
    }
    private func output(_ termination:VaultProcessTermination = .exit,_ status:Int32=0,_ text:String="fresh")->VaultProcessResult {
        .init(status:status,stdout:Data(text.utf8),stderr:Data(),termination:termination)
    }
    func testEveryReadOnlyOperationCanDiscardOneSIGINTAndReturnFreshOutput() async throws {
        for operation:VaultNativeOperation in [.attachmentInventory,.encryptionProbe,.volumeInfo] {
            let calls=Calls([output(.signal,SIGINT,"partial interrupted body"),output()]),identity=Counter()
            let result=try await VaultReadOnlyQuery.run(operation:operation,validate:{_ = identity.next()},query:{try await calls.next($0)})
            XCTAssertEqual(String(decoding:result.stdout,as:UTF8.self),"fresh");XCTAssertTrue(result.succeeded)
            let budgets=await calls.budgets;XCTAssertEqual(budgets.count,2);XCTAssertEqual(identity.count,4)
        }
    }
    func testNormalErrorsOtherSignalsUnknownAndZeroSignalNeverTriggerRecovery() async throws {
        for result in [output(.exit,2),output(.exit,16),output(.signal,SIGTERM),output(.unknown,2),output(.signal,0),output(.unknown,0)] {
            let calls=Calls([result,output()])
            let returned=try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{},query:{try await calls.next($0)})
            XCTAssertEqual(returned.termination,result.termination);XCTAssertEqual(returned.status,result.status)
            let budgets=await calls.budgets;XCTAssertEqual(budgets.count,1)
        }
    }
    func testMalformedNormalSuccessIsParsedOnceAndRefusedWithoutAnotherQuery() async throws {
        let calls=Calls([output(.exit,0,"not an inventory"),output()])
        let result=try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{},query:{try await calls.next($0)})
        XCTAssertThrowsError(try NativeVaultDriver.attachmentList(result)) {XCTAssertTrue(($0 as? VaultNativeFailure)?.invalidOutput == true)}
        let budgets=await calls.budgets;XCTAssertEqual(budgets.count,1)
    }
    func testRepeatedInterruptAndSecondNormalFailureHaveNoThirdAttempt() async throws {
        for second in [output(.signal,SIGINT),output(.exit,2)] {
            let calls=Calls([output(.signal,SIGINT),second,output()])
            let result=try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{},query:{try await calls.next($0)})
            XCTAssertEqual(result.termination,second.termination);XCTAssertEqual(result.status,second.status)
            XCTAssertThrowsError(try NativeVaultDriver.attachmentList(result))
            let budgets=await calls.budgets;XCTAssertEqual(budgets.count,2)
        }
    }
    func testMutationOperationsCannotEnterQueryRecovery() async throws {
        for operation:VaultNativeOperation in [.imageDetach,.filesystemUnmount] {
            let calls=Calls([output()]),identity=Counter()
            do {_ = try await VaultReadOnlyQuery.run(operation:operation,validate:{_ = identity.next()},query:{try await calls.next($0)});XCTFail("Mutation entered query recovery")}
            catch {XCTAssertTrue(error.localizedDescription.contains("read-only"))}
            let budgets=await calls.budgets;XCTAssertTrue(budgets.isEmpty);XCTAssertEqual(identity.count,0)
        }
    }
    func testInvalidDeadlinePreventsValidationAndProcessLaunch() async throws {
        for timeout in [0.0,-1,.infinity,.nan,60.001] {
            let calls=Calls([output()]),identity=Counter()
            do {_ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,timeout:timeout,validate:{_ = identity.next()},query:{try await calls.next($0)});XCTFail("Invalid budget launched a query")}
            catch {}
            let budgets=await calls.budgets;XCTAssertTrue(budgets.isEmpty);XCTAssertEqual(identity.count,0)
        }
    }
    func testBothAttemptsReceiveOnlyTheirRemainingSharedDeadline() async throws {
        let clock=Clock(),calls=Calls([output(.signal,SIGINT),output()],action:{n in clock.advance(n==1 ? 0.35:0.1)})
        let result=try await VaultReadOnlyQuery.run(operation:.attachmentInventory,timeout:1,validate:{},now:{clock.now()},query:{try await calls.next($0)})
        XCTAssertTrue(result.succeeded)
        let budgets=await calls.budgets;XCTAssertEqual(budgets.count,2);XCTAssertEqual(budgets[0],1,accuracy:1e-9);XCTAssertEqual(budgets[1],0.65,accuracy:1e-9)
    }
    func testSpentValidationBudgetCannotStartAProcess() async throws {
        let clock=Clock(),calls=Calls([output()])
        do {_ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,timeout:1,validate:{clock.advance(1.01)},now:{clock.now()},query:{try await calls.next($0)});XCTFail("Expired validation launched native work")}
        catch {XCTAssertTrue(error.localizedDescription.contains("timed out"))}
        let budgets=await calls.budgets;XCTAssertTrue(budgets.isEmpty)
    }
    func testExpiredSuccessOrInterruptCannotPublishOrStartAnotherProcess() async throws {
        for result in [output(),output(.signal,SIGINT)] {
            let clock=Clock(),calls=Calls([result,output()],action:{_ in clock.advance(1.01)})
            do {_ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,timeout:1,validate:{},now:{clock.now()},query:{try await calls.next($0)});XCTFail("Expired query was admitted")}
            catch {XCTAssertTrue(error.localizedDescription.contains("timed out"))}
            let budgets=await calls.budgets;XCTAssertEqual(budgets.count,1)
        }
    }
    func testAlreadyCancelledQueryNeverValidatesOrLaunches() async throws {
        let calls=Calls([output()]),identity=Counter()
        let task=Task {withUnsafeCurrentTask {$0?.cancel()};return try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{_ = identity.next()},query:{try await calls.next($0)})}
        do {_ = try await task.value;XCTFail("Cancelled query ran")} catch is CancellationError {} catch {throw error}
        let budgets=await calls.budgets;XCTAssertTrue(budgets.isEmpty);XCTAssertEqual(identity.count,0)
    }
    func testCancellationAfterInterruptDoesNotStartRecovery() async throws {
        let calls=Calls([output(.signal,SIGINT),output()],action:{_ in withUnsafeCurrentTask {$0?.cancel()}})
        let task=Task {try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{},query:{try await calls.next($0)})}
        do {_ = try await task.value;XCTFail("Cancelled query retried")} catch is CancellationError {} catch {throw error}
        let budgets=await calls.budgets;XCTAssertEqual(budgets.count,1)
    }
    func testCancellationDuringFinalValidationCannotPublishSuccess() async throws {
        let identity=Counter(),calls=Calls([output()])
        let task=Task {try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{if identity.next()==2 {withUnsafeCurrentTask {$0?.cancel()}}},query:{try await calls.next($0)})}
        do {_ = try await task.value;XCTFail("Validation cancelled but query succeeded")} catch is CancellationError {} catch {throw error}
        let budgets=await calls.budgets;XCTAssertEqual(budgets.count,1)
    }
    func testThrownNativeErrorsAreNotRetried() async throws {
        let calls=Calls([output()],action:{_ in throw POSIXError(.EIO)})
        do {_ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{},query:{try await calls.next($0)});XCTFail("Native launch failure swallowed")}
        catch let error as POSIXError {XCTAssertEqual(error.code,.EIO)}
        let budgets=await calls.budgets;XCTAssertEqual(budgets.count,1)
    }
    func testRemainingDeadlineTerminatesAndReapsARealSecondHelper() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-query-timeout-"+UUID().uuidString)
        try Paths.ensure(root);defer {try? FileManager.default.removeItem(at:root)}
        let marker=root.appendingPathComponent("owned-pid")
        actor RealCalls {
            let marker:URL;var budgets=[Double]()
            init(_ marker:URL) {self.marker=marker}
            func next(_ timeout:Double) async throws ->VaultProcessResult {
                budgets.append(timeout)
                let code:String
                if budgets.count==1 {code="import os,signal,time;time.sleep(.15);signal.signal(signal.SIGINT,signal.SIG_DFL);os.kill(os.getpid(),signal.SIGINT)"}
                else {code="import os,pathlib,time;pathlib.Path(\(String(reflecting:marker.path))).write_text(str(os.getpid()));time.sleep(60)"}
                return try await VaultProcess.run("/usr/bin/python3",["-c",code],timeout:timeout)
            }
        }
        let calls=RealCalls(marker)
        do {_ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,timeout:3,validate:{},query:{try await calls.next($0)});XCTFail("Blocking helper escaped the shared query deadline")}
        catch {XCTAssertTrue(error.localizedDescription.contains("timed out"))}
        let budgets=await calls.budgets;XCTAssertEqual(budgets.count,2)
        if budgets.count==2 {XCTAssertLessThan(budgets[1],budgets[0]-0.1)}
        let pid=try XCTUnwrap(Int32(String(contentsOf:marker,encoding:.utf8)))
        errno=0;XCTAssertEqual(kill(pid,0),-1);XCTAssertEqual(errno,ESRCH)
    }
}

final class VaultQueryIdentityTests:XCTestCase {
    private var root:URL!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-query-identity-"+UUID().uuidString);try Paths.ensure(root)}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    private func paths(image:Bool=true)throws->VaultPaths {
        let package=root.appendingPathComponent(UUID().uuidString+".oswindvault");try Paths.ensure(package)
        let paths=try VaultPaths(package);try paths.write(LibraryVaultInfo(name:"Owned query identity",capacityGiB:1,volumeUUID:UUID().uuidString),as:VaultPaths.manifestName)
        if image {try Paths.ensure(paths.image)};return paths
    }
    func testImageContentsMayChangeButDirectoryIdentityMayNot() throws {
        let paths=try paths(),identity=try VaultQueryIdentity(paths:paths)
        try Data("owned band data".utf8).write(to:paths.image.appendingPathComponent("owned-band"));XCTAssertNoThrow(try identity.validate())
        try FileManager.default.moveItem(at:paths.image,to:paths.package.appendingPathComponent("preserved-original"));try Paths.ensure(paths.image)
        XCTAssertThrowsError(try identity.validate())
    }
    func testManifestReplacementAndPackageReplacementCannotValidate() throws {
        let paths=try paths(),identity=try VaultQueryIdentity(paths:paths)
        var info=try paths.info();info.id=UUID().uuidString.lowercased();try paths.write(info,as:VaultPaths.manifestName)
        XCTAssertThrowsError(try identity.validate())
        let second=try self.paths(),other=try VaultQueryIdentity(paths:second)
        try FileManager.default.moveItem(at:second.package,to:root.appendingPathComponent("preserved-package"));try Paths.ensure(second.package)
        XCTAssertThrowsError(try other.validate())
    }
    func testMissingImageStateIsStableOnlyUntilAnImageAppears() throws {
        let paths=try paths(image:false),identity=try VaultQueryIdentity(paths:paths)
        XCTAssertNoThrow(try identity.validate());try Paths.ensure(paths.image);XCTAssertThrowsError(try identity.validate())
    }
    func testImageDisappearanceAndSymlinksAreNotAnAbsentIdentity() throws {
        let paths=try paths(),identity=try VaultQueryIdentity(paths:paths)
        try FileManager.default.moveItem(at:paths.image,to:paths.package.appendingPathComponent("preserved-image"));XCTAssertThrowsError(try identity.validate())
        try FileManager.default.createSymbolicLink(at:paths.image,withDestinationURL:paths.package.appendingPathComponent("preserved-image"))
        XCTAssertThrowsError(try VaultQueryIdentity(paths:paths))
    }
    func testChangedIdentityAfterInterruptStopsBeforeFreshQuery() async throws {
        let paths=try paths(),identity=try VaultQueryIdentity(paths:paths)
        actor Count {var calls=0;func next(){calls+=1}}
        let count=Count()
        do {
            _ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{try identity.validate()},query:{_ in
                await count.next();try FileManager.default.moveItem(at:paths.image,to:paths.package.appendingPathComponent("preserved-image"));try Paths.ensure(paths.image)
                return .init(status:SIGINT,stdout:Data(),stderr:Data(),termination:.signal)
            });XCTFail("Replaced image was queried again")
        } catch {XCTAssertTrue(error.localizedDescription.contains("identity changed"))}
        let calls=await count.calls;XCTAssertEqual(calls,1)
    }
    func testChangedIdentityBeforeFirstQueryStopsNativeWork() async throws {
        let paths=try paths(),identity=try VaultQueryIdentity(paths:paths)
        var info=try paths.info();info.setupComplete=true;try paths.write(info,as:VaultPaths.manifestName)
        do {_ = try await VaultReadOnlyQuery.run(operation:.attachmentInventory,validate:{try identity.validate()},query:{_ in XCTFail("Query launched after identity change");return .init(status:0,stdout:Data(),stderr:Data())});XCTFail("Changed identity accepted")}
        catch {XCTAssertTrue(error.localizedDescription.contains("identity changed"))}
    }
}
