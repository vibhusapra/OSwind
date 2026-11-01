import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct WorkflowFrameChoice:Codable,Equatable,Sendable {
    public let ordinal:Int
    public let time:Double?
}
public struct WorkflowFramePreview:Sendable {
    public let source:WorkflowSourceBinding
    public let title:String
    public let app:String
    public let timestamp:Date
    public let png:Data
    public let frames:[WorkflowFrameChoice]
}

public enum NarratedWorkflow {
    /// Explicit retained-source preview only. No live screen acquisition,
    /// narration, export or history write is triggered by loading a frame.
    public static func preview(store:MemoryStore,memoryID:String,frameOrdinal:Int=0) async throws -> WorkflowFramePreview {
        let activity=try store.mediaWriteLease();defer {activity.release()}
        let settings=try LibrarySettingsSnapshot.capture(root:store.root);defer {settings.release()}
        let body:@Sendable (PIIImportScanner?) async throws ->WorkflowFramePreview = {scanner in
            let source=try await WorkflowFrameReservation.make(store:store,memoryID:memoryID,frameOrdinal:frameOrdinal,settings:settings,scanner:scanner)
            defer {source.release()}
            return source.preview
        }
        if settings.settings.piiImports.enabled {return try await settings.settings.piiImports.withScanner {try await body($0)}}
        return try await body(nil)
    }
}

/// Private to one preview/export worker. Its lease survives actual decode and
/// inspection work. Export retains these objects until encoding/publication
/// finishes; cancellation must join the worker before releasing them.
final class WorkflowFrameReservation:@unchecked Sendable {
    let preview:WorkflowFramePreview
    let snapshot:any VisualMediaSnapshot
    private init(preview:WorkflowFramePreview,snapshot:any VisualMediaSnapshot) {self.preview=preview;self.snapshot=snapshot}
    static func make(store:MemoryStore,memoryID:String,frameOrdinal:Int,settings:LibrarySettingsSnapshot,scanner:PIIImportScanner?,ocr:@Sendable (CGImage)throws->[TextRegion]=VisualOCR.regions) async throws ->WorkflowFrameReservation {
        let pii=settings.settings.piiImports
        guard pii.enabled == (scanner != nil),scanner.map({$0.compute==pii.compute && $0.threshold==pii.threshold}) ?? true else {throw OSwindError.invalid("Use the selected local privacy scanner for workflow frames")}
        guard (0..<240).contains(frameOrdinal),let memory=try store.get(memoryID),let plan=try VisualSourcePlan.make(memory),let point=plan.points.first(where:{$0.ordinal==frameOrdinal}) else {throw OSwindError.invalid("Choose an available retained screen frame")}
        try allowed(memory,policy:settings.settings.privacy)
        let snapshot:any VisualMediaSnapshot
        let image:CGImage
        if plan.kind == .image {
            guard let value=try VisualImageSnapshot.make(store:store,id:memoryID) else {throw OSwindError.unavailable("Retained screen image is unavailable")}
            snapshot=value
            do {image=try decode(value.data)}catch {value.release();throw error}
        } else {
            guard let value=try VisualVideoSnapshot.make(store:store,id:memoryID) else {throw OSwindError.unavailable("Retained replay is unavailable")}
            snapshot=value
            do {
                let decoder=try await VisualReplayDecoder.open(value.url);defer {decoder.close()}
                guard let time=point.time else {throw OSwindError.invalid("Replay frame time is missing")}
                let frame=try await decoder.image(at:time)
                guard abs(frame.time-time)<=1.0/600 else {throw OSwindError.unavailable("The exact retained replay frame is unavailable")}
                image=frame.image
            }catch {value.release();throw error}
        }
        var retained=false;defer {if !retained {snapshot.release()}}
        // make() above may have observed a newer source. Never combine the
        // earlier frame coordinate with that different retained recording.
        guard snapshot.plan.revision==plan.revision,snapshot.plan.points.contains(point) else {throw OSwindError.unavailable("The selected screen source changed")}
        try Task.checkCancellation()
        let recognized=try ocr(image).map(\.text).joined(separator:"\n")
        guard recognized.utf8.count<=128*1024 else {throw OSwindError.invalid("Selected frame text exceeds the privacy inspection budget")}
        try safeText(recognized,policy:settings.settings.privacy)
        if let scanner {
            let original=try await scanner.sanitize(memory,policy:settings.settings.privacy)
            guard !original.redacted else {throw OSwindError.unavailable("Local privacy inspection found sensitive content in this screen source")}
            // The inspector deliberately refuses an empty document. There is
            // no recognized text to inspect here; the original typed source
            // is still scanned, and this is not an image-PII absence claim.
            if !recognized.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                let pixels=try await scanner.sanitize(Memory(kind:.note,text:recognized),policy:settings.settings.privacy)
                guard !pixels.redacted else {throw OSwindError.unavailable("Local privacy inspection found sensitive content in this screen source")}
            }
        }
        try Task.checkCancellation()
        let binding=WorkflowSourceBinding(library:WorkflowSourceBinding.libraryKey(store),memoryID:memoryID,revision:plan.revision,mediaSHA256:snapshot.sha256,kind:plan.kind == .image ? .image:.video,frameOrdinal:point.ordinal,frameTime:point.time)
        try binding.validate()
        let preview=WorkflowFramePreview(source:binding,title:memory.title,app:memory.app,timestamp:memory.timestamp,png:try encode(image),frames:plan.points.map {WorkflowFrameChoice(ordinal:$0.ordinal,time:$0.time)})
        let result=WorkflowFrameReservation(preview:preview,snapshot:snapshot)
        try result.withCurrent(store:store,settings:settings) {_ in ()}
        retained=true;return result
    }
    func withCurrent<T>(store:MemoryStore,settings:LibrarySettingsSnapshot,_ body:(Memory)throws->T)throws->T {
        try snapshot.withAdmission(for:store) {memory in
            try store.withRoutineDatabase {_ in
                try settings.withCurrent(root:store.root,policy:settings.settings.privacy) {
                    guard preview.source.library==WorkflowSourceBinding.libraryKey(store),snapshot.plan.revision==preview.source.revision,snapshot.sha256==preview.source.mediaSHA256,
                          let current=try store.get(memory.id),try VisualSourcePlan.make(current)?.revision==preview.source.revision else {throw OSwindError.unavailable("The workflow frame binding changed")}
                    try Self.allowed(current,policy:settings.settings.privacy)
                    return try body(current)
                }
            }
        }
    }
    func release() {snapshot.release()}
    deinit {release()}
    static func allowed(_ memory:Memory,policy:PrivacyPolicy)throws {
        guard policy.retainImages,VisualRetrievalEngine.allowed(memory,policy:policy) else {throw OSwindError.unavailable("Current privacy settings exclude this screen source")}
        for text in [memory.id,memory.app,memory.bundleID,memory.title,memory.url ?? "",memory.text] {try safeText(text,policy:policy)}
    }
    static func safeText(_ text:String,policy:PrivacyPolicy)throws {
        guard !text.contains("[REDACTED"),!policy.sanitize(text).redacted else {throw OSwindError.unavailable("Sensitive or previously redacted screen content cannot enter a workflow export")}
    }
    private static func decode(_ data:Data)throws->CGImage {
        guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width),(1...4096).contains(height),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096] as CFDictionary) else {throw OSwindError.invalid("The retained image is invalid, animated or larger than 4096 pixels")}
        return image
    }
    private static func encode(_ image:CGImage)throws->Data {
        let scale=min(1,1920/Double(max(image.width,image.height))),width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
        guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue),let _=context.data else {throw OSwindError.unavailable("Cannot prepare a bounded workflow preview")}
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height));context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let data=NSMutableData()
        guard let resized=context.makeImage(),let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {throw OSwindError.unavailable("Cannot encode workflow frame")}
        CGImageDestinationAddImage(destination,resized,nil)
        guard CGImageDestinationFinalize(destination),data.length<=16*1024*1024 else {throw OSwindError.invalid("Workflow preview exceeds 16 MiB")}
        return data as Data
    }
}
