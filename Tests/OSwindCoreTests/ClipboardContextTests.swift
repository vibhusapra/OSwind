import XCTest
@testable import OSwindCore

final class ClipboardContextTests:XCTestCase {
    let session="00000000-0000-4000-8000-000000000001"
    func context()->WindowContext {.init(app:"Owned editor",bundle:"org.oswind.owned-editor",pid:123,title:"Marigold plan",url:nil,accessibilityText:"not retained",secure:false,bounds:.init(x:1,y:2,width:300,height:200))}
    func snapshot(_ text:String="Mira owns the Marigold release.",types:[String]=["public.utf8-plain-text"],source:String?=nil,count:Int=7,final:Int=7,items:Int=1)->ClipboardTextSnapshot {.init(changeCount:count,finalChangeCount:final,itemCount:items,types:types,text:Data(text.utf8),declaredSource:source)}
    func draft(_ value:ClipboardTextSnapshot?=nil,before:WindowContext?=nil,after:WindowContext?=nil,elapsed:Double=0.01,policy:PrivacyPolicy=PrivacyPolicy())throws->ClipboardTextDraft {
        try .init(snapshot:value ?? snapshot(),before:before ?? context(),after:after ?? context(),sessionID:session,at:Date(timeIntervalSince1970:1800000000),elapsedSeconds:elapsed,policy:policy)
    }
    func testDefaultMissingAndMalformedSettingsStayOff()throws {
        XCTAssertFalse(AppSettings().clipboard.enabled)
        for value in [#"{}"#,#"{"clipboard":"bad"}"#,#"{"clipboard":{"enabled":"yes"}}"#] {XCTAssertFalse(try JSONDecoder().decode(AppSettings.self,from:Data(value.utf8)).clipboard.enabled)}
        var settings=AppSettings();settings.clipboard.enabled=true
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(settings)).clipboard.enabled)
        XCTAssertFalse(LibraryBackup.quietSettings(settings).clipboard.enabled);XCTAssertTrue(settings.clipboard.enabled)
    }
    func testPlainTextDraftLabelsObservedContextWithoutClaimingOrigin()throws {
        let d=try draft(),raw=String(decoding:d.batch,as:UTF8.self)
        XCTAssertTrue(raw.contains("Mira owns"));XCTAssertTrue(raw.contains("Clipboard origin is not verified"));XCTAssertFalse(raw.contains("not retained"));XCTAssertFalse(raw.contains("imagePath"));XCTAssertFalse(raw.contains("audioPath"))
        let bytes=try JSONSerialization.jsonObject(with:d.batch)as! [String:Any],record=(bytes["records"]as! [[String:Any]])[0]
        XCTAssertEqual(record["bundleID"]as? String,context().bundle);XCTAssertNil(record["url"])
    }
    func testProtectedTransientRemoteFileAndImageMarkersRefuse() {
        for marker in ClipboardTextDraft.ignoredTypes {XCTAssertThrowsError(try draft(snapshot(types:["public.utf8-plain-text",marker.uppercased()])))}
        XCTAssertThrowsError(try draft(snapshot(types:["public.html"])));XCTAssertThrowsError(try draft(snapshot(items:2)))
    }
    func testSourceClaimsNeverOverrideForegroundPrivacy()throws {
        let types=["public.utf8-plain-text","org.nspasteboard.source"]
        for source in [nil,"","org.oswind.different"]as [String?] {XCTAssertThrowsError(try draft(snapshot(types:types,source:source)))}
        XCTAssertNoThrow(try draft(snapshot(types:types,source:context().bundle)))
        var policy=PrivacyPolicy();policy.excludedApps.append(context().bundle)
        XCTAssertThrowsError(try draft(snapshot(types:types,source:context().bundle),policy:policy))
    }
    func testMissingBrowserURLExcludedTitleSecureFieldAndSelfRefuse() {
        var c=context();c.bundle="com.apple.Safari";XCTAssertThrowsError(try draft(before:c,after:c));c.url="https://chase.com/account";XCTAssertThrowsError(try draft(before:c,after:c))
        c=context();c.title="Private Window";XCTAssertThrowsError(try draft(before:c,after:c))
        c=context();c.secure=true;XCTAssertThrowsError(try draft(before:c,after:c))
        c=context();c.bundle="com.oswind.desktop";XCTAssertThrowsError(try draft(before:c,after:c))
        c=context();c.title="";XCTAssertThrowsError(try draft(before:c,after:c))
    }
    func testChangedCountIdentityWindowAndTimeoutRefuse() {
        XCTAssertThrowsError(try draft(snapshot(final:8)))
        var c=context();c.pid+=1;XCTAssertThrowsError(try draft(after:c));c=context();c.title+=" edited";XCTAssertThrowsError(try draft(after:c))
        c=context();c.bounds?.origin.x+=1;XCTAssertThrowsError(try draft(after:c))
        for value in [Double.nan,Double.infinity,-1,2.001] {XCTAssertThrowsError(try draft(elapsed:value))}
    }
    func testTextBoundsMalformedUTF8NULAndWhitespaceRefuse() {
        for value in [""," \n\t","a\0b",String(repeating:"x",count:65537)] {XCTAssertThrowsError(try draft(snapshot(value)))}
        let malformed=ClipboardTextSnapshot(changeCount:7,finalChangeCount:7,itemCount:1,types:["public.utf8-plain-text"],text:Data([0xff,0xfe]));XCTAssertThrowsError(try draft(malformed))
    }
    func testSecretPatternsAlwaysDropWholeClipboardEvenWhenGlobalRedactionOff() {
        var policy=PrivacyPolicy();policy.redactSecrets=false
        for value in ["password=owned-secret", "sk-"+String(repeating:"a",count:30),"123-45-6789"] {XCTAssertThrowsError(try draft(snapshot(value),policy:policy))}
    }
    func testStableEventIdentityAndSmallDigestDoNotDuplicateOriginals()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-owned-clipboard-"+UUID().uuidString),store=try MemoryStore(root:root);defer {try? store.close();try? FileManager.default.removeItem(at:root)}
        let a=try draft(),b=try draft(),next=try draft(snapshot(count:8,final:8))
        XCTAssertEqual(a.sourceID,b.sourceID);XCTAssertEqual(a.digest.count,32);XCTAssertEqual(a.digest,next.digest);XCTAssertNotEqual(a.sourceID,next.sourceID)
        _ = try store.importCollectorBatch(a.batch);_ = try store.importCollectorBatch(b.batch)
        XCTAssertEqual(try store.stats().count,1);XCTAssertEqual(try store.get(a.sourceID)?.kind,.note)
        XCTAssertEqual(try store.search(SearchFilter(query:"Marigold")).first?.memory.id,a.sourceID)
    }
}
