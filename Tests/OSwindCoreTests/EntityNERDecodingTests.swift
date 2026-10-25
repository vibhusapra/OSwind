import XCTest
@testable import OSwindCore

final class EntityNERDecodingTests:XCTestCase {
    private func token(_ start:Int,_ length:Int,_ word:Int?,_ id:Int32=200)->EntityWordPieceTokenizer.Token {.init(id:id,range:NSRange(location:start,length:length),word:word)}
    private func labels(_ contents:[Int])->[Int] {[0]+contents+Array(repeating:0,count:255-contents.count)}
    func testFirstSubwordOwnsWholeNameAndExactUnicodeAnchor() throws {
        let tokens=[token(3,1,0),token(4,1,0),token(5,1,0),token(7,4,1)]
        let result=try EntityNERDecoder.decode(text:"😀 Zoë Chen",window:.init(tokens:tokens),labels:labels([1,5,3,2]))
        XCTAssertEqual(result,[.init(kind:.person,name:"Zoë Chen",start:3,length:8,method:"coreml-distilbert")])
    }
    func testBeginningLabelsKeepAdjacentPeopleSeparate() throws {
        let result=try EntityNERDecoder.decode(text:"Maya Chen",window:.init(tokens:[token(0,4,0),token(5,4,1)]),labels:labels([1,1]))
        XCTAssertEqual(result.map(\.name),["Maya","Chen"])
    }
    func testInitialContinuationAndKindChangesProduceIndependentSpans() throws {
        let result=try EntityNERDecoder.decode(text:"Maya Apple Paris",window:.init(tokens:[token(0,4,0),token(5,5,1),token(11,5,2)]),labels:labels([2,4,6]))
        XCTAssertEqual(result.map(\.kind),[.person,.organization,.place])
    }
    func testOutsideAndMiscellaneousCloseNamesWithoutCreatingGroups() throws {
        let result=try EntityNERDecoder.decode(text:"Maya met Apple Paris",window:.init(tokens:[token(0,4,0),token(5,3,1),token(9,5,2),token(15,5,3)]),labels:labels([1,0,7,8]))
        XCTAssertEqual(result.map(\.name),["Maya"])
    }
    func testLiteralSpecialCannotBecomeEvidenceOrJoinAdjacentNames() throws {
        let result=try EntityNERDecoder.decode(text:"Maya[MASK]Chen",window:.init(tokens:[token(0,4,0),token(4,6,nil,103),token(10,4,1)]),labels:labels([1,1,2]))
        XCTAssertEqual(result.map(\.name),["Maya","Chen"])
    }
    func testWhitespaceNameNormalizesWhileOriginalRangeStaysExact() throws {
        let result=try EntityNERDecoder.decode(text:"Maya\nChen",window:.init(tokens:[token(0,4,0),token(5,4,1)]),labels:labels([1,2]))
        XCTAssertEqual(result.first?.name,"Maya Chen");XCTAssertEqual(result.first?.length,9)
    }
    func testInvalidControlNameIsSkippedWithoutDroppingOtherNames() throws {
        let result=try EntityNERDecoder.decode(text:"Ma\0ya Paris",window:.init(tokens:[token(0,5,0),token(6,5,1)]),labels:labels([1,5]))
        XCTAssertEqual(result.map(\.name),["Paris"])
    }
    func testBrokenSurrogateOutOfBoundsAndOverlappingTokensRefuse() throws {
        for tokens in [[token(1,1,0)],[token(-1,1,0)],[token(0,99,0)],[token(0,2,0),token(1,2,1)]] {
            XCTAssertThrowsError(try EntityNERDecoder.decode(text:"😀 Maya",window:.init(tokens:tokens),labels:labels(Array(repeating:1,count:tokens.count))))
        }
    }
    func testInvalidLabelCountAndValueRefuse() throws {
        XCTAssertThrowsError(try EntityNERDecoder.decode(text:"Maya",window:.init(tokens:[token(0,4,0)]),labels:[1]))
        XCTAssertThrowsError(try EntityNERDecoder.decode(text:"Maya",window:.init(tokens:[token(0,4,0)]),labels:labels([9])))
    }
    func testWholeWordWindowsMakeProgressAndCoverEveryToken() throws {
        let tokens=(0..<900).map {token($0,1,$0/100)};let windows=try EntityNERWindow.make(tokens)
        XCTAssertGreaterThan(windows.count,1);XCTAssertEqual(Set(windows.flatMap {$0.tokens.map(\.range.location)}),Set(0..<900))
        for window in windows {
            XCTAssertLessThanOrEqual(window.tokens.count,254);XCTAssertEqual(window.inputIDs.count,256);XCTAssertEqual(window.attentionMask.count,256)
            XCTAssertEqual(window.tokens.first!.range.location%100,0);XCTAssertEqual(NSMaxRange(window.tokens.last!.range)%100,0)
            XCTAssertEqual(window.attentionMask.reduce(0,+),Int32(window.tokens.count+2))
        }
    }
    func testWindowsHandleShortOverlapWithoutRepeatingForever() throws {
        let counts=[100,55,100,55,100];var tokens=[EntityWordPieceTokenizer.Token](),offset=0
        for (word,count) in counts.enumerated() {for _ in 0..<count {tokens.append(token(offset,1,word));offset+=1}}
        let windows=try EntityNERWindow.make(tokens);XCTAssertLessThan(windows.count,10);XCTAssertEqual(Set(windows.flatMap {$0.tokens.map(\.range.location)}),Set(0..<offset))
    }
    func testOversizedWordAndTokenInventoryRefuse() throws {
        XCTAssertThrowsError(try EntityNERWindow.make((0..<255).map {token($0,1,0)}))
        XCTAssertThrowsError(try EntityNERWindow.make((0..<32769).map {token($0,1,$0)}))
        XCTAssertTrue(try EntityNERWindow.make([]).isEmpty)
    }
    func testCancellationRefusesWindowsAndDecoder() async throws {
        let task=Task {withUnsafeCurrentTask {$0?.cancel()};return try EntityNERWindow.make([token(0,4,0)])}
        do {_ = try await task.value;XCTFail("Cancelled windows succeeded")}catch is CancellationError {}catch {XCTFail("Unexpected \(error)")}
        let decoding=Task {withUnsafeCurrentTask {$0?.cancel()};return try EntityNERDecoder.decode(text:"Maya",window:.init(tokens:[token(0,4,0)]),labels:labels([1]))}
        do {_ = try await decoding.value;XCTFail("Cancelled decoder succeeded")}catch is CancellationError {}catch {XCTFail("Unexpected \(error)")}
    }
}
