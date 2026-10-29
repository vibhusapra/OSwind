import XCTest
@testable import OSwindCore

final class PIIDocumentTests:XCTestCase {
    func plan(_ text:String,limit:Int=16,padded:Bool=false,cost:Int=1)throws->PIIWindowPlan {
        try PIIWindowPlan.make(document:PIIDocument(text),prompt:[50281,50369],tokenLimit:limit,padded:padded) {_ in Array(repeating:1,count:cost)}
    }
    func testEveryWordCoveredWithBoundedOverlapAndCorrectFraming() throws {
        let text=(0..<100).map {"word\($0)"}.joined(separator:" "),source=try PIIDocument(text),result=try plan(text)
        try result.validate(document:source)
        var coverage=Array(repeating:0,count:source.words.count),lastEnd=0
        for window in result.windows {
            XCTAssertLessThanOrEqual(window.input.inputIDs.count,16)
            XCTAssertEqual(window.input.inputIDs.first,50281);XCTAssertEqual(window.input.inputIDs.last,50282)
            XCTAssertEqual(window.input.wordsMask.filter {$0>0},(1...window.wordRange.count).map(Int64.init))
            XCTAssertEqual(window.input.attentionMask,Array(repeating:1,count:window.input.inputIDs.count))
            XCTAssertEqual(window.sourceSHA256,PIIDocument.digest(window.text))
            XCTAssertGreaterThan(window.wordRange.upperBound,lastEnd);lastEnd=window.wordRange.upperBound
            for index in window.wordRange {coverage[index]+=1}
        }
        XCTAssertTrue(coverage.allSatisfy {$0>0});XCTAssertTrue(coverage.contains {$0>1})
        XCTAssertEqual(Set(result.windows.map(\.id)).count,result.windows.count)
        XCTAssertEqual(result.framedTokens,result.windows.reduce(0) {$0+$1.input.inputIDs.count})
    }
    func testRepeatedWindowBytesHaveDistinctDocumentPositions() throws {
        let result=try plan(Array(repeating:"word",count:100).joined(separator:" "))
        XCTAssertEqual(result.windows[0].sourceSHA256,result.windows[1].sourceSHA256)
        XCTAssertNotEqual(result.windows[0].id,result.windows[1].id)
    }
    func testOuterWhitespaceAndShortSourceRemainByteExact() throws {
        let text=" \tCafe\u{301} 👩🏽‍💻\n",result=try plan(text,limit:128)
        XCTAssertEqual(result.windows.count,1);XCTAssertEqual(Array(result.windows[0].text.utf8),Array(text.utf8))
        XCTAssertEqual(result.documentSHA256,PIIDocument.digest(text))
    }
    func testLongWhitespaceGapKeepsOriginalGlobalRangesWithoutTokenCost() throws {
        let text="before"+String(repeating:" ",count:12000)+"after",result=try plan(text)
        XCTAssertEqual(result.windows.count,1);XCTAssertEqual(result.windows[0].input.inputIDs.count,5)
        XCTAssertEqual(result.windows[0].input.words.last?.range.location,12006)
        XCTAssertEqual(Array(result.windows[0].text.utf8),Array(text.utf8))
    }
    func testComposedCharactersNeverSplitAtWindowSeams() throws {
        let text=Array(repeating:"a Cafe\u{301} 👩🏽‍💻 z",count:10).joined(separator:" "),source=try PIIDocument(text),result=try plan(text)
        let original=text as NSString
        for window in result.windows {
            let words=window.input.words,range=NSRange(location:words[0].range.location,length:NSMaxRange(words.last!.range)-words[0].range.location)
            XCTAssertEqual(original.rangeOfComposedCharacterSequences(for:range),range)
        }
        try result.validate(document:source)
    }
    func testOversizedWholeCharacterGroupAndWordRefuseCompletePlan() throws {
        XCTAssertThrowsError(try plan("👩🏽‍💻",limit:6))
        XCTAssertThrowsError(try plan("word",limit:16,cost:14))
        XCTAssertThrowsError(try PIIDocument(String(repeating:"a",count:1025)))
    }
    func testDocumentByteScalarAndWordBoundsRefuseBeforeBackend() throws {
        XCTAssertThrowsError(try PIIDocument(String(repeating:"🦊",count:32769)))
        XCTAssertThrowsError(try PIIDocument(String(repeating:" ",count:32769)))
        XCTAssertThrowsError(try PIIDocument(Array(repeating:"a",count:8193).joined(separator:" ")))
        XCTAssertThrowsError(try PIIDocument(" \n\t"))
        XCTAssertEqual(try PIIDocument("a"+String(repeating:" ",count:32767)).words.count,1)
    }
    func testWorkBudgetsRefuseInsteadOfReturningPrefixWindows() throws {
        let text=Array(repeating:"a",count:800).joined(separator:" ")
        XCTAssertThrowsError(try plan(text,limit:8,cost:5))
        XCTAssertThrowsError(try plan(text,limit:512,padded:true,cost:200))
    }
    func testInvalidPieceIDsAndPromptAreRefused() throws {
        let source=try PIIDocument("owned")
        for ids:[Int64] in [[],[-1],[50370]] {
            XCTAssertThrowsError(try PIIWindowPlan.make(document:source,prompt:[50281],tokenLimit:16) {_ in ids})
        }
        for prompt:[Int64] in [[],[50370],Array(repeating:1,count:16)] {
            XCTAssertThrowsError(try PIIWindowPlan.make(document:source,prompt:prompt,tokenLimit:16) {_ in [1]})
        }
    }
    func testPlanCannotBeReusedForCanonicallyEquivalentDifferentBytes() throws {
        let composed=try PIIDocument("café"),decomposed=try PIIDocument("cafe\u{301}")
        let result=try plan(composed.text)
        XCTAssertThrowsError(try result.validate(document:decomposed))
    }
    func testOversizedNextWordCanRelinquishOverlapWithoutLosingCoverage() throws {
        let source=try PIIDocument("a b c d e large f g h")
        let result=try PIIWindowPlan.make(document:source,prompt:[50281,50369],tokenLimit:8) {Array(repeating:1,count:$0=="large" ? 5:1)}
        try result.validate(document:source)
        XCTAssertTrue(result.windows.contains {$0.wordRange==5..<6})
    }
    func testCancellationStopsPlanningBeforeAnyTokenization() async throws {
        let source=try PIIDocument("owned")
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            return try PIIWindowPlan.make(document:source,prompt:[50281],tokenLimit:16) {_ in XCTFail("Cancelled planner tokenized input");return [1]}
        }
        do {_ = try await task.value;XCTFail("Cancelled plan accepted")} catch is CancellationError {} catch {XCTFail("Unexpected error")}
    }
}
