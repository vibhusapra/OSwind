import XCTest
import CryptoKit
@testable import OSwindCore

final class PIIDecodingTests:XCTestCase {
    func tensor(_ text:String,assignments:[(Int,Int,Int,Float)]=[])throws->(PIIDecoding.Source,[Float]) {
        let source=try PIIDecoding.Source(text)
        var values=Array(repeating:Float(-20),count:source.words.count*12*3)
        for (word,label,channel,value) in assignments {values[(word*12+label)*3+channel]=value}
        return (source,values)
    }
    func entity(_ start:Int,_ end:Int,_ label:Int=0,_ score:Float=8)->[(Int,Int,Int,Float)] {
        [(start,label,0,score),(end,label,1,score)]+(start...end).map {($0,label,2,score)}
    }
    func decode(_ source:PIIDecoding.Source,_ values:[Float],threshold:Double=0.5)throws->PIIDecoding.Detection {
        try PIIDecoding.decode(source:source,shape:[1,source.words.count,12,3],logits:values,threshold:threshold)
    }
    func testStrictStartEndAndInclusiveInsideThreshold()throws {
        for channel in [0,1] {
            var assignments=entity(0,1);assignments.append((channel==0 ? 0:1,0,channel,0))
            let (source,values)=try tensor("alpha beta",assignments:assignments)
            XCTAssertTrue(try decode(source,values).spans.isEmpty)
        }
        let (source,values)=try tensor("alpha beta",assignments:entity(0,1)+[(0,0,2,0),(1,0,2,0)])
        let result=try decode(source,values);XCTAssertEqual(result.spans.count,1);XCTAssertEqual(result.spans.first?.confidence,0.5)
    }
    func testInsideGapRejectsCrossingSpan()throws {
        let (source,values)=try tensor("alpha beta gamma",assignments:entity(0,2)+[(1,0,2,-0.01)])
        XCTAssertTrue(try decode(source,values).spans.isEmpty)
    }
    func testStableClassAndEndTieOrdering()throws {
        let (source,values)=try tensor("alpha beta",assignments:entity(0,1)+entity(0,0)+entity(0,0,1))
        let result=try decode(source,values);XCTAssertEqual(result.spans.count,1)
        XCTAssertEqual(result.spans.first?.labelIndex,0);XCTAssertEqual(result.spans.first?.endWord,0)
    }
    func testConfidenceWinsOverEarlierOverlappingStart()throws {
        let (source,values)=try tensor("alpha beta gamma",assignments:entity(0,1,0,4)+entity(1,2,1,8))
        let result=try decode(source,values);XCTAssertEqual(result.spans.map(\.startWord),[1]);XCTAssertEqual(result.spans.first?.labelIndex,1)
    }
    func testTokenDecoderDoesNotApplySpanModelWidthCap()throws {
        let text=Array(repeating:"word",count:13).joined(separator:" ")
        let (source,values)=try tensor(text,assignments:entity(0,12))
        XCTAssertEqual(try decode(source,values).spans.first?.endWord,12)
    }
    func testWrongLayoutBatchLabelAndWordDimensionsRefuse()throws {
        let (source,values)=try tensor("owned")
        for shape in [[],[3,1,1,12],[2,1,12,3],[1,2,12,3],[1,1,13,3],[1,1,12,2]] {
            XCTAssertThrowsError(try PIIDecoding.decode(source:source,shape:shape,logits:values,threshold:0.5))
        }
        XCTAssertThrowsError(try decode(source,Array(values.dropLast())))
        XCTAssertThrowsError(try decode(source,values+[0]))
    }
    func testNonfiniteOutputAndInvalidThresholdRefuseWholeResult()throws {
        let (source,values)=try tensor("owned")
        for bad:Float in [.nan,.infinity,-.infinity] {var input=values;input[0]=bad;XCTAssertThrowsError(try decode(source,input))}
        for threshold:Double in [0,1,-1,2,.nan,.infinity,-.infinity] {XCTAssertThrowsError(try decode(source,values,threshold:threshold))}
    }
    func testExtremeFiniteLogitsRemainFinite()throws {
        let (source,values)=try tensor("owned",assignments:entity(0,0,0,.greatestFiniteMagnitude))
        let result=try decode(source,values);XCTAssertEqual(result.spans.first?.confidence,1)
    }
    func testCandidateExplosionRefusesWithoutPartialDetection()throws {
        let source=try PIIDecoding.Source(Array(repeating:"word",count:64).joined(separator:" "))
        let values=Array(repeating:Float(10),count:source.words.count*12*3)
        XCTAssertThrowsError(try decode(source,values)) {XCTAssertTrue(String(describing:$0).contains("budget"))}
    }
    func testSourceAndMaximumWordBounds()throws {
        XCTAssertThrowsError(try PIIDecoding.Source(String(repeating:"a",count:4097)))
        XCTAssertThrowsError(try PIIDecoding.Source(String(repeating:"🦊",count:4097)))
        XCTAssertThrowsError(try PIIDecoding.Source(Array(repeating:"a",count:513).joined(separator:" ")))
        let (source,values)=try tensor(Array(repeating:"a",count:512).joined(separator:" "))
        XCTAssertTrue(try decode(source,values).spans.isEmpty)
    }
    func testCombiningCharacterMaskExpandsWithoutLeakingMark()throws {
        let text="before Cafe\u{301} after",(source,values)=try tensor(text,assignments:entity(1,1,2))
        let detection=try decode(source,values),result=try PIIDecoding.redact(text,detection:detection)
        XCTAssertEqual((text as NSString).substring(with:detection.spans[0].range),"Cafe")
        XCTAssertEqual(result.text,"before [REDACTED] after");XCTAssertTrue(result.suppressMedia)
    }
    func testOverlappingEmojiExpansionsMergeIntoOneWholeMask()throws {
        let text="before 👩🏽‍💻 after",(source,values)=try tensor(text,assignments:entity(2,2,10)+entity(4,4,10))
        let detection=try decode(source,values),result=try PIIDecoding.redact(text,detection:detection)
        XCTAssertEqual(detection.spans.count,2);XCTAssertEqual(result.ranges.count,1)
        XCTAssertEqual(result.text,"before [REDACTED] after")
    }
    func testTouchingMasksMergeAndUnmaskedBytesRemainExact()throws {
        let (source,values)=try tensor("a+b",assignments:entity(0,0)+entity(1,1,1))
        let result=try PIIDecoding.redact("a+b",detection:decode(source,values))
        XCTAssertEqual(result.text,"[REDACTED]b");XCTAssertEqual(result.ranges,[NSRange(location:0,length:2)])
        let text="\u{feff}Cafe\u{301} 🦊",(other,logits)=try tensor(text,assignments:entity(3,3,10))
        let masked=try PIIDecoding.redact(text,detection:decode(other,logits))
        XCTAssertEqual(Array(masked.text.utf8),Array("\u{feff}Cafe\u{301} [REDACTED]".utf8))
    }
    func testByteDifferentCanonicallyEqualOrEditedSourceRefuses()throws {
        let original="Cafe\u{301}",(source,values)=try tensor(original,assignments:entity(0,0))
        let detection=try decode(source,values);XCTAssertEqual(original,"Café")
        for changed in ["Café",original+" ","other"] {XCTAssertThrowsError(try PIIDecoding.redact(changed,detection:detection))}
    }
    func testEmptyWhitespaceAndLiteralMarkerRemainUnmodified()throws {
        for text in [""," \t\r\n","literal [REDACTED]"] {
            let (source,values)=try tensor(text),result=try PIIDecoding.redact(text,detection:decode(source,values))
            XCTAssertEqual(Array(result.text.utf8),Array(text.utf8));XCTAssertFalse(result.redacted);XCTAssertFalse(result.suppressMedia)
        }
    }
    func testAlreadyCancelledDecodeAndRedactionRefuse()async throws {
        let text="owned",(source,values)=try tensor(text,assignments:entity(0,0));let detection=try decode(source,values)
        let task=Task.detached {
            withUnsafeCurrentTask {$0?.cancel()}
            do {_=try PIIDecoding.decode(source:source,shape:[1,source.words.count,12,3],logits:values,threshold:0.5);return false}catch is CancellationError {}catch {return false}
            do {_=try PIIDecoding.redact(text,detection:detection);return false}catch is CancellationError {return true}catch {return false}
        }
        let result=await task.value;XCTAssertTrue(result)
    }
    func testConcurrentSourceDecodingAndMasksStayIsolated()async throws {
        let texts=["alpha beta","before Cafe\u{301} after","a+b","before 👩🏽‍💻 after"]
        try await withThrowingTaskGroup(of:Bool.self) {group in
            for i in 0..<32 {
                let text=texts[i%texts.count]
                group.addTask {
                    let source=try PIIDecoding.Source(text);var logits=Array(repeating:Float(-20),count:source.words.count*36)
                    for channel in 0..<3 {logits[channel]=8}
                    let detection=try PIIDecoding.decode(source:source,shape:[1,source.words.count,12,3],logits:logits,threshold:0.5)
                    let result=try PIIDecoding.redact(text,detection:detection)
                    return result.redacted && detection.sourceSHA256==source.sha256 && result.ranges.first?.location==0
                }
            }
            for try await result in group {XCTAssertTrue(result)}
        }
    }
    func testIndependentNativeLogitsDecoderAndGraphemeReferences()throws {
        struct Range:Decodable {let location:Int,length:Int;var value:NSRange {NSRange(location:location,length:length)}}
        struct Span:Decodable {let startWord:Int,endWord:Int,labelIndex:Int,confidence:Float,range:Range,text:String}
        struct Expected:Decodable {let threshold:Double,spans:[Span],redactionRanges:[Range],redactedText:String}
        struct Row:Decodable {let id:String,text:String,sourceSHA256:String,shape:[Int],logitsBase64:Data,expectations:[Expected]}
        struct Reference:Decodable {let rows:[Row],confidenceAbsoluteTolerance:Float}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures=[("native-decoder-reference-v1.json","9a6b1ef283b902ae16b6b5060339f9c3bea782ca9f45a423fc26e61f39edc30e",92),
                      ("coreml-decoder-reference-v1.json","d83122da7561d6c62d96c0b7c2b1239a1970e0b37759d16ce1a92984aa8d851f",72)]
        for (name,digest,count) in fixtures {
        let data=try Data(contentsOf:root.appendingPathComponent("benchmarks/prototypes/pii/"+name))
        XCTAssertEqual(SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),digest)
        let reference=try JSONDecoder().decode(Reference.self,from:data);XCTAssertEqual(reference.rows.count,count)
        var comparisons=0,maximumConfidenceDifference=Float(0)
        for row in reference.rows {
            let source=try PIIDecoding.Source(row.text);XCTAssertEqual(source.sha256,row.sourceSHA256,row.id)
            let values=row.logitsBase64.withUnsafeBytes {bytes in stride(from:0,to:bytes.count,by:4).map {Float(bitPattern:UInt32(littleEndian:bytes.loadUnaligned(fromByteOffset:$0,as:UInt32.self)))}}
            for expected in row.expectations {
                comparisons+=1
                let detection=try PIIDecoding.decode(source:source,shape:row.shape,logits:values,threshold:expected.threshold)
                XCTAssertEqual(detection.spans.count,expected.spans.count,row.id)
                for (actual,gold) in zip(detection.spans,expected.spans) {
                    XCTAssertEqual(actual.startWord,gold.startWord,row.id);XCTAssertEqual(actual.endWord,gold.endWord,row.id)
                    XCTAssertEqual(actual.labelIndex,gold.labelIndex,row.id);XCTAssertEqual(actual.range,gold.range.value,row.id)
                    XCTAssertEqual(actual.confidence,gold.confidence,accuracy:reference.confidenceAbsoluteTolerance,row.id)
                    maximumConfidenceDifference=max(maximumConfidenceDifference,abs(actual.confidence-gold.confidence))
                    XCTAssertEqual(Array((row.text as NSString).substring(with:actual.range).utf8),Array(gold.text.utf8),row.id)
                }
                let redaction=try PIIDecoding.redact(row.text,detection:detection)
                XCTAssertEqual(redaction.ranges,expected.redactionRanges.map(\.value),row.id)
                XCTAssertEqual(Array(redaction.text.utf8),Array(expected.redactedText.utf8),row.id)
            }
        }
        let metrics:[String:Any]=["fixture":name,"thresholdComparisons":comparisons,"maximumConfidenceDifference":maximumConfidenceDifference]
        print("PII decoder reference metrics: "+String(decoding:try JSONSerialization.data(withJSONObject:metrics,options:.sortedKeys),as:UTF8.self))
        }
    }
}
