import XCTest
import CryptoKit
@testable import OSwindCore

final class EntityWordPieceTests:XCTestCase {
    private func tokenizer() throws ->EntityWordPieceTokenizer {
        try .init(vocabulary:["[PAD]":0,"[UNK]":100,"[CLS]":101,"[SEP]":102,"[MASK]":103,"Maya":200,"Chen":201,"Z":202,"##o":203,"##ë":204,"Paris":205,".":206,"中":207,"文":208,"a":209,"##b":210,"x":211,"y":212,",":213])
    }
    func testNamesAndSubwordsRetainExactUTF16Offsets() throws {
        let text="😀 Zoë Maya Chen.",tokens=try tokenizer().tokenize(text)
        XCTAssertEqual(tokens.map(\.id),[100,202,203,204,200,201,206])
        XCTAssertEqual(tokens.map(\.range),[NSRange(location:0,length:2),NSRange(location:3,length:1),NSRange(location:4,length:1),NSRange(location:5,length:1),NSRange(location:7,length:4),NSRange(location:12,length:4),NSRange(location:16,length:1)])
        XCTAssertEqual(tokens.map(\.word),[0,1,1,1,2,3,4])
    }
    func testCaseAndAccentsRemainSignificant() throws {
        let tokens=try tokenizer().tokenize("maya Zoë Zoe")
        XCTAssertEqual(tokens.map(\.id),[100,202,203,204,100])
    }
    func testUnknownPieceReplacesWholeWordWithoutKeepingPartialPrefix() throws {
        let tokens=try tokenizer().tokenize("abc Maya")
        XCTAssertEqual(tokens.map(\.id),[100,200]);XCTAssertEqual(tokens[0].range,NSRange(location:0,length:3))
    }
    func testOneHundredScalarBudgetAndUnknownOversizedWord() throws {
        let exact=try tokenizer().tokenize("a"+String(repeating:"b",count:99));XCTAssertEqual(exact.count,100)
        let tooLong=try tokenizer().tokenize("a"+String(repeating:"b",count:100));XCTAssertEqual(tooLong.map(\.id),[100]);XCTAssertEqual(tooLong[0].range.length,101)
    }
    func testWhitespaceAndPunctuationSplitBasicWords() throws {
        let tokens=try tokenizer().tokenize("Maya\tChen\nParis,\u{00a0}Maya.")
        XCTAssertEqual(tokens.map(\.id),[200,201,205,213,200,206]);XCTAssertEqual(tokens.map(\.word),[0,1,2,3,4,5])
    }
    func testControlsAreRemovedWithOriginalCoordinatesPreserved() throws {
        let tokens=try tokenizer().tokenize("Ma\0ya\u{200d} Chen")
        XCTAssertEqual(tokens.map(\.id),[200,201]);XCTAssertEqual(tokens[0].range,NSRange(location:0,length:5));XCTAssertEqual(tokens[1].range,NSRange(location:7,length:4))
    }
    func testChineseScalarsAndSupplementaryOffsets() throws {
        let tokens=try tokenizer().tokenize("😀中文Paris")
        XCTAssertEqual(tokens.map(\.id),[100,207,208,205]);XCTAssertEqual(tokens[3].range,NSRange(location:4,length:5))
    }
    func testLiteralSpecialTokensDoNotBecomeEvidenceWords() throws {
        let tokens=try tokenizer().tokenize("x[MASK]y")
        XCTAssertEqual(tokens.map(\.id),[211,103,212]);XCTAssertEqual(tokens.map(\.word),[0,nil,1]);XCTAssertEqual(tokens[1].range,NSRange(location:1,length:6))
    }
    func testEmptyAndOnlyRemovedCharactersReturnNoTokens() throws {
        XCTAssertTrue(try tokenizer().tokenize("").isEmpty);XCTAssertTrue(try tokenizer().tokenize(" \n\0\u{fffd}").isEmpty)
    }
    func testInputBoundAndCancelledCallRefuse() async throws {
        XCTAssertThrowsError(try tokenizer().tokenize(String(repeating:"a",count:32769)))
        let task=Task {withUnsafeCurrentTask {$0?.cancel()};return try tokenizer().tokenize("Maya")}
        do {_ = try await task.value;XCTFail("Cancelled tokenizer published output")}catch is CancellationError {}catch {XCTFail("Unexpected \(error)")}
    }
    func testVocabularyRejectsChangedSpecialAndDuplicateIDs() throws {
        XCTAssertThrowsError(try EntityWordPieceTokenizer(vocabulary:["[UNK]":0]))
        XCTAssertThrowsError(try EntityWordPieceTokenizer(vocabulary:["[PAD]":0,"[UNK]":100,"[CLS]":101,"[SEP]":102,"[MASK]":103,"bad":103]))
    }
    func testPinnedVocabularyMatchesIndependentTokenAndOffsetReferences() throws {
        let environment=ProcessInfo.processInfo.environment
        guard let vocabPath=environment["OSWIND_TEST_ENTITY_VOCAB"],let referencePath=environment["OSWIND_TEST_ENTITY_TOKENIZER_REFERENCES"] else {throw XCTSkip("Requires explicit pinned public vocabulary and offline validation references; no download")}
        let vocabularyData=try Data(contentsOf:URL(fileURLWithPath:vocabPath)),referenceData=try Data(contentsOf:URL(fileURLWithPath:referencePath))
        func sha(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
        XCTAssertEqual(sha(vocabularyData),"eeaa9875b23b04b4c54ef759d03db9d1ba1554838f8fb26c5d96fa551df93d02")
        XCTAssertEqual(sha(referenceData),"4a37be51c00dde8318a734f8db95be5614f420a5ec8218088f6a8846b1cf9407")
        guard sha(vocabularyData)=="eeaa9875b23b04b4c54ef759d03db9d1ba1554838f8fb26c5d96fa551df93d02",sha(referenceData)=="4a37be51c00dde8318a734f8db95be5614f420a5ec8218088f6a8846b1cf9407" else {return}
        var words=try XCTUnwrap(String(data:vocabularyData,encoding:.utf8)).components(separatedBy:"\n");if words.last=="" {words.removeLast()};XCTAssertEqual(words.count,28996)
        let actual=try EntityWordPieceTokenizer(vocabulary:Dictionary(uniqueKeysWithValues:words.enumerated().map {($0.element,Int32($0.offset))}))
        struct Reference:Decodable {struct Row:Decodable {struct Token:Decodable {let id:Int32;let start:Int;let length:Int};let id:String;let text:String;let tokens:[Token]};let rows:[Row]}
        let reference=try JSONDecoder().decode(Reference.self,from:referenceData);XCTAssertEqual(reference.rows.count,262)
        for row in reference.rows {
            let tokens=try actual.tokenize(row.text)
            XCTAssertEqual(tokens.map(\.id),row.tokens.map(\.id),row.id)
            XCTAssertEqual(tokens.map(\.range),row.tokens.map {NSRange(location:$0.start,length:$0.length)},row.id)
        }
    }
}
