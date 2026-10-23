import XCTest
import Vision
import CoreGraphics
import CoreText
@testable import OSwindCore

final class VisionFixtureTests: XCTestCase {
    func image(_ lines: [String]) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:6400,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:1,alpha:1)); context.fill(CGRect(x:0,y:0,width:1600,height:900))
        let font = CTFontCreateWithName("Helvetica" as CFString,36,nil)
        for (i,text) in lines.enumerated() {
            let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)]
            context.textPosition = CGPoint(x:70,y:780-i*80); CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:attributes)),context)
        }
        return try XCTUnwrap(context.makeImage())
    }
    func testActualVisionOCRAndSecretBoundary() throws {
        let bitmap = try image(["OSwind remembers the Friday release.","Maya owns the checklist.","password=local-test-secret"])
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        let begin = Date(); try VNImageRequestHandler(cgImage:bitmap).perform([request]); let duration = Date().timeIntervalSince(begin)
        let text = request.results!.compactMap {$0.topCandidates(1).first?.string}.joined(separator:"\n")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("Friday release")); XCTAssertTrue(text.contains("Maya owns")); XCTAssertTrue(PrivacyPolicy().sanitize(text).redacted)
        print("Vision synthetic 1600x900 OCR: \(Int(duration*1000)) ms")
    }
    func testFingerprintChangesWithContent() throws {
        let a = try image(["A screen of one sentence."]), b = try image(["A completely different line of content.","Second line of text.","Third line."])
        XCTAssertEqual(CaptureController.difference(CaptureController.fingerprint(a),CaptureController.fingerprint(a)),0)
        XCTAssertGreaterThan(CaptureController.difference(CaptureController.fingerprint(a),CaptureController.fingerprint(b)),0)
    }
    func testReasoningIsNeverDisplayed() {
        XCTAssertEqual(AnswerEngine.visibleAnswer("<think>private reasoning</think>\nMaya [1]."),"Maya [1].")
        XCTAssertEqual(AnswerEngine.visibleAnswer("reasoning without opening tag</think>Final [1]"),"Final [1]")
        XCTAssertEqual(AnswerEngine.visibleAnswer("<think>unfinished"),"")
    }
    func testSummarySamplesWholeRange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:root) }; let store = try MemoryStore(root:root)
        for i in 0..<1000 { try store.insert(Memory(id:"\(i)",timestamp:Date(timeIntervalSince1970:Double(i)),text:"Moment \(i)")) }
        let samples = try store.timelineSample(SearchFilter(),limit:12)
        XCTAssertEqual(samples.count,12); XCTAssertEqual(samples.first?.id,"0"); XCTAssertEqual(samples.last?.id,"999")
        let scoped = try store.timelineSample(SearchFilter(start:Date(timeIntervalSince1970:500)),limit:12); XCTAssertEqual(scoped.first?.id,"500"); XCTAssertEqual(scoped.last?.id,"999")
    }
}
