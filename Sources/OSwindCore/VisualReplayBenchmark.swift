import Foundation
import CoreText
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

/// Explicit, synthetic-only probe. Never reads screen pixels or the normal
/// library. Fresh output directory is required, and partial failures are kept.
public enum VisualReplayBenchmark {
    public static func run(directory:URL,frames:Int=12,hardwareRequired:Bool=true) async throws -> [String:Any] {
        guard (2...120).contains(frames),!FileManager.default.fileExists(atPath:directory.path) else {throw OSwindError.invalid("Replay probe requires a fresh output directory and 2–120 frames")}
        try Paths.ensure(directory)
        let store=try MemoryStore(root:directory.appendingPathComponent("library"))
        let recorder=VisualChunkRecorder(store:store,codec:hardwareRequired ? "hevc":"h264",hardwareRequired:hardwareRequired)
        let jpeg=directory.appendingPathComponent("jpeg-reference");try Paths.ensure(jpeg)
        let width=1280,height=720,start=Date(),first=Date().addingTimeInterval(-Double(frames))
        let context=CIContext(options:[.cacheIntermediates:false])
        var ocrMS=[Double](),appendMS=[Double](),ocrChecks=0,sourceIdentity=0
        do {
            for index in 0..<frames {
                try Task.checkCancellation()
                let buffer=try fixtureFrame(index:index,width:width,height:height)
                let ocrStart=Date(),regions=try VisualOCR.regions(buffer),text=regions.map(\.text).joined(separator:"\n")
                ocrMS.append(Date().timeIntervalSince(ocrStart)*1000)
                if text.localizedCaseInsensitiveContains("Frame token: visual-"+String(format:"%03d",index)) {sourceIdentity+=1}
                if text.localizedCaseInsensitiveContains("Maya owns capture") && text.localizedCaseInsensitiveContains("Theo owns archive") {ocrChecks+=1}
                let frame=ReplayFrameInput(buffer:buffer,time:Double(index),capturedAt:first.addingTimeInterval(Double(index)),app:"OSwind synthetic replay",bundle:"org.oswind.synthetic-replay",title:"Synthetic replay benchmark",url:nil,display:"synthetic-window",text:text,regions:regions)
                let appendStart=Date();try await recorder.append(frame,privacy:PrivacyPolicy(),interval:1);appendMS.append(Date().timeIntervalSince(appendStart)*1000)
                let ci=CIImage(cvPixelBuffer:buffer)
                guard let image=context.createCGImage(ci,from:ci.extent),let output=CGImageDestinationCreateWithURL(jpeg.appendingPathComponent("frame-\(index).jpg") as CFURL,UTType.jpeg.identifier as CFString,1,nil) else {throw OSwindError.unavailable("Cannot create JPEG reference")}
                CGImageDestinationAddImage(output,image,[kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
                guard CGImageDestinationFinalize(output) else {throw OSwindError.unavailable("Cannot encode JPEG reference")}
            }
            try await recorder.close()
            let memories=try store.search(SearchFilter(limit:100),mode:.keyword).map(\.memory)
            let frameCount=memories.reduce(0,{$0+($1.visualRecording?.frames.count ?? 0)})
            guard frameCount==frames,ocrChecks==frames,sourceIdentity==frames else {throw OSwindError.unavailable("Synthetic replay lost frames or expected OCR text")}
            var videoBytes:Int64=0,thumbnailBytes:Int64=0,decoded=0,decodedOCR=0,decodedIdentity=0
            var decodedDiagnostics=[[String:Any]]()
            for memory in memories {
                guard let source=memory.visualRecording,let url=memory.videoPath.flatMap({store.assetURL($0)}) else {throw OSwindError.invalid("Replay source is incomplete")}
                videoBytes+=try bytes(url)
                if let thumbnail=memory.imagePath.flatMap({store.assetURL($0)}) {thumbnailBytes+=try bytes(thumbnail)}
                let generator=AVAssetImageGenerator(asset:AVURLAsset(url:url));generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
                for frame in source.frames {
                    let image=try generator.copyCGImage(at:CMTime(seconds:frame.time,preferredTimescale:600),actualTime:nil)
                    guard image.width==width,image.height==height else {throw OSwindError.invalid("Decoded replay dimensions changed")};decoded+=1
                    let recognized=try VisualOCR.regions(image).map(\.text).joined(separator:"\n")
                    if recognized.localizedCaseInsensitiveContains("Maya owns capture") && recognized.localizedCaseInsensitiveContains("Theo owns archive") {decodedOCR+=1}
                    let globalIndex=Int(round(memory.timestamp.timeIntervalSince(first)+frame.time))
                    let expectedToken="Frame token: visual-"+String(format:"%03d",globalIndex)
                    let identity=(0..<frames).contains(globalIndex) && recognized.localizedCaseInsensitiveContains(expectedToken)
                    if identity {decodedIdentity+=1}
                    decodedDiagnostics.append(["source":frame.text,"decoded":recognized,"identity_passed":identity,"expected_token":expectedToken])
                }
            }
            try JSONSerialization.data(withJSONObject:decodedDiagnostics,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("decoded-fidelity.json"),options:.atomic)
            guard decodedOCR==frames,decodedIdentity==frames else {throw OSwindError.unavailable("Compressed replay OCR: ownership \(decodedOCR)/\(frames), frame identity \(decodedIdentity)/\(frames); see decoded-fidelity.json") }
            let jpegBytes=try FileManager.default.contentsOfDirectory(at:jpeg,includingPropertiesForKeys:nil).reduce(Int64(0)) {try $0+bytes($1)}
            let report:[String:Any]=["format":"OSwind synthetic visual replay probe v1","schema_version":MemoryStore.schemaVersion,"hardware_required":hardwareRequired,"codec":hardwareRequired ? "hevc":"h264","width":width,"height":height,"interval_seconds":1,"input_frames":frames,"stored_frames":frameCount,"decoded_frames":decoded,"decoded_ocr_checks_passed":decodedOCR,"decoded_frame_identity_checks_passed":decodedIdentity,"ocr_checks_passed":ocrChecks,"source_frame_identity_checks_passed":sourceIdentity,"clips":memories.count,"video_bytes":videoBytes,"thumbnail_bytes":thumbnailBytes,"jpeg_reference_bytes":jpegBytes,"video_plus_thumbnail_to_jpeg_ratio":Double(videoBytes+thumbnailBytes)/Double(max(1,jpegBytes)),"ocr_ms":ocrMS,"append_including_chunk_finalization_ms":appendMS,"wall_seconds":Date().timeIntervalSince(start),"scope":"Generated static desktop-like pixels with changing labels; actual Vision OCR, required-hardware HEVC (or explicit software H264), source storage, every-frame decode and decoded ownership/authored frame-token OCR checks. JPEG uses the same pixels at quality 0.75. Excludes desktop capture, natural workloads, power, database/metadata bytes and competitors."]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"),options:.atomic)
            return report
        } catch {try? await recorder.close(commit:false);throw error}
    }
    private static func bytes(_ url:URL) throws -> Int64 {(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.int64Value ?? 0}
    private static func fixtureFrame(index:Int,width:Int,height:Int) throws -> CVPixelBuffer {
        var result:CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&result)==kCVReturnSuccess,let buffer=result else {throw OSwindError.unavailable("Cannot allocate synthetic replay frame")}
        CVPixelBufferLockBaseAddress(buffer,[]);defer {CVPixelBufferUnlockBaseAddress(buffer,[])}
        guard let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue) else {throw OSwindError.unavailable("Cannot draw synthetic replay frame")}
        context.setFillColor(CGColor(gray:0.97,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        context.setFillColor(CGColor(red:0.35,green:0.23,blue:0.68,alpha:1));context.fill(CGRect(x:0,y:height-80,width:width,height:80))
        let font=CTFontCreateWithName("Helvetica" as CFString,32,nil)
        for (row,text) in ["OSwind synthetic replay frame \(index)","Maya owns capture. Theo owns archive.","The source stays local on this Mac.","Frame token: visual-\(String(format:"%03d",index))"].enumerated() {
            let string=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0.08,alpha:1)])
            context.textPosition=CGPoint(x:56,y:height-160-row*90);CTLineDraw(CTLineCreateWithAttributedString(string),context)
        }
        context.setFillColor(CGColor(red:0.2,green:Double(index%10)/10,blue:0.65,alpha:1));context.fill(CGRect(x:56+index*5,y:70,width:180,height:45))
        return buffer
    }
}
