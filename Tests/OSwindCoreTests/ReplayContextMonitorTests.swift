import XCTest
import AppKit
import ApplicationServices
@testable import OSwindCore

private final class ReplayTreeCounter {
    var reads=0,bindings=0,messages=0
}
private struct ReplayOwnedTree:AccessibilityTreeSource {
    let root=0
    let counter:ReplayTreeCounter
    func value(_ node:Int,_ attribute:AccessibilityAttribute,budget:AccessibilityReadBudget) throws -> AccessibilityTreeValue<Int>? {
        _ = try budget.message();counter.messages+=1
        if node==0,attribute == .focusedWindow {return .node(1)}
        if node==1,attribute == .title {return .string("Owned replay page")}
        if node==1,attribute == .position {return .point(CGPoint(x:10,y:20))}
        if node==1,attribute == .size {return .size(CGSize(width:640,height:480))}
        if attribute == .role {return .string(node==1 ? kAXWindowRole:kAXStaticTextRole)}
        if node==1,attribute == .children {return .nodes(Array(2...301))}
        if node>1,attribute == .value {return .string("Owned replay observation \(counter.reads) text \(node)")}
        return nil
    }
}

@MainActor final class ReplayContextMonitorTests:XCTestCase {
    private func binding(_ monitor:ReplayContextMonitor,_ context:WindowContext?,unchanged:Bool=true,expected:Bool=true,file:StaticString=#filePath,line:UInt=#line) async {
        let result=await monitor.canKeepBinding(context,intervalUnchanged:unchanged)
        XCTAssertEqual(result,expected,file:file,line:line)
    }
    private var context:WindowContext {
        WindowContext(app:"Owned replay",bundle:"org.oswind.replay-fixture",pid:8123,title:"Owned replay page",accessibilityText:"Owned text",secure:false,bounds:CGRect(x:10,y:20,width:640,height:480))
    }
    func testQuietBoundStreamDoesNotTraverseTreeOnSupervisorPolls() async throws {
        let expected=context,counter=ReplayTreeCounter()
        let environment=ReplayContextEnvironment(available:{_ in true},identityCurrent:{$0.pid==8123 && $1==nil},read:{_ in
            counter.reads+=1
            return try? AccessibilityTraversal.read(ReplayOwnedTree(counter:counter),identity:expected,budget:AccessibilityReadBudget())
        },binding:{_ in
            counter.bindings+=1
            return try? AccessibilityTraversal.read(ReplayOwnedTree(counter:counter),identity:expected,budget:AccessibilityReadBudget(),scope:.binding)
        })
        let monitor=ReplayContextMonitor(target:nil,environment:environment)
        let boundValue=await monitor.fresh(policy:PrivacyPolicy()),bound=try XCTUnwrap(boundValue)
        XCTAssertGreaterThan(counter.messages,1500)
        let initialMessages=counter.messages
        for _ in 0..<120 {await binding(monitor,bound)}
        XCTAssertEqual(counter.reads,1);XCTAssertEqual(counter.bindings,120)
        XCTAssertEqual(counter.messages-initialMessages,120*4)
        XCTAssertEqual(initialMessages,1510)
        print("REPLAY_DUTY quiet polls=120 frames=0 fullReads=\(counter.reads) bindingReads=\(counter.bindings) attributes=\(counter.messages)")
        // These are 120 deterministic scheduler decisions, not elapsed seconds
        // or a measurement of physical screen capture/power.
    }
    func testEachSampleStillMakesFreshBeforeAndAfterObservationsForEveryProfile() async throws {
        for profile in CaptureProfile.allCases {
            let expected=context,counter=ReplayTreeCounter()
            let environment=ReplayContextEnvironment(available:{_ in true},identityCurrent:{_,_ in true},read:{_ in
                counter.reads+=1
                return try? AccessibilityTraversal.read(ReplayOwnedTree(counter:counter),identity:expected,budget:AccessibilityReadBudget())
            },binding:{_ in
                counter.bindings+=1
                return try? AccessibilityTraversal.read(ReplayOwnedTree(counter:counter),identity:expected,budget:AccessibilityReadBudget(),scope:.binding)
            })
            let monitor=ReplayContextMonitor(target:nil,environment:environment)
            let initial=await monitor.fresh(policy:PrivacyPolicy()),bound=try XCTUnwrap(initial)
            let stride=Int(profile.replayInterval(lowPower:false,thermalLimited:false)*2)
            var samples=0
            for tick in 0..<120 {
                await binding(monitor,bound)
                if tick%stride==0 {
                    let before=await monitor.fresh(policy:PrivacyPolicy()),after=await monitor.fresh(policy:PrivacyPolicy())
                    XCTAssertNotEqual(before?.accessibilityText,after?.accessibilityText)
                    XCTAssertEqual(before.map(ReplayContextMonitor.key),after.map(ReplayContextMonitor.key));samples+=1
                }
            }
            XCTAssertEqual(samples,profile == .light ? 12:profile == .balanced ? 60:120)
            XCTAssertEqual(counter.reads,1+samples*2)
            XCTAssertEqual(counter.bindings,120);XCTAssertEqual(counter.messages,counter.reads*1510+120*4)
            print("REPLAY_DUTY \(profile.rawValue) polls=120 frames=\(samples) fullReads=\(counter.reads) bindingReads=\(counter.bindings) attributes=\(counter.messages)")
        }
    }
    func testSessionPermissionIdleIdentityAndPowerChangesRequireRebindingWithoutTreeRead() async {
        var available=true,current=true,reads=0
        let expected=context,monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in available},identityCurrent:{_,_ in current},read:{_ in reads+=1;return expected},binding:{_ in expected}))
        await binding(monitor,expected)
        available=false;await binding(monitor,expected,expected:false)
        available=true;current=false;await binding(monitor,expected,expected:false)
        current=true;await binding(monitor,expected,unchanged:false,expected:false)
        await binding(monitor,nil,expected:false);XCTAssertEqual(reads,0)
    }
    func testCheapBindingIsNeverAFramePrivacyDecision() async {
        let bound=context;var next=bound,reads=0
        let monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in true},identityCurrent:{_,_ in true},read:{_ in reads+=1;return next},binding:{_ in bound}))
        next.secure=true
        await binding(monitor,bound)
        let secure=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNil(secure)
        next=bound;next.title="Incognito owned fixture"
        let privateWindow=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNil(privateWindow)
        next=bound;next.bundle="com.apple.Passwords"
        let excluded=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNil(excluded)
        next=bound;next.bundle="com.google.Chrome";next.url="https://accounts.google.com/owned"
        let domain=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNil(domain)
        next.url=nil
        let missingURL=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNil(missingURL)
        next=bound
        let recovered=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNotNil(recovered);XCTAssertEqual(reads,6)
    }
    func testFrameObservationsDetectSameAppWindowTitleURLBoundsAndPIDChanges() async throws {
        let original=context;var next=original
        let monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in true},identityCurrent:{_,_ in true},read:{_ in next},binding:{_ in next}))
        let before=await monitor.fresh(policy:PrivacyPolicy()),bound=try XCTUnwrap(before)
        for field in 0..<5 {
            next=original
            switch field {
            case 0:next.title="Different owned window"
            case 1:next.url="https://example.org/other"
            case 2:next.bounds=CGRect(x:30,y:40,width:640,height:480)
            case 3:next.bounds=CGRect(x:10,y:20,width:800,height:480)
            default:next.pid=9123
            }
            let after=await monitor.fresh(policy:PrivacyPolicy()),changed=try XCTUnwrap(after)
            XCTAssertNotEqual(ReplayContextMonitor.key(bound),ReplayContextMonitor.key(changed))
            await binding(monitor,bound,expected:field==1)
        }
    }
    func testUnavailableOrChangedIdentityAfterSuspensionCannotReturnObservedContext() async {
        for changeIdentity in [false,true] {
            let entered=XCTestExpectation(description:"owned replay AX suspended")
            var resolve:CheckedContinuation<WindowContext?,Never>?,available=true,current=true
            let expected=context,monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in available},identityCurrent:{_,_ in current},read:{_ in await withCheckedContinuation {resolve=$0;entered.fulfill()}},binding:{_ in XCTFail("Fresh check used binding scope");return nil}))
            let task=Task {await monitor.fresh(policy:PrivacyPolicy())};await fulfillment(of:[entered],timeout:5)
            if changeIdentity {current=false}else {available=false}
            resolve?.resume(returning:expected);let result=await task.value;XCTAssertNil(result)
        }
    }
    func testCancelJoinsSuspendedObservationAndRejectsLateSuccess() async {
        let entered=XCTestExpectation(description:"cancelable replay AX suspended")
        var resolve:CheckedContinuation<WindowContext?,Never>?,returned=false
        let expected=context,monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in true},identityCurrent:{_,_ in true},read:{_ in await withCheckedContinuation {resolve=$0;entered.fulfill()}},binding:{_ in XCTFail("Fresh check used binding scope");return nil}))
        let task=Task {let result=await monitor.fresh(policy:PrivacyPolicy());returned=true;return result}
        await fulfillment(of:[entered],timeout:5);monitor.cancel();await Task.yield();XCTAssertFalse(returned)
        resolve?.resume(returning:expected);let result=await task.value;XCTAssertNil(result);XCTAssertTrue(returned)
    }
    func testBindingReadRejectsSessionChangeIdentityChangeAndCancellationWhileSuspended() async {
        for change in 0..<3 {
            let entered=XCTestExpectation(description:"binding observation suspended")
            var resolve:CheckedContinuation<WindowContext?,Never>?,available=true,current=true,returned=false
            let expected=context,monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in available},identityCurrent:{_,_ in current},read:{_ in XCTFail("Binding read traversed full tree");return nil},binding:{_ in await withCheckedContinuation {resolve=$0;entered.fulfill()}}))
            let task=Task {let result=await monitor.canKeepBinding(expected,intervalUnchanged:true);returned=true;return result}
            await fulfillment(of:[entered],timeout:5)
            if change==0 {available=false}else if change==1 {current=false}else {monitor.cancel()}
            await Task.yield();XCTAssertFalse(returned)
            resolve?.resume(returning:expected);let result=await task.value;XCTAssertFalse(result)
        }
    }
    func testExplicitTargetNeverFallsBackAndCarriesTargetedIdlePolicy() async {
        var targets=[String?](),targeted=[Bool]()
        let monitor=ReplayContextMonitor(target:"org.missing.owned",environment:ReplayContextEnvironment(available:{targeted.append($0);return true},identityCurrent:{_,_ in XCTFail("Missing app cannot have an identity");return false},read:{targets.append($0);return nil},binding:{_ in XCTFail("Missing target cannot keep a binding");return nil}))
        let value=await monitor.fresh(policy:PrivacyPolicy());XCTAssertNil(value)
        XCTAssertEqual(targets,["org.missing.owned"]);XCTAssertTrue(targeted.allSatisfy {$0})
    }
    func testAlreadyCancelledTaskDoesNotStartTreeReadOrKeepBinding() async {
        var reads=0
        let expected=context,monitor=ReplayContextMonitor(target:nil,environment:ReplayContextEnvironment(available:{_ in true},identityCurrent:{_,_ in true},read:{_ in reads+=1;return expected},binding:{_ in XCTFail("Cancelled task started binding read");return nil}))
        let task=Task {() -> WindowContext? in
            withUnsafeCurrentTask {$0?.cancel()}
            await binding(monitor,expected,expected:false)
            return await monitor.fresh(policy:PrivacyPolicy())
        }
        let value=await task.value;XCTAssertNil(value);XCTAssertEqual(reads,0)
    }
}
