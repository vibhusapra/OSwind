import XCTest
@testable import OSwindCore

final class FocusedWindowBindingTests:XCTestCase {
    let focused=CGRect(x:100,y:100,width:1000,height:640)
    func context(title:String="Focused",bounds:CGRect?=nil)->WindowContext {WindowContext(app:"Fixture",bundle:"org.oswind.fixture",pid:1,title:title,url:nil,accessibilityText:"",secure:false,bounds:bounds)}
    func testMissingExplicitFocusedWindowCannotFallBackToAnotherWindow() {
        let other=CaptureWindowDescriptor(frame:CGRect(x:10,y:10,width:700,height:500),title:"Other")
        XCTAssertNil(FocusedWindowBinding.select([other],context:context(bounds:focused)))
        XCTAssertNil(FocusedWindowBinding.select([other],context:context()))
    }
    func testGeometryBindsOnlyTheUnambiguousFocusedSource() {
        let windows=[CaptureWindowDescriptor(frame:CGRect(x:10,y:10,width:700,height:500),title:"Focused"),CaptureWindowDescriptor(frame:focused,title:"Different system title")]
        XCTAssertEqual(FocusedWindowBinding.select(windows,context:context(bounds:focused)),1)
        XCTAssertNil(FocusedWindowBinding.select([windows[1],windows[1]],context:context(bounds:focused)))
        var invalid=focused;invalid.size.width = .infinity
        XCTAssertNil(FocusedWindowBinding.select(windows,context:context(bounds:invalid)))
    }
    func testMissingAccessibilityMetadataRequiresSingleCandidate() {
        let window=CaptureWindowDescriptor(frame:focused,title:"Native fixture")
        XCTAssertEqual(FocusedWindowBinding.select([window],context:context(title:"")),0)
        XCTAssertNil(FocusedWindowBinding.select([window,window],context:context(title:"")))
        XCTAssertEqual(FocusedWindowBinding.select([window],context:context(title:"Native fixture")),0)
        XCTAssertNil(FocusedWindowBinding.select([window,window],context:context(title:"Native fixture")))
    }
}
