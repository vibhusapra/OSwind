import XCTest
@testable import OSwindCore

final class UnavailableEntityScopeTests:XCTestCase {
    func testCalendarScopeAndSnapshotRoundTripsNeverBroadenUnavailableRestriction()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-unavailable-calendar-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        try store.insert(Memory(id:"unrelated",timestamp:QueryScopeResolver.instant("2024-03-10T12:00:00Z"),kind:.note,app:"Owned",text:"Unrelated source"))
        let filter=SearchFilter(unavailableEntityScope:.init()),scope=ActivitySourceScope(filter)
        XCTAssertEqual(scope.filter.unavailableEntityScope,filter.unavailableEntityScope)
        let restored=try JSONDecoder().decode(ActivitySourceScope.self,from:SyncProtocolLimits.encode(scope));XCTAssertEqual(restored.filter.unavailableEntityScope,filter.unavailableEntityScope)
        let snapshot=try store.activityCalendar(.init(month:"2024-03",timeZone:.gmt,selectedDay:"2024-03-10",filter:filter));XCTAssertEqual(snapshot.totalSources,0)
        XCTAssertEqual(snapshot.scope.filter.unavailableEntityScope,filter.unavailableEntityScope);XCTAssertEqual(try store.matchingCount(snapshot.scope.filter),0)
        XCTAssertThrowsError(try QueryScopeResolver.resolve(snapshot.scope.filter))
        let plain=ActivitySourceScope(SearchFilter());XCTAssertNotEqual(scope,plain,"Unavailable scope must not share an unrestricted calendar cache key")
    }
    func testMarkdownSavedHistoryLabelsUnavailableEntityInsteadOfAnyEntity()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-unavailable-export-"+UUID().uuidString);defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        let entity=try store.createEntity(kind:.project,name:"Owned original scope"),chat=try store.createChat(title:"Owned exported answer")
        _=try store.appendChatTurn(sessionID:chat.id,question:"Exact question",answer:.init(text:"Exact answer 👩🏽‍💻 e\u{301}",sources:[],provider:"owned",duration:0),filter:.init(entityID:entity.id));try store.deleteEntity(entity.id)
        let markdown=ConversationContext.markdown(try XCTUnwrap(store.chat(chat.id)),turns:try store.chatTurns(chat.id))
        XCTAssertTrue(markdown.contains("Exact answer 👩🏽‍💻 e\u{301}"));XCTAssertTrue(markdown.contains("Entity: unavailable"));XCTAssertFalse(markdown.contains("Entity: any"))
    }
    func testUnavailableRestrictionRefusesSearchAndCannotMatchUnrelatedContent()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("owned-unavailable-scope-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try MemoryStore(root:root);defer {try? store.close()}
        try store.insert(Memory(id:"unrelated",kind:.note,app:"Owned",title:"Unrelated",text:"Owned unrelated content"))
        XCTAssertEqual(try store.matchingCount(),1)
        let filter=SearchFilter(unavailableEntityScope:.init())
        XCTAssertThrowsError(try store.search(filter,mode:.keyword)) {error in
            guard case OSwindError.unavailable=error else {return XCTFail("Unexpected scope error: \(error)")}
        }
        XCTAssertEqual(try store.matchingCount(filter),0)
        XCTAssertTrue(try store.timelineSample(filter).isEmpty)
        XCTAssertEqual(try store.vectorCount(modelID:"owned",filter:filter),0)
    }
    func testUnavailableRestrictionRefusesBeforeScopeParsingOrAppLookup()throws {
        let filter=SearchFilter(query:String(repeating:"x",count:5000),app:"Owned",unavailableEntityScope:.init())
        XCTAssertThrowsError(try QueryScopeResolver.resolve(filter,canonicalApp:{_ in XCTFail("Unavailable scopes must not resolve apps");return "Owned"})) {error in
            guard case OSwindError.unavailable=error else {return XCTFail("Expected the unavailable scope before query parsing")}
        }
    }
    func testUnavailableScopeSurvivesNativeFilterRoundTripAndNilKeepsOldShape()throws {
        let ordinary=SearchFilter(entityID:"owned-live-entity"),old=try SyncProtocolLimits.encode(ordinary)
        XCTAssertNil((try JSONSerialization.jsonObject(with:old) as? [String:Any])?["unavailableEntityScope"])
        XCTAssertEqual(try JSONDecoder().decode(SearchFilter.self,from:old),ordinary)
        let unavailable=SearchFilter(unavailableEntityScope:.init()),bytes=try SyncProtocolLimits.encode(unavailable)
        XCTAssertNotNil((try JSONSerialization.jsonObject(with:bytes) as? [String:Any])?["unavailableEntityScope"])
        XCTAssertEqual(((try JSONSerialization.jsonObject(with:bytes) as? [String:Any])?["entityID"] as? [String:String])?["state"],"unavailable")
        let restored=try JSONDecoder().decode(SearchFilter.self,from:bytes)
        XCTAssertEqual(restored,unavailable);XCTAssertThrowsError(try restored.requireAvailableEntityScope())
    }
    func testUnavailableNativeSelectorCannotLoseItsRestrictionOrHaveAnActiveID()throws {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:SyncProtocolLimits.encode(SearchFilter(unavailableEntityScope:.init()))) as? [String:Any])
        object.removeValue(forKey:"unavailableEntityScope");XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
        object["unavailableEntityScope"]=[String:String]();object["entityID"]="active-entity";XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
        object["entityID"]=["state":"unknown"];XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
        XCTAssertThrowsError(try SyncProtocolLimits.encode(SearchFilter(entityID:"active-entity",unavailableEntityScope:.init())))
    }
    func testUnavailableNativeFilterCannotExportAsAnUnscopedWireFilter()throws {
        let filter=SearchFilter(unavailableEntityScope:.init())
        let wire=try SyncFilterBody(filter,resolve:{_ in XCTFail("Unavailable scope must not look up an active entity");throw OSwindError.invalid("No lookup")})
        XCTAssertNil(wire.entity);XCTAssertNotNil(wire.unavailableEntityScope)
        let decoded=try JSONDecoder().decode(SyncFilterBody.self,from:SyncProtocolLimits.encode(wire)),restored=try decoded.projected { _ in XCTFail("Unavailable provenance is not a lookup");return "unused" }
        XCTAssertNotNil(restored.unavailableEntityScope);XCTAssertThrowsError(try restored.requireAvailableEntityScope())
    }
    func testWireUnavailableProvenanceHasNoProjectionAuthorityOrEntityDependency()throws {
        let origin="00000000-0000-0000-0000-000000006201",lifetime="00000000-0000-0000-0000-000000006202"
        let reference=try UnavailableEntityScope.Reference(origin:origin,lifetime:lifetime)
        let marker=try UnavailableEntityScope(original:reference,projection:.init(origin:origin,generation:lifetime,group:origin,epoch:lifetime)),wire=try SyncFilterBody(SearchFilter(unavailableEntityScope:marker),resolve:{_ in throw OSwindError.invalid("No active entity")})
        let bytes=try SyncProtocolLimits.encode(wire)
        XCTAssertFalse(String(decoding:bytes,as:UTF8.self).contains("projection"))
        let restored=try wire.projected { _ in XCTFail("Provenance must not request an active definition");return "unused" }
        XCTAssertEqual(restored.unavailableEntityScope?.original,reference);XCTAssertNil(restored.unavailableEntityScope?.projection)
        let parent=try SyncPortableRecord(identity:.init(table:.conversation,origin:origin,lifetime:lifetime),body:.conversation(.init(title:"Owned",created:Date(timeIntervalSince1970:1700000000),updated:Date(timeIntervalSince1970:1700000000))))
        let record=try SyncPortableRecord(identity:.init(table:.turn,origin:origin,lifetime:"00000000-0000-0000-0000-000000006203"),body:.turn(.init(conversation:parent.identity,timestamp:Date(timeIntervalSince1970:1700000000),question:"Owned",text:"Answer",provider:"owned",duration:0,warnings:[],filter:wire,timeZone:nil)))
        XCTAssertEqual(record.dependencies.map(\.identity),[parent.identity])
        XCTAssertNoThrow(try record.validateDependencies {id,_ in XCTAssertEqual(id,parent.identity);return parent})
        XCTAssertThrowsError(try record.validateDependencies {_,_ in throw OSwindError.unavailable("Owning conversation still required")})
        XCTAssertEqual(try SyncPortableRecord.decode(record.encoded()),record)
    }
    func testMalformedScopeProvenanceCannotDisappearDuringDecoding()throws {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:SyncProtocolLimits.encode(SearchFilter())) as? [String:Any])
        object["unavailableEntityScope"]=["original":["origin":"invalid","lifetime":"00000000-0000-0000-0000-000000000001"]]
        XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
        object["unavailableEntityScope"]=["projection":["origin":"00000000-0000-0000-0000-000000000001","generation":"00000000-0000-0000-0000-000000000002","group":"00000000-0000-0000-0000-000000000003","epoch":"00000000-0000-0000-0000-000000000004"]]
        XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
    }
}
