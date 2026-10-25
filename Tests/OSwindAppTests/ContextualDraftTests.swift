import XCTest
import ApplicationServices
import OSwindCore
@testable import OSwind

@MainActor final class ContextualDraftTests:XCTestCase {
    final class Transport:DraftInsertionTransport {
        var captured=0,activated=0,writes=[String](),cleared=0,bound=false
        var captureError:Error?,activateError:Error?,writeError:Error?
        let target=DraftDestination(token:UUID(),app:"Fixture editor",bundle:"com.oswind.fixture",title:"Owned document",selectionLength:0,capturedAt:0)
        func capture(privacy:PrivacyPolicy) throws ->DraftDestination {captured+=1;if let captureError {throw captureError};bound=true;return target}
        func activate(_ destination:DraftDestination) throws {XCTAssertEqual(destination,target);activated+=1;if let activateError {throw activateError}}
        func insert(_ text:String,at destination:DraftDestination,privacy:PrivacyPolicy) throws {XCTAssertEqual(destination,target);writes.append(text);if let writeError {throw writeError}}
        func clear(){cleared+=1;bound=false}
    }
    func finish(_ model:ContextualDraftModel) async throws {
        for _ in 0..<1000 where model.busy {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertFalse(model.busy)
    }
    func testRolePrivacyAndProtectedInputAdmission() throws {
        let allowed=DraftTargetFacts(),policy=PrivacyPolicy()
        XCTAssertNoThrow(try DraftInsertionGuard.validate(allowed,privacy:policy))
        var cases=[DraftTargetFacts]()
        for key in [\DraftTargetFacts.locked,\.secureInput,\.protectedAncestor] {var x=allowed;x[keyPath:key]=true;cases.append(x)}
        var x=allowed;x.trusted=false;cases.append(x)
        x=allowed;x.bundle="";cases.append(x)
        x=allowed;x.bundle="com.oswind.desktop";cases.append(x)
        x=allowed;x.bundle="com.apple.Passwords";cases.append(x)
        x=allowed;x.bundle="com.apple.Terminal";cases.append(x)
        x=allowed;x.bundle="com.microsoft.VSCode";cases.append(x)
        x=allowed;x.bundle="com.google.Chrome";cases.append(x)
        x=allowed;x.title="Private browsing";cases.append(x)
        x=allowed;x.role=kAXButtonRole;cases.append(x)
        x=allowed;x.writable=false;cases.append(x)
        for item in cases {XCTAssertThrowsError(try DraftInsertionGuard.validate(item,privacy:policy))}
        var custom=policy;custom.excludedApps=[allowed.bundle];XCTAssertThrowsError(try DraftInsertionGuard.validate(allowed,privacy:custom))
        // Browser refusal remains even with domain-policy checking disabled.
        x=allowed;x.bundle="com.apple.Safari";custom.requireBrowserContext=false;custom.excludedDomains=[]
        XCTAssertThrowsError(try DraftInsertionGuard.validate(x,privacy:custom))
    }
    func testInvalidSelectionAndExpiredDestinationRefused() throws {
        for range in [CFRange(location:-1,length:0),CFRange(location:0,length:-1),CFRange(location:2,length:0),CFRange(location:0,length:2),CFRange(location:Int.max,length:Int.max)] {
            var x=DraftTargetFacts();x.characterCount=1;x.selection=range
            XCTAssertThrowsError(try DraftInsertionGuard.validate(x,privacy:PrivacyPolicy()))
        }
        for time in [Double.nan,Double.infinity,-1,300,301] {XCTAssertThrowsError(try DraftInsertionGuard.validateAge(0,now:time))}
        XCTAssertNoThrow(try DraftInsertionGuard.validateAge(0,now:299.99))
        XCTAssertThrowsError(try DraftInsertionGuard.validateAge(1,now:0))
        XCTAssertThrowsError(try DraftInsertionGuard.validateAge(.nan,now:1))
    }
    func testSelectionTextAndMetadataMutationRefused() throws {
        let original=DraftTargetFacts(),hash=Data([1])
        XCTAssertNoThrow(try DraftInsertionGuard.validateUnchanged(original,original,selectedHash:hash,currentHash:hash))
        var changes=[DraftTargetFacts]()
        var x=original;x.characterCount=4;changes.append(x)
        x=original;x.selection=CFRange(location:1,length:0);changes.append(x)
        x=original;x.title="Another document";changes.append(x)
        x=original;x.bundle="com.other.Editor";changes.append(x)
        x=original;x.protectedAncestor=true;changes.append(x)
        x=original;x.writable=false;changes.append(x)
        for item in changes {XCTAssertThrowsError(try DraftInsertionGuard.validateUnchanged(original,item,selectedHash:hash,currentHash:hash))}
        XCTAssertThrowsError(try DraftInsertionGuard.validateUnchanged(original,original,selectedHash:hash,currentHash:Data([2])))
    }
    func testDraftByteBoundsAndControlCharacters() throws {
        for value in ["", " \n\t", "a\0b", "a\u{1b}b", "a\u{7f}b", "a\u{85}b",String(repeating:"a",count:65_537),String(repeating:"é",count:32_769)] {XCTAssertThrowsError(try DraftInsertionGuard.validateText(value))}
        for value in ["hello\n\tworld\r\n",String(repeating:"é",count:32_768),"👩🏽‍💻 · العربية · हिन्दी"] {XCTAssertNoThrow(try DraftInsertionGuard.validateText(value))}
    }
    func testExplicitEditedSingleAttemptAndNoDuplicateRetry() async throws {
        let transport=Transport(),model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Clipboard touched")})
        var validated=0
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Source answer [1]",sources:[],provider:"fixture",duration:0)) {validated+=1}
        model.text="Edited answer [1]";model.insert(privacy:PrivacyPolicy());model.insert(privacy:PrivacyPolicy());try await finish(model)
        XCTAssertEqual(validated,1);XCTAssertEqual(transport.activated,1);XCTAssertEqual(transport.writes,["Edited answer [1]"]);XCTAssertNil(model.destination);XCTAssertNotNil(model.status)
        model.insert(privacy:PrivacyPolicy());XCTAssertEqual(transport.writes.count,1)
    }
    func testUncertainWriteAcknowledgementConsumesDestination() async throws {
        let transport=Transport();transport.writeError=OSwindError.unavailable("Uncertain acknowledgement")
        let model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Fallback copy")})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0),validate:{})
        model.insert(privacy:PrivacyPolicy());try await finish(model)
        XCTAssertEqual(transport.writes.count,1);XCTAssertNotNil(model.error);XCTAssertNil(model.status);XCTAssertNil(model.destination)
        model.insert(privacy:PrivacyPolicy());XCTAssertEqual(transport.writes.count,1)
    }
    func testMissingEvidencePreventsActivationAndCopy() async throws {
        let transport=Transport(),model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Stale evidence copied")})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Stale draft",sources:[],provider:"fixture",duration:0)) {throw OSwindError.unavailable("Evidence removed")}
        model.insert(privacy:PrivacyPolicy());try await finish(model);model.copy();try await finish(model)
        XCTAssertEqual(transport.activated,0);XCTAssertTrue(transport.writes.isEmpty);XCTAssertNotNil(model.error)
    }
    func testClearDuringActivationPreventsLateWrite() async throws {
        let transport=Transport();var continuation:CheckedContinuation<Void,Never>?
        let model=ContextualDraftModel(transport:transport,settle:{await withCheckedContinuation {continuation=$0}},copy:{_ in XCTFail("Unexpected copy")})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0),validate:{})
        model.insert(privacy:PrivacyPolicy())
        for _ in 0..<1000 where continuation==nil {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertNotNil(continuation);model.clear();continuation?.resume();await Task.yield()
        XCTAssertTrue(transport.writes.isEmpty);XCTAssertTrue(model.text.isEmpty);XCTAssertFalse(model.showing);XCTAssertNil(model.error)
    }
    func testNewShortcutRevokesInFlightHandoff() async throws {
        let transport=Transport();var continuation:CheckedContinuation<Void,Never>?
        let model=ContextualDraftModel(transport:transport,settle:{await withCheckedContinuation {continuation=$0}},copy:{_ in})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0),validate:{})
        model.insert(privacy:PrivacyPolicy());for _ in 0..<1000 where continuation==nil {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertNotNil(continuation);model.chooseDestination(privacy:PrivacyPolicy());continuation?.resume();try await Task.sleep(for:.milliseconds(20))
        XCTAssertTrue(transport.writes.isEmpty);XCTAssertEqual(transport.captured,2);XCTAssertNotNil(model.destination);XCTAssertNil(model.error);XCTAssertTrue(transport.bound,"Cancelled older handoff must not clear a newly captured destination")
    }
    func testCopyWithoutDestinationKeepsCitationMarkers() async throws {
        let transport=Transport();transport.captureError=OSwindError.unavailable("Permission unavailable");var copied=[String]()
        let model=ContextualDraftModel(transport:transport,settle:{},copy:{copied.append($0)})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Reviewed [1]",sources:[],provider:"fixture",duration:0),validate:{})
        XCTAssertNil(model.destination);model.copy();try await finish(model)
        XCTAssertEqual(copied,["Reviewed [1]"]);XCTAssertEqual(transport.activated,0);XCTAssertTrue(transport.writes.isEmpty)
    }
    func testSourceRevisionAndPrivacyRecheckedWithRealStore() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        var copied=[String]();let model=ContextualDraftModel(transport:Transport(),settle:{},copy:{copied.append($0)})
        let app=try AppModel(root:root,startServices:false,drafting:model);defer {app.prepareForLibrarySwitch()}
        var source=Memory(id:"owned-source",app:"Notes",bundleID:"com.oswind.fixture",title:"Owned evidence",text:"Maya owns release.")
        try app.store.insert(source)
        let answer=Answer(text:"Maya owns release [1].",sources:[.init(memory:source,score:1,match:"fixture")],provider:"fixture",duration:0)
        app.reviewDraft(answer);model.copy();try await finish(model);XCTAssertEqual(copied.count,1)
        source.text="Robin owns release.";try app.store.insert(source);model.copy();try await finish(model)
        XCTAssertEqual(copied.count,1);XCTAssertNotNil(model.error)
        app.reviewDraft(answer);app.settings.privacy.excludedApps.append(source.bundleID)
        XCTAssertTrue(model.text.isEmpty);XCTAssertFalse(model.showing)
        app.reviewDraft(answer);model.copy();try await finish(model);XCTAssertEqual(copied.count,1)
    }
    func testActivationAndClipboardFailureDoNotReportSuccess() async throws {
        let transport=Transport();transport.activateError=OSwindError.unavailable("Activation refused")
        let model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in throw OSwindError.unavailable("Clipboard refused")})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0),validate:{})
        model.insert(privacy:PrivacyPolicy());try await finish(model)
        XCTAssertTrue(transport.writes.isEmpty);XCTAssertNil(model.destination);XCTAssertNotNil(model.error);XCTAssertNil(model.status)
        model.copy();try await finish(model);XCTAssertNotNil(model.error);XCTAssertNil(model.status)
    }
    func testClearDuringEvidenceValidationPreventsLateCopyAndActivation() async throws {
        let transport=Transport();var continuation:CheckedContinuation<Void,Never>?
        let model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Late copy")})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0)) {await withCheckedContinuation {continuation=$0}}
        model.insert(privacy:PrivacyPolicy());for _ in 0..<1000 where continuation==nil {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertNotNil(continuation);model.clear();continuation?.resume();await Task.yield()
        XCTAssertEqual(transport.activated,0);XCTAssertTrue(transport.writes.isEmpty);XCTAssertTrue(model.text.isEmpty);XCTAssertNil(model.error)
    }
    func testInvalidEditedTextCannotStartHandoff() async throws {
        let transport=Transport(),model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Invalid copy")})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0),validate:{})
        model.text="bad\u{1b}text";model.copy();model.insert(privacy:PrivacyPolicy())
        XCTAssertFalse(model.busy);XCTAssertNotNil(model.error);XCTAssertEqual(transport.activated,0);XCTAssertTrue(transport.writes.isEmpty)
    }
    func testCrossConnectionDeletionRefusesDraftHandoff() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let transport=Transport(),model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in XCTFail("Deleted evidence copied")})
        let app=try AppModel(root:root,startServices:false,drafting:model);defer {app.prepareForLibrarySwitch()}
        let source=Memory(id:"owned-source",text:"Maya owns release.");try app.store.insert(source)
        app.reviewDraft(Answer(text:"Maya owns release [1].",sources:[.init(memory:source,score:1,match:"fixture")],provider:"fixture",duration:0))
        let other=try MemoryStore(root:root);try other.delete(source.id)
        model.chooseDestination(privacy:PrivacyPolicy());model.insert(privacy:PrivacyPolicy());try await finish(model)
        XCTAssertEqual(transport.activated,0);XCTAssertTrue(transport.writes.isEmpty);XCTAssertNotNil(model.error)
    }
    func testExplicitCancelPreservesEditableDraftAndRevokesPendingWrite() async throws {
        let transport=Transport();var continuation:CheckedContinuation<Void,Never>?
        let model=ContextualDraftModel(transport:transport,settle:{await withCheckedContinuation {continuation=$0}},copy:{_ in})
        model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft [1]",sources:[],provider:"fixture",duration:0),validate:{})
        model.insert(privacy:PrivacyPolicy());for _ in 0..<1000 where continuation==nil {try await Task.sleep(for:.milliseconds(2))}
        XCTAssertNotNil(continuation);model.cancelHandoff();continuation?.resume();try await Task.sleep(for:.milliseconds(20))
        XCTAssertEqual(model.text,"Owned draft [1]");XCTAssertTrue(model.showing);XCTAssertFalse(model.busy);XCTAssertNil(model.destination);XCTAssertFalse(transport.bound);XCTAssertTrue(transport.writes.isEmpty)
    }
    func testLibraryLifecycleClearsDraftAndDestination() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let transport=Transport(),model=ContextualDraftModel(transport:transport,settle:{},copy:{_ in})
        let app=try AppModel(root:root,startServices:false,drafting:model)
        for operation in [app.prepareForLibrarySwitch,app.clearForVaultLock,app.pauseForHistoryErasure] {
            model.chooseDestination(privacy:PrivacyPolicy());model.review(Answer(text:"Owned draft",sources:[],provider:"fixture",duration:0),validate:{})
            operation();XCTAssertTrue(model.text.isEmpty);XCTAssertNil(model.destination);XCTAssertFalse(model.showing)
        }
    }
}
