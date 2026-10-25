import XCTest
import Hub
import CryptoKit
import OSwindTokenizers
@testable import OSwindCore

final class VisualTokenizerDataTests:XCTestCase {
    func payload(vocab:Any=["a":0,"b":1],merges:Any=[["a","b"]],extra:[String:Any]=[:])throws->Data {
        var root:[String:Any] = ["model":["type":"BPE","vocab":vocab,"merges":merges]]
        for (key,value) in extra {root[key]=value}
        return try JSONSerialization.data(withJSONObject:root)
    }
    func testCanonicallyEquivalentVocabularyKeysRemainByteDistinct()throws {
        let input=Data(#"{"model":{"type":"BPE","vocab":{"é":0,"e\u0301":1},"merges":[["e","\u0301"]]}}"#.utf8)
        let decoded=try VisualTokenizerData.decode(input),vocab=try XCTUnwrap(decoded.model.vocab.dictionary())
        XCTAssertEqual(vocab.count,2)
        XCTAssertEqual(vocab[BinaryDistinctString("é")]?.integer(),0)
        XCTAssertEqual(vocab[BinaryDistinctString("e\u{301}" )]?.integer(),1)
    }
    func testLeadingBOMAndEscapedQuotesRemainExact()throws {
        let input=try payload(vocab:["\u{feff}#":0,"#":1,"@quoted\"\\":2,"\u{301}":3],merges:[["\u{feff}","#"],["@quoted\"","\\"],["\u{301}","a"]])
        let decoded=try VisualTokenizerData.decode(input),vocab=try XCTUnwrap(decoded.model.vocab.dictionary()),merges=try XCTUnwrap(decoded.model.merges.array())
        XCTAssertEqual(vocab.count,4);XCTAssertEqual(vocab[BinaryDistinctString("\u{feff}#")]?.integer(),0)
        XCTAssertEqual(vocab[BinaryDistinctString("#")]?.integer(),1)
        XCTAssertEqual(vocab[BinaryDistinctString("@quoted\"\\")]?.integer(),2)
        XCTAssertEqual(merges[0][0].string(),"\u{feff}")
        XCTAssertEqual(merges[1][0].string(),"@quoted\"");XCTAssertEqual(merges[1][1].string(),"\\")
        XCTAssertEqual(vocab[BinaryDistinctString("\u{301}")]?.integer(),3)
        XCTAssertEqual(merges[2][0].string(),"\u{301}")
    }
    func testSmallMetadataMatchesExistingConfigTypesAndTokenTuples()throws {
        let data=try payload(extra:["version":"1.0","normalizer":["type":"Replace","pattern":["String":"a"],"content":"b"],"metadata":["boolean":true,"null":NSNull(),"integer":7,"float":0.25,"tuple":[7,"token"],"array":["a","b"]]])
        let old=try JSONDecoder().decode(Config.self,from:data),new=try VisualTokenizerData.decode(data)
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(old),try encoder.encode(new))
        let metadata=new["metadata"]
        XCTAssertEqual(metadata["boolean"].boolean(),true);XCTAssertTrue(metadata["null"].isNull())
    }
    func testUnsupportedShapesAndModelTypesRefuse()throws {
        for text in ["[]","null","{}",#"{"model":{}}"#,#"{"model":{"type":"Unigram","vocab":{"a":0},"merges":[]}}"#,#"{"model":{"type":"BPE","vocab":[],"merges":[]}}"#,#"{"model":{"type":"BPE","vocab":{},"merges":[]}}"#] {
            XCTAssertThrowsError(try VisualTokenizerData.decode(Data(text.utf8)))
        }
    }
    func testInvalidVocabularyIdentifiersRefuseWithoutBooleanCoercion()throws {
        for value:Any in [true,"1",0.5,-1,256000] {
            XCTAssertThrowsError(try VisualTokenizerData.decode(payload(vocab:["a":value])))
        }
    }
    func testMalformedMergePairsRefuse()throws {
        for merges:Any in ["unsupported",[["a"]],[["a","b","c"]],[[true,"b"]],[1]] {
            XCTAssertThrowsError(try VisualTokenizerData.decode(payload(merges:merges)))
        }
    }
    func testByteMetadataAndContainerBoundsRefuse()throws {
        XCTAssertThrowsError(try VisualTokenizerData.decode(Data(repeating:32,count:VisualTokenizerData.maximumBytes+1)))
        XCTAssertThrowsError(try VisualTokenizerData.decode(payload(extra:["large":String(repeating:"x",count:256*1024)])))
        XCTAssertThrowsError(try VisualTokenizerData.decode(payload(extra:Dictionary(uniqueKeysWithValues:(0..<33).map {("extra-\($0)",true)}))))
        XCTAssertThrowsError(try VisualTokenizerData.decode(payload(vocab:[String(repeating:"x",count:32769):0])))
    }
    func testAlreadyCancelledDecodeRefusesBeforeParsingMalformedInput()async throws {
        let task=Task.detached {withUnsafeCurrentTask {$0?.cancel()};return try VisualTokenizerData.decode(Data("malformed".utf8))}
        do {_=try await task.value;XCTFail("Cancelled parser ran")}catch is CancellationError {} catch {XCTFail("Unexpected error: \(error)")}
    }
    func testBPEMergesUseExactUnicodeBytesWithoutInventingACanonicalMerge()throws {
        let input=Data(##"{"model":{"type":"BPE","vocab":{"<unk>":0,"▁":1,"Å":2,"Å":3,"▁Å":4},"merges":[["▁","Å"]]}}"##.utf8)
        let config=Config(["tokenizer_class":"GemmaTokenizer","unk_token":"<unk>"])
        let tokenizer=try PreTrainedTokenizer(tokenizerConfig:config,tokenizerData:VisualTokenizerData.decode(input),strict:true)
        XCTAssertEqual(tokenizer.encode(text:"▁Å",addSpecialTokens:false),[4])
        XCTAssertEqual(tokenizer.encode(text:"▁Å",addSpecialTokens:false),[1,3])
    }
    func testLiteralSpaceNormalizationReplacesBeforeACombiningMark()throws {
        let input=Data(##"{"normalizer":{"type":"Replace","pattern":{"String":" "},"content":"▁"},"model":{"type":"BPE","vocab":{"<unk>":0,"▁":1,"\u0301":2},"merges":[]}}"##.utf8)
        let config=Config(["tokenizer_class":"GemmaTokenizer","unk_token":"<unk>"])
        let tokenizer=try PreTrainedTokenizer(tokenizerConfig:config,tokenizerData:VisualTokenizerData.decode(input),strict:true)
        XCTAssertEqual(tokenizer.encode(text:" \u{301} ",addSpecialTokens:false),[1,2,1])
    }
    func testPinnedCompleteVocabularyMergesAndIndependentTokenReferences()async throws {
        let env=ProcessInfo.processInfo.environment
        guard let model=env["OSWIND_VISUAL_MODEL_DIR"],let reference=env["OSWIND_TEST_VISUAL_TOKENIZER_REFERENCE"] else {throw XCTSkip("Opt-in exact local visual bundle and independently prepared tokenizer references; never downloads")}
        func sha(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
        let referenceData=try Data(contentsOf:URL(fileURLWithPath:reference))
        XCTAssertEqual(sha(referenceData),"bfe39a039eb3b372433f8db1218d2bbf25d20db21659e70c644291e10e86e964")
        struct Query:Decodable {let text:String,ids:[Int],truncated:Bool}
        struct Reference:Decodable {let vocabularyCount:Int,mergeCount:Int,vocabularySHA256:String,orderedMergesSHA256:String,queries:[Query]}
        let gold=try JSONDecoder().decode(Reference.self,from:referenceData)
        let directory=URL(fileURLWithPath:model),data=try Data(contentsOf:directory.appendingPathComponent("tokenizer.json"))
        XCTAssertEqual(sha(data),VisualModelBundle.tokenizerSHA256)
        let config=try VisualTokenizerData.decode(data),vocab=try XCTUnwrap(config.model.vocab.dictionary()),merges=try XCTUnwrap(config.model.merges.array())
        XCTAssertEqual(vocab.count,gold.vocabularyCount);XCTAssertEqual(merges.count,gold.mergeCount)
        var vocabularyDigest=SHA256(),mergeDigest=SHA256()
        func frame(_ bytes:[UInt8],_ digest:inout SHA256) {
            var length=UInt32(bytes.count).bigEndian
            withUnsafeBytes(of:&length) {digest.update(data:Data($0))};digest.update(data:Data(bytes))
        }
        let entries=try vocab.map {key,value in (Array(key.string.utf8),try XCTUnwrap(value.integer()))}.sorted {$0.0.lexicographicallyPrecedes($1.0)}
        for (bytes,identifier) in entries {
            frame(bytes,&vocabularyDigest);var id=UInt64(identifier).bigEndian
            withUnsafeBytes(of:&id) {vocabularyDigest.update(data:Data($0))}
        }
        for merge in merges {
            let pair=try XCTUnwrap(merge.array());XCTAssertEqual(pair.count,2)
            for part in pair {frame(Array(try XCTUnwrap(part.string()).utf8),&mergeDigest)}
        }
        XCTAssertEqual(vocabularyDigest.finalize().map {String(format:"%02x",$0)}.joined(),gold.vocabularySHA256)
        XCTAssertEqual(mergeDigest.finalize().map {String(format:"%02x",$0)}.joined(),gold.orderedMergesSHA256)
        let tokenizer=try await VisualTokenizer(directory:directory)
        for (index,query) in gold.queries.enumerated() {
            let tokens=try tokenizer.encode(query.text)
            XCTAssertEqual(tokens.ids,query.ids,"Independent tokenizer query \(index)")
            XCTAssertEqual(tokens.truncated,query.truncated,"Independent tokenizer truncation \(index)")
        }
        XCTAssertEqual(gold.queries.count,439)
    }
}
