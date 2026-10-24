import XCTest
@testable import OSwindCore

final class ActivityCalendarIntegrationTests:XCTestCase {
    var root:URL!,store:MemoryStore!
    override func setUpWithError() throws {root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-calendar-api-"+UUID().uuidString);store=try MemoryStore(root:root)}
    override func tearDownWithError() throws {try? store.close();try? FileManager.default.removeItem(at:root)}
    func testMCPToolAdvertisesReadonlyBoundedMetadataInterface() throws {
        let tool=try XCTUnwrap(Integration.tools.first {$0["name"] as? String=="memory_activity"}),schema=try XCTUnwrap(tool["inputSchema"] as? [String:Any]),properties=try XCTUnwrap(schema["properties"] as? [String:Any]),annotations=try XCTUnwrap(tool["annotations"] as? [String:Bool])
        XCTAssertEqual(annotations["readOnlyHint"],true);XCTAssertEqual(schema["additionalProperties"] as? Bool,false);XCTAssertEqual(schema["required"] as? [String],["month"]);XCTAssertNil(properties["query"]);XCTAssertNil(properties["limit"]);XCTAssertNotNil(properties["day"])
    }
    func testStrictParametersRejectQueryUnknownZoneBooleanWeekdayAndWrongTypes() throws {
        let bad:[[String:Any]]=[[:],["month":2024],["month":"2024-03","query":"words"],["month":"2024-03","limit":1],["month":"2024-03","timeZone":"No/SuchZone"],["month":"2024-03","timeZone":true],["month":"2024-03","firstWeekday":true],["month":"2024-03","firstWeekday":2.5],["month":"2024-03","firstWeekday":8],["month":"2024-03","day":1],["month":"2024-03","favorites":1]]
        for args in bad {XCTAssertThrowsError(try Integration.activityRequest(args))}
    }
    func testReadOnlyExecuteAndRPCPublishSameFullCountsWithISOHourBounds() async throws {
        try store.insert(Memory(id:"owned",timestamp:try QueryScopeResolver.instant("2024-11-03T01:30:00-05:00"),app:"Notes",text:"Owned source"))
        let args:[String:Any]=["month":"2024-11","timeZone":"America/New_York","day":"2024-11-03","firstWeekday":2]
        let raw=try await Integration.execute("memory_activity",args:args,store:store,embedder:LocalEmbedder()),result=try XCTUnwrap(raw as? [String:Any])
        XCTAssertEqual(result["totalSources"] as? Int,1);XCTAssertEqual(result["recordedDays"] as? Int,1);XCTAssertEqual((result["days"] as? [Any])?.count,30);XCTAssertEqual((result["hours"] as? [Any])?.count,25)
        let rpc=await Integration.rpc(["jsonrpc":"2.0","id":7,"method":"tools/call","params":["name":"memory_activity","arguments":args]],store:store,embedder:LocalEmbedder());let response=try XCTUnwrap(rpc)
        let payload=try XCTUnwrap(response["result"] as? [String:Any]),content=try XCTUnwrap(payload["content"] as? [[String:Any]]),text=try XCTUnwrap(content.first?["text"] as? String),decoded=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(text.utf8)) as? NSDictionary)
        XCTAssertEqual(decoded,result as NSDictionary)
        let hours=try XCTUnwrap(result["hours"] as? [[String:Any]]);XCTAssertTrue(hours.allSatisfy {$0["start"] is String && $0["end"] is String});XCTAssertEqual(try store.stats().count,1)
    }
}
