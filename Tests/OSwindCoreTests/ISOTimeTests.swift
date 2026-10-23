import XCTest
@testable import OSwindCore

final class ISOTimeTests: XCTestCase {
    func testPublicResolutionAndExportRoundTripFractionalBounds() throws {
        for value in ["2026-10-22T12:30:00Z","2026-10-22T12:30:00.125Z","2026-10-22T12:30:00.123456789Z","1969-12-31T23:59:59.875Z","2001-01-01T00:00:00.123456789Z"] {
            let date = try QueryScopeResolver.instant(value), text = try ISOTime.string(date)
            XCTAssertEqual(try QueryScopeResolver.instant(text),date,value)
            let result = try Integration.json(SearchFilter(start:date)) as! [String:Any]
            XCTAssertEqual(try QueryScopeResolver.instant(result["start"] as! String),date)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = try MemoryStore(root:root), date = try QueryScopeResolver.instant("2026-10-22T12:30:00.123456789Z")
        try store.insert(Memory(id:"fraction",timestamp:date,kind:.note,text:"Fractional fixture"))
        let output = root.appendingPathComponent("export.json"); try store.exportJSON(to:output)
        try store.delete("fraction"); _ = try store.importJSON(from:output)
        XCTAssertEqual(try store.get("fraction")?.timestamp,date)
    }
    func testNumericLegacyDatesDecodeAndInvalidDatesDoNotSerialize() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { try ISOTime.decode(from:$0) }
        XCTAssertEqual(try decoder.decode(Date.self,from:Data("0.125".utf8)),Date(timeIntervalSinceReferenceDate:0.125))
        XCTAssertThrowsError(try Integration.json(SearchFilter(start:Date(timeIntervalSinceReferenceDate:.infinity))))
        XCTAssertThrowsError(try ISOTime.string(Date(timeIntervalSinceReferenceDate:0.000000000123)))
    }
}
