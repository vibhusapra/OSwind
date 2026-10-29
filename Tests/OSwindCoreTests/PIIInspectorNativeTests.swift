import XCTest
import CPIIRuntime
@testable import OSwindCore

final class PIIInspectorNativeTests:XCTestCase {
    struct Reference:Decodable {let rows:[Row]}
    struct Row:Decodable {let id:String,kind:String,text:String,sourceSHA256:String,expectations:[Expected]}
    struct Expected:Decodable {
        struct Span:Decodable {let labelIndex:Int,confidence:Float,range:RangeValue}
        let threshold:Double,spans:[Span],redactionRanges:[RangeValue],redactedText:String
    }
    struct RangeValue:Decodable {let location:Int,length:Int}
    func testCABIInvalidArgumentsNeverTouchCallerOutput() {
        var output:Float=123,error=Array(repeating:CChar(0),count:256)
        XCTAssertNotEqual(OSWPiiRun(nil,nil,nil,nil,0,0,&output,1,&error,error.count),0)
        XCTAssertEqual(output,123)
        var session:OpaquePointer?
        XCTAssertNotEqual(OSWPiiCreate(nil,nil,0,0,&session,&error,error.count),0)
        XCTAssertNil(session);OSWPiiDestroy(nil)
    }
    func testMissingAssetsFailWithoutCreatingDirectoriesOrOpeningHistory() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-pii-missing-\(UUID().uuidString)")
        let inspector=PIIInspector(modelDirectory:root,runtimeLibrary:root.appendingPathComponent("missing.dylib"),compute:.cpu)
        do {_ = try await inspector.inspect("owned synthetic text",threshold:0.5);XCTFail("Missing assets accepted")} catch {}
        await inspector.shutdown();XCTAssertFalse(FileManager.default.fileExists(atPath:root.path))
    }
    func testActualCPUCohortMatchesPinnedIndependentReference() async throws {try await cohort(.cpu)}
    func testActualCoreMLCohortMatchesPinnedIndependentReference() async throws {try await cohort(.coreML)}
    func testActualCPULongDocumentKeepsCompleteOriginalCoordinates() async throws {try await longDocument(.cpu)}
    func testActualCoreMLLongDocumentKeepsCompleteOriginalCoordinates() async throws {try await longDocument(.coreML)}
    func testActualBackendsPreserveCoordinatesAcrossLongWhitespaceGap() async throws {
        let env=ProcessInfo.processInfo.environment
        guard let directory=env["OSWIND_TEST_PII_MODEL_DIR"],let library=env["OSWIND_TEST_PII_RUNTIME_LIBRARY"] else {throw XCTSkip("Explicit pinned local PII model/runtime opt-in absent")}
        let prefix="safe"+String(repeating:" ",count:12000),text=prefix+"password=ownedSecretAfterGap"
        for compute:PIIComputePolicy in [.cpu,.coreML] {
            let inspector=PIIInspector(modelDirectory:URL(fileURLWithPath:directory),runtimeLibrary:URL(fileURLWithPath:library),compute:compute)
            do {
                let result=try await inspector.inspect(text,threshold:0.5)
                XCTAssertEqual(result.windowCount,1);XCTAssertTrue(result.patternRedacted)
                XCTAssertTrue(result.masks.contains {$0.startUTF16==(prefix as NSString).length})
                XCTAssertFalse(result.text.contains("ownedSecretAfterGap"))
                XCTAssertEqual(result.sourceSHA256,PIIDocument.digest(text));await inspector.shutdown()
            } catch {await inspector.shutdown();throw error}
        }
    }
    private func longDocument(_ compute:PIIComputePolicy) async throws {
        let env=ProcessInfo.processInfo.environment
        guard let directory=env["OSWIND_TEST_PII_MODEL_DIR"],let library=env["OSWIND_TEST_PII_RUNTIME_LIBRARY"] else {throw XCTSkip("Explicit pinned local PII model/runtime opt-in absent")}
        let sample="Owned support note: my private phone number is +1 (202) 555-0100. Keep this private.",filler=Array(repeating:"Routine work continues.",count:100).joined(separator:" ")
        let text=sample+" "+filler+" "+sample+" "+filler+" "+sample,source=try PIIDocument(text)
        XCTAssertGreaterThan(text.unicodeScalars.count,4096)
        let inspector=PIIInspector(modelDirectory:URL(fileURLWithPath:directory),runtimeLibrary:URL(fileURLWithPath:library),compute:compute)
        do {
            let result=try await inspector.inspect(text,threshold:0.5)
            XCTAssertEqual(result.sourceSHA256,source.sha256);XCTAssertGreaterThan(result.windowCount,1)
            XCTAssertGreaterThan(result.framedTokens,0);XCTAssertLessThanOrEqual(result.framedTokens,PIIDocument.maximumFramedTokens)
            for span in result.spans {
                XCTAssertGreaterThanOrEqual(span.startUTF16,0);XCTAssertGreaterThan(span.lengthUTF16,0)
                XCTAssertLessThanOrEqual(span.startUTF16+span.lengthUTF16,(text as NSString).length)
            }
            let ranges=(try NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:"+1 (202) 555-0100"))).matches(in:text,range:NSRange(location:0,length:(text as NSString).length)).map(\.range)
            XCTAssertEqual(ranges.count,3)
            let covered=ranges.filter {range in result.modelMasks.contains {$0.startUTF16<=range.location && $0.startUTF16+$0.lengthUTF16>=NSMaxRange(range)}}.count
            print("PII document native metrics: compute=\(compute.rawValue) windows=\(result.windowCount) framedTokens=\(result.framedTokens) sourceWords=\(source.words.count) expectedValues=3 learnedFullValues=\(covered)")
            // Coverage here is an authored quality observation, not an accepted
            // threshold. Structural completeness/refusal is the tested contract.
            await inspector.shutdown()
        } catch {await inspector.shutdown();throw error}
    }
    private func cohort(_ compute:PIIComputePolicy) async throws {
        let env=ProcessInfo.processInfo.environment
        guard let directory=env["OSWIND_TEST_PII_MODEL_DIR"],let library=env["OSWIND_TEST_PII_RUNTIME_LIBRARY"] else {throw XCTSkip("Explicit pinned local PII model/runtime opt-in absent")}
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture=root.appendingPathComponent("benchmarks/prototypes/pii/\(compute == .cpu ? "native":"coreml")-decoder-reference-v1.json")
        let reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:fixture))
        let rows=reference.rows.filter {$0.kind=="model-validation"};XCTAssertEqual(rows.count,72)
        let inspector=PIIInspector(modelDirectory:URL(fileURLWithPath:directory),runtimeLibrary:URL(fileURLWithPath:library),compute:compute)
        await inspector.setRetention(.untilQuit)
        var comparisons=0,maximumConfidenceDifference:Float=0
        do {
            for row in rows {
                for expected in row.expectations {
                    let result=try await inspector.inspect(row.text,threshold:expected.threshold)
                    XCTAssertEqual(result.windowCount,1,row.id)
                    comparisons+=1
                    XCTAssertEqual(result.sourceSHA256,row.sourceSHA256,row.id);XCTAssertEqual(result.spans.count,expected.spans.count,row.id)
                    for (actual,span) in zip(result.spans,expected.spans) {
                        XCTAssertEqual(actual.startUTF16,span.range.location,row.id);XCTAssertEqual(actual.lengthUTF16,span.range.length,row.id)
                        XCTAssertEqual(actual.label,PIITokenizer.labels[span.labelIndex],row.id)
                        XCTAssertEqual(actual.confidence,span.confidence,accuracy:compute == .cpu ? 1e-6:1e-3,row.id)
                        maximumConfidenceDifference=max(maximumConfidenceDifference,abs(actual.confidence-span.confidence))
                    }
                    XCTAssertEqual(result.modelMasks.map(\.startUTF16),expected.redactionRanges.map(\.location),row.id)
                    XCTAssertEqual(result.modelMasks.map(\.lengthUTF16),expected.redactionRanges.map(\.length),row.id)
                    let patternRanges=PrivacyPolicy().sensitiveRanges(in:row.text)
                    if patternRanges.isEmpty {XCTAssertEqual(result.text,expected.redactedText,row.id)}
                    for range in patternRanges {
                        XCTAssertTrue(result.masks.contains {$0.startUTF16<=range.location && $0.startUTF16+$0.lengthUTF16>=NSMaxRange(range)},row.id)
                    }
                    XCTAssertEqual(result.patternRedacted,!patternRanges.isEmpty,row.id)
                    XCTAssertEqual(result.suppressMedia,result.redacted,row.id)
                }
            }
            let resident=await inspector.modelResident;XCTAssertTrue(resident)
            if compute == .coreML {
                let long=try await inspector.inspect(Array(repeating:"word",count:128).joined(separator:" "),threshold:0.5)
                XCTAssertGreaterThan(long.windowCount,1)
            }
            await inspector.shutdown();let remaining=await inspector.modelResident;XCTAssertFalse(remaining)
            print("PII native session metrics: compute=\(compute.rawValue) sources=\(rows.count) comparisons=\(comparisons) maximumConfidenceDifference=\(maximumConfidenceDifference)")
        } catch {await inspector.shutdown();throw error}
    }
}
