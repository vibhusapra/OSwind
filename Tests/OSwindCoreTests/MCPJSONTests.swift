import XCTest
@testable import OSwindCore

final class MCPJSONTests:XCTestCase {
    func testStrictRoundTripPreservesNumbersAndLeadingBOM()throws {
        let raw=Data(#"{"z":1.00e+2,"a":"\ufeffx","b":[true,null,-0]}"#.utf8)
        let value=try MCPValue.decode(raw);XCTAssertEqual(value["a"]?.text,"\u{feff}x");XCTAssertEqual(value,try MCPValue.decode(value.encoded()));XCTAssertTrue(String(decoding:value.encoded(),as:UTF8.self).contains("1.00e+2"))
    }
    func testRejectsDuplicateEscapedAndCanonicallyEquivalentKeys() {
        for raw in [#"{"id":1,"id":2}"#,#"{"id":1,"\u0069d":2}"#,"{\"é\":1,\"e\u{301}\":2}"] {XCTAssertThrowsError(try MCPValue.decode(Data(raw.utf8)),raw)}
    }
    func testRejectsNonJSONNumbersTrailingBytesAndBrokenUTF8() {
        for raw in ["01","+1","NaN","1e999",".5","1.","-","true false","[1,]","{\"x\":1,}","\u{feff}{}"] {XCTAssertThrowsError(try MCPValue.decode(Data(raw.utf8)),raw)}
        XCTAssertThrowsError(try MCPValue.decode(Data([34,255,34])))
    }
    func testDepthNodeAndByteBounds() {
        XCTAssertThrowsError(try MCPValue.decode(Data((String(repeating:"[",count:26)+"0"+String(repeating:"]",count:26)).utf8)))
        XCTAssertThrowsError(try MCPValue.decode(Data(("["+Array(repeating:"0",count:10001).joined(separator:",")+"]").utf8)))
        XCTAssertThrowsError(try MCPValue.decode(Data("{}".utf8),maximum:1))
    }
    func testCommandFileRejectsDuplicateKeysAndUnknownOptions() {
        for raw in [#"{"executable":"/usr/bin/python3","executable":"/evil","arguments":[],"credentialNames":[]}"#,#"{"executable":"/usr/bin/python3","arguments":[],"credentialNames":[],"shell":true}"#] {XCTAssertThrowsError(try MCPServerCommand.decodeConfiguration(Data(raw.utf8)))}
    }
    func testCommandRejectsImplicitShellAndRuntimeEnvironmentOverrides() {
        for path in ["python3","./server","/a\0b"] {XCTAssertThrowsError(try MCPServerCommand(executable:path).validate())}
        for key in ["PATH","HOME","DYLD_INSERT_LIBRARIES","NODE_OPTIONS","PYTHONPATH","foo","XPC_SERVICE_NAME","TOKEN=BAD"] {XCTAssertThrowsError(try MCPServerCommand(executable:"/usr/bin/python3",credentialNames:[key]).validate())}
        XCTAssertThrowsError(try MCPServerCommand(executable:"/usr/bin/python3",credentialNames:["TOKEN","TOKEN"]).validate())
        XCTAssertNoThrow(try MCPServerCommand(executable:"/usr/bin/python3",credentialNames:["API_TOKEN"]).validate())
    }
}
