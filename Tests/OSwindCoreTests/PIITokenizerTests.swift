import XCTest
import Hub
@testable import OSwindTokenizers
import CryptoKit
@testable import OSwindCore

final class PIITokenizerTests:XCTestCase {
    func testByteLevelPrefixIsAddedOnceBeforeRegexSplitting()throws {
        let data=Data(#"{"pre_tokenizer":{"type":"ByteLevel","add_prefix_space":true,"use_regex":true},"model":{"type":"BPE","vocab":{"Ġ":0,"a":1,"-":2,"b":3},"merges":[]}}"#.utf8)
        let config=Config(["tokenizer_class":"PreTrainedTokenizer"])
        let tokenizer=try PreTrainedTokenizer(tokenizerConfig:config,tokenizerData:VisualTokenizerData.decode(data),strict:true)
        XCTAssertEqual(tokenizer.encode(text:"a-b",addSpecialTokens:false),[0,1,2,3])
        XCTAssertEqual(tokenizer.encode(text:" a-b",addSpecialTokens:false),[0,1,2,3])
    }
    func testByteLevelEmptyAndCombiningPrefixMatchIndependentRustReference()throws {
        let preTokenizer=ByteLevelPreTokenizer(config:Config(["add_prefix_space":true,"use_regex":true]))
        XCTAssertEqual(preTokenizer.preTokenize(text:"",options:[]),[])
        XCTAssertEqual(preTokenizer.preTokenize(text:" \u{301}a",options:[]),["ĠÌģ","a"])
        XCTAssertEqual(preTokenizer.preTokenize(text:"\u{301}a",options:[]),["ĠÌģ","a"])
        let unprefixed=ByteLevelPreTokenizer(config:Config(["add_prefix_space":false,"use_regex":true]))
        XCTAssertEqual(unprefixed.preTokenize(text:"a-b",options:[]),["a","-","b"])
        let noRegex=ByteLevelPreTokenizer(config:Config(["add_prefix_space":true,"use_regex":false]))
        XCTAssertEqual(noRegex.preTokenize(text:"",options:[]),[])
        XCTAssertEqual(noRegex.preTokenize(text:" \u{301}a",options:[]),["ĠÌģa"])
    }
    func testWordSplitterUsesScalarOffsetsAndPythonHyphenRules()throws {
        let input="🔒 a-b a--b _foo-bar Cafe\u{301} 👩🏽‍💻"
        let words=try PIITokenizer.split(input)
        XCTAssertEqual(words.map(\.text),["🔒","a-b","a","-","-","b","_foo-bar","Cafe","\u{301}","👩","🏽","\u{200d}","💻"])
        for word in words {
            XCTAssertEqual(Array((input as NSString).substring(with:word.range).utf8),Array(word.text.utf8))
        }
        XCTAssertEqual(words[1].range,NSRange(location:3,length:3))
        // Intermediate model words deliberately differ from composed characters.
        XCTAssertNil(PassageRange(start:words[8].range.location,length:words[8].range.length).text(in:input))
    }
    func testWhitespaceMatchesPinnedPythonIncludingInformationSeparators()throws {
        let values:[UInt32]=Array(9...13)+Array(28...32)+[0x85,0xa0,0x1680]+Array(0x2000...0x200a)+[0x2028,0x2029,0x202f,0x205f,0x3000]
        for value in values {
            let text="a"+String(Unicode.Scalar(value)!)+"b"
            XCTAssertEqual(try PIITokenizer.split(text).map(\.text),["a","b"],"Whitespace \(value)")
        }
        XCTAssertEqual(try PIITokenizer.split("a\u{200b}b").count,3)
    }
    func testWordClassesDoNotChangeWithHostUnicodeVersion()throws {
        XCTAssertEqual(try PIITokenizer.split("x\u{1c89}y ²Ⅳ½ _x").map(\.text),["x","\u{1c89}","y","²Ⅳ½","_x"])
        XCTAssertEqual(PIIWordCharacters.ranges.count,748)
    }
    func testOversizedSourcesRefuseWithoutPartialResults()throws {
        XCTAssertThrowsError(try PIITokenizer.split(String(repeating:"a",count:4097)))
        XCTAssertThrowsError(try PIITokenizer.split(String(repeating:"🦊",count:4097)))
        XCTAssertEqual(try PIITokenizer.split(" \t\r\n"),[])
    }
    func testChangedAssetsRefuseBeforeTokenizerConstruction()throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data("{}".utf8).write(to:root.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(to:root.appendingPathComponent("tokenizer_config.json"))
        XCTAssertThrowsError(try PIITokenizer(directory:root))
    }
    func testAlreadyCancelledSplittingAndLoadingRefuseBeforeIO()async throws {
        let task=Task.detached {
            withUnsafeCurrentTask {$0?.cancel()}
            do {_=try PIITokenizer.split("owned");return false}catch is CancellationError {}catch {return false}
            do {_=try PIITokenizer(directory:URL(fileURLWithPath:"/nonexistent-owned-pii-tokenizer"));return false}catch is CancellationError {return true}catch {return false}
        }
        let result=await task.value;XCTAssertTrue(result)
    }
    func testPinnedTokenizerMatchesIndependentGLiNERAndRustTensors()throws {
        let env=ProcessInfo.processInfo.environment
        guard let directory=env["OSWIND_TEST_PII_TOKENIZER_DIR"],let reference=env["OSWIND_TEST_PII_TOKENIZER_REFERENCE"] else {
            throw XCTSkip("Opt-in pinned local tokenizer and independent GLiNER/Rust references; no downloads or weights")
        }
        struct Word:Decodable {let text:String,location:Int,length:Int}
        struct Row:Decodable {let id:String,text:String,words:[Word],inputIDs:[Int64],attentionMask:[Int64],wordsMask:[Int64],textLength:Int64}
        struct Reference:Decodable {let rows:[Row],labels:[String],wordClassRanges:[[UInt32]]}
        let data=try Data(contentsOf:URL(fileURLWithPath:reference))
        XCTAssertEqual(SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),"38303b8a7caf42592966e850cad0d6f3d054b177a1c914bb25d8580da535b412")
        let gold=try JSONDecoder().decode(Reference.self,from:data)
        XCTAssertEqual(gold.rows.count,181);XCTAssertEqual(gold.labels,PIITokenizer.labels)
        XCTAssertEqual(PIIWordCharacters.ranges.map {[$0.0,$0.1]},gold.wordClassRanges)
        let tokenizer=try PIITokenizer(directory:URL(fileURLWithPath:directory))
        for row in gold.rows {
            let actual=try tokenizer.encode(row.text)
            XCTAssertEqual(actual.inputIDs,row.inputIDs,row.id);XCTAssertEqual(actual.attentionMask,row.attentionMask,row.id)
            XCTAssertEqual(actual.wordsMask,row.wordsMask,row.id);XCTAssertEqual(actual.textLength,row.textLength,row.id)
            XCTAssertEqual(actual.words.count,row.words.count,row.id)
            for (word,reference) in zip(actual.words,row.words) {
                XCTAssertEqual(Array(word.text.utf8),Array(reference.text.utf8),row.id)
                XCTAssertEqual(word.range,NSRange(location:reference.location,length:reference.length),row.id)
            }
        }
        XCTAssertThrowsError(try tokenizer.encode(" \t\n"))
        XCTAssertThrowsError(try tokenizer.encode(String(repeating:"a",count:1025)))
        XCTAssertThrowsError(try tokenizer.encode(Array(repeating:"123456789",count:200).joined(separator:" ")))
    }
    func testConcurrentEncodingKeepsImmutableSourceTensors()async throws {
        guard let directory=ProcessInfo.processInfo.environment["OSWIND_TEST_PII_TOKENIZER_DIR"] else {throw XCTSkip("Opt-in verified local tokenizer; no downloads")}
        let tokenizer=try PIITokenizer(directory:URL(fileURLWithPath:directory))
        let texts=["a-b","Cafe\u{301} 👩🏽‍💻","owned.person@example.test","password=OwnedOnly-42!"]
        let expected=try texts.map {try tokenizer.encode($0)}
        try await withThrowingTaskGroup(of:Bool.self) {group in
            for i in 0..<32 {
                let index=i%texts.count,text=texts[index],gold=expected[index]
                group.addTask {
                    let result=try tokenizer.encode(text)
                    return result.inputIDs==gold.inputIDs && result.wordsMask==gold.wordsMask && result.attentionMask==gold.attentionMask && result.words==gold.words
                }
            }
            for try await result in group {XCTAssertTrue(result)}
        }
    }
}
