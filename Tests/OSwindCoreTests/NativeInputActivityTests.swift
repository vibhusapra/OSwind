import XCTest
import CoreGraphics
@testable import OSwindCore

final class NativeInputActivityTests:XCTestCase {
    func testActivityIncludesKeyboardMouseAndTabletRatherThanNullEvents() {
        var state:CGEventSourceStateID?,event:CGEventType?
        let seconds=NativeInputActivity.secondsSinceLastInput {s,e in
            state=s;event=e
            return e.rawValue==UInt32.max ? 4:1_416_474
        }
        XCTAssertEqual(state,.combinedSessionState)
        XCTAssertEqual(event?.rawValue,UInt32.max,"Apple's any-input mask includes keyboard, mouse and tablet; null is a different event type")
        XCTAssertEqual(seconds,4,"An old null event must not hide recent user activity")
    }
    func testInvalidNativeAgesCannotAdmitAutomaticCapture() {
        for raw in [Double.nan,.infinity,-Double.infinity,-1] {
            let seconds=NativeInputActivity.secondsSinceLastInput {_,_ in raw}
            XCTAssertEqual(seconds,.infinity)
            for profile in CaptureProfile.allCases {
                XCTAssertNil(profile.effectiveInterval(lowPower:false,thermalLimited:false,idleSeconds:seconds))
            }
        }
    }
    func testAnyInputAgePreservesTheCaptureBudgetBoundary() {
        for age in [0.0,119.9,120] {
            let seconds=NativeInputActivity.secondsSinceLastInput {_,event in event.rawValue==UInt32.max ? age:1_416_474}
            XCTAssertEqual(CaptureProfile.light.effectiveInterval(lowPower:false,thermalLimited:false,idleSeconds:seconds),20)
        }
        let expired=NativeInputActivity.secondsSinceLastInput {_,_ in 120.01}
        XCTAssertNil(CaptureProfile.light.effectiveInterval(lowPower:false,thermalLimited:false,idleSeconds:expired))
    }
    @MainActor func testDefaultSnapshotEnvironmentReadsTheNativeAnyInputAge() {
        let started=ProcessInfo.processInfo.systemUptime
        let before=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)
        let actual=SnapshotCaptureEnvironment().idleSeconds()
        let after=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)
        let elapsed=ProcessInfo.processInfo.systemUptime-started
        XCTAssertTrue(actual.isFinite && actual>=0)
        XCTAssertLessThanOrEqual(actual,max(before,after)+elapsed+0.5,"A different event counter cannot stand in for the most recent input; queries may straddle new input")
    }
    @MainActor func testDefaultReplayEnvironmentHonorsRecentNativeInput() {
        let enabled = !SessionState.locked && CGPreflightScreenCaptureAccess()
        let before=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)
        let environment=ReplayContextEnvironment(),actual=environment.available(false)
        let after=CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:CGEventType(rawValue:UInt32.max)!)
        if !enabled {XCTAssertFalse(actual)}
        else if before<119.5 && after<119.5 {XCTAssertTrue(actual,"Recent input must allow untargeted replay admission")}
        else if before>120.5 && after>120.5 {XCTAssertFalse(actual)}
        XCTAssertEqual(environment.available(true),enabled,"Explicitly targeted replay keeps its existing idle bypass, not a lock/permission bypass")
    }
}
