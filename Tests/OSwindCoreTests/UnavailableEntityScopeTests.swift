import XCTest
@testable import OSwindCore

final class UnavailableEntityScopeTests:XCTestCase {
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
        let restored=try JSONDecoder().decode(SearchFilter.self,from:bytes)
        XCTAssertEqual(restored,unavailable);XCTAssertThrowsError(try restored.requireAvailableEntityScope())
    }
    func testUnavailableNativeFilterCannotExportAsAnUnscopedWireFilter()throws {
        let filter=SearchFilter(unavailableEntityScope:.init())
        XCTAssertThrowsError(try SyncFilterBody(filter,resolve:{_ in XCTFail("Unavailable scope must not look up an active entity");throw OSwindError.invalid("No lookup")}))
    }
    func testMalformedScopeProvenanceCannotDisappearDuringDecoding()throws {
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:SyncProtocolLimits.encode(SearchFilter())) as? [String:Any])
        object["unavailableEntityScope"]=["original":["origin":"invalid","lifetime":"00000000-0000-0000-0000-000000000001"]]
        XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
        object["unavailableEntityScope"]=["projection":["origin":"00000000-0000-0000-0000-000000000001","generation":"00000000-0000-0000-0000-000000000002","group":"00000000-0000-0000-0000-000000000003","epoch":"00000000-0000-0000-0000-000000000004"]]
        XCTAssertThrowsError(try JSONDecoder().decode(SearchFilter.self,from:JSONSerialization.data(withJSONObject:object)))
    }
}
