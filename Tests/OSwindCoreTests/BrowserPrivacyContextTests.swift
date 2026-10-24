import XCTest
@testable import OSwindCore

final class BrowserPrivacyContextTests:XCTestCase {
    func testRootDotAndEncodedHostCannotBypassDomainRules() {
        var policy=PrivacyPolicy();policy.excludedDomains=[" Private.Example. "]
        for url in ["https://private.example/","https://PRIVATE.EXAMPLE./path","https://sub.private.example./path","https://pr%69vate.example/path"] {
            XCTAssertNotNil(policy.exclusion(app:"browser",title:"",url:url,isBrowser:true),url)
        }
        for url in ["https://notprivate.example/","https://private.example.evil.test/","https://private.example@evil.test/path"] {
            XCTAssertNil(policy.exclusion(app:"browser",title:"",url:url,isBrowser:true),url)
        }
        policy.excludedDomains=["private.example"]
        XCTAssertNotNil(policy.exclusion(app:"browser",title:"",url:"https://private.example./",isBrowser:true))
        XCTAssertNotNil(policy.exclusion(app:"browser",title:"",url:"https://sub.private.example./",isBrowser:true))
    }
    func testUnicodeAndIDNARepresentationsShareDomainExclusions() {
        for domain in ["bücher.example","xn--bcher-kva.example"] {
            var policy=PrivacyPolicy();policy.excludedDomains=[domain]
            for url in ["https://bücher.example/","https://xn--bcher-kva.example/","https://sub.bücher.example./"] {
                XCTAssertNotNil(policy.exclusion(app:"browser",title:"",url:url,isBrowser:true),domain+" "+url)
            }
        }
    }
    func testRequiredBrowserContextRejectsMissingInvalidAndNonWebURLs() {
        let policy=PrivacyPolicy()
        for url:String? in [nil,"","not a URL","https://","about:blank","chrome://newtab","file:///owned.pdf"] {
            XCTAssertNotNil(policy.exclusion(app:"browser",title:"",url:url,isBrowser:true),String(describing:url))
        }
        XCTAssertNil(policy.exclusion(app:"browser",title:"",url:"https://example.org/",isBrowser:true))
        XCTAssertNil(policy.exclusion(app:"browser",title:"",url:"http://localhost:8080/",isBrowser:true))
    }
    func testExplicitContextOptOutAndNoDomainRulesRemainAvailable() {
        var policy=PrivacyPolicy();policy.requireBrowserContext=false
        XCTAssertNil(policy.exclusion(app:"browser",title:"",url:nil,isBrowser:true))
        policy.requireBrowserContext=true;policy.excludedDomains=[]
        XCTAssertNil(policy.exclusion(app:"browser",title:"",url:nil,isBrowser:true))
        XCTAssertNil(policy.exclusion(app:"native",title:"",url:nil,isBrowser:false))
        policy.excludedDomains=["private.example"]
        XCTAssertNotNil(policy.exclusion(app:"native",title:"",url:"https://private.example./",isBrowser:false))
    }
}
