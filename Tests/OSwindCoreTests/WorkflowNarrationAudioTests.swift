import XCTest
@testable import OSwindCore

final class WorkflowNarrationAudioTests:XCTestCase {
    let script="This is the authored narration."
    func fixture(silent:Bool=false,rate:Int=24000,change:((inout [String:Any])->Void)?=nil)throws->URL {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-workflow-audio-"+UUID().uuidString);try Paths.ensure(root)
        try Data(script.utf8).write(to:root.appendingPathComponent("narration.txt"))
        let count=4800;var wav=Data()
        func text(_ s:String) {wav.append(contentsOf:s.utf8)}
        func u32(_ v:UInt32) {var n=v.littleEndian;withUnsafeBytes(of:&n){wav.append(contentsOf:$0)}}
        func u16(_ v:UInt16) {var n=v.littleEndian;withUnsafeBytes(of:&n){wav.append(contentsOf:$0)}}
        text("RIFF");u32(UInt32(36+count*2));text("WAVEfmt ");u32(16);u16(1);u16(1);u32(UInt32(rate));u32(UInt32(rate*2));u16(2);u16(16);text("data");u32(UInt32(count*2))
        for i in 0..<count {let sample:Int16=silent ? 0:Int16(sin(Double(i)*2*Double.pi*440/Double(rate))*4000);u16(UInt16(bitPattern:sample))}
        try wav.write(to:root.appendingPathComponent("narration.wav"))
        try wav.write(to:root.appendingPathComponent("foreign.wav"))
        let duration=Double(count)/Double(rate)
        var receipt:[String:Any] = ["model":"mlx-community/Kokoro-82M-bf16","voice":"af_heart","speed":1.0,"audio":root.appendingPathComponent("narration.wav").path,"audio_seconds":duration,"chunks":[["start_seconds":0.0,"end_seconds":duration]]]
        change?(&receipt)
        try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys).write(to:root.appendingPathComponent("narration.timing.json"))
        return root
    }
    func inspect(_ root:URL)throws->WorkflowNarrationReceipt {try WorkflowNarrationAudio.inspect(tree:BackupFileTree(root:root),stem:"narration",script:script)}
    func testMeasuredPCMAndChunksBindExactScriptAndFiles()throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        let result=try inspect(root)
        XCTAssertEqual(result.frames,4800);XCTAssertEqual(result.sampleRate,24000);XCTAssertEqual(result.audioSeconds,0.2,accuracy:0.000001)
        XCTAssertGreaterThan(result.rms,0.01);XCTAssertGreaterThan(result.peak,0.1);XCTAssertEqual(result.chunks.count,1)
        XCTAssertEqual(result.scriptSHA256,WorkflowDraft.digest(Data(script.utf8)));XCTAssertEqual(result.wavSHA256,WorkflowDraft.digest(try Data(contentsOf:root.appendingPathComponent("narration.wav"))))
    }
    func testSilentAndWrongRateAudioRefuse()throws {
        for (silent,rate) in [(true,24000),(false,16000)] {
            let root=try fixture(silent:silent,rate:rate);defer {try? FileManager.default.removeItem(at:root)}
            XCTAssertThrowsError(try inspect(root))
        }
    }
    func testWrongVoiceSpeedModelOrDurationCannotReuseReceipt()throws {
        for change:(inout [String:Any])->Void in [{ $0["voice"]="other" },{ $0["speed"]=1.1 },{ $0["model"]="other" },{ $0["audio_seconds"]=0.19 }] {
            let root=try fixture(change:change);defer {try? FileManager.default.removeItem(at:root)}
            XCTAssertThrowsError(try inspect(root))
        }
    }
    func testGapsOverlapsAndTruncatedChunkCoverageRefuse()throws {
        for chunks in [[],[["start_seconds":0.01,"end_seconds":0.2]],[["start_seconds":0.0,"end_seconds":0.19]],[["start_seconds":0.0,"end_seconds":0.15],["start_seconds":0.1,"end_seconds":0.2]]] as [[[String:Double]]] {
            let root=try fixture(change:{$0["chunks"]=chunks});defer {try? FileManager.default.removeItem(at:root)}
            XCTAssertThrowsError(try inspect(root))
        }
    }
    func testChangedScriptForeignOutputAndTruncatedWAVRefuse()throws {
        let root=try fixture();defer {try? FileManager.default.removeItem(at:root)}
        XCTAssertThrowsError(try WorkflowNarrationAudio.inspect(tree:BackupFileTree(root:root),stem:"narration",script:"Changed reviewed script"))
        let foreign=try fixture(change:{let path=($0["audio"] as! String);$0["audio"] = URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("foreign.wav").path});defer {try? FileManager.default.removeItem(at:foreign)}
        XCTAssertThrowsError(try inspect(foreign))
        try Data("RIFFtruncated".utf8).write(to:root.appendingPathComponent("narration.wav"))
        XCTAssertThrowsError(try inspect(root))
    }
    func testActualOwnedStockKokoroOutputPassesMeasuredAudioAdmission()throws {
        guard let path=ProcessInfo.processInfo.environment["OSWIND_TEST_WORKFLOW_KOKORO_DIRECTORY"] else {throw XCTSkip("Explicit authored local Kokoro output fixture")}
        let root=URL(fileURLWithPath:path,isDirectory:true),script=try String(contentsOf:root.appendingPathComponent("narration.txt"),encoding:.utf8)
        let receipt=try WorkflowNarrationAudio.inspect(tree:BackupFileTree(root:root),stem:"narration",script:script)
        XCTAssertEqual(receipt.voice,"af_heart");XCTAssertEqual(receipt.speed,1);XCTAssertGreaterThan(receipt.audioSeconds,1);XCTAssertGreaterThan(receipt.rms,0.00001)
    }
}
