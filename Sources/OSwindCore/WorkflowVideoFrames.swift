import Foundation
import CoreGraphics
import CoreVideo
import CoreText
import ImageIO

enum WorkflowVideoFrames {
    static let width=1280,height=720
    static func render(draft:WorkflowDraft,frames:[WorkflowFramePreview],timeline:WorkflowTimeline,workspace:BackupWorkspace,hardwareRequired:Bool=true) async throws->URL {
        try Task.checkCancellation()
        let draft=try draft.validated()
        guard timeline.draftRevision == (try draft.revision),timeline.sampleRate==24000,timeline.frames>0,timeline.frames<=2_880_000,
              timeline.steps.count==draft.steps.count,frames.count==draft.steps.count,timeline.narration.frames==timeline.frames else {throw OSwindError.invalid("Video inputs differ from the measured workflow")}
        var previous:Int64=0
        for (index,step) in timeline.steps.enumerated() {
            guard step.stepID==draft.steps[index].id,step.startFrame==previous,step.endFrame>step.startFrame,step.endFrame<=timeline.frames,step.endFrame-step.startFrame>=2400,
                  frames[index].source==draft.steps[index].source else {throw OSwindError.invalid("Workflow frame order or measured boundaries changed")}
            previous=step.endFrame
        }
        guard previous==timeline.frames else {throw OSwindError.invalid("Workflow timeline omits narration")}
        try workspace.tree.requireRootIdentity(at:workspace.url)
        let url=workspace.url.appendingPathComponent("workflow-video.mov"),writer=try ReplayVideoEncoder(url:url,width:width,height:height,frameInterval:1,codec:"h264",hardwareRequired:hardwareRequired,workspace:workspace)
        do {
            for (index,frame) in frames.enumerated() {
                try Task.checkCancellation()
                let buffer=try canvas(draft:draft,frame:frame,index:index)
                try await writer.append(buffer,time:timeline.steps[index].startSeconds)
            }
            // Keep the last image through the exact audio end. The final mux
            // trims this sub-frame ceiling to the narration's 24 kHz duration.
            let end=ceil(timeline.duration*600)/600
            let actual=try await writer.finish(duration:end)
            guard actual+1.0/600>=timeline.duration else {throw OSwindError.invalid("Video does not cover the complete narration")}
            try Task.checkCancellation();try workspace.tree.requireRootIdentity(at:workspace.url);return url
        }catch {
            let original=error;writer.cancel();await writer.waitForCancellation();throw original
        }
    }
    static func canvas(draft:WorkflowDraft,frame:WorkflowFramePreview,index:Int)throws->CVPixelBuffer {
        guard draft.steps.indices.contains(index),frame.png.count<=16*1024*1024,
              let source=CGImageSourceCreateWithData(frame.png as CFData,nil),CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let pixelWidth=properties[kCGImagePropertyPixelWidth] as? Int,let pixelHeight=properties[kCGImagePropertyPixelHeight] as? Int,
              (1...1920).contains(pixelWidth),(1...1920).contains(pixelHeight),
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary),image.width==pixelWidth,image.height==pixelHeight else {throw OSwindError.invalid("Invalid bounded workflow frame pixels")}
        var pixel:CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true] as CFDictionary,&pixel)==kCVReturnSuccess,let pixel else {throw OSwindError.unavailable("Cannot allocate workflow video frame")}
        CVPixelBufferLockBaseAddress(pixel,[]);defer {CVPixelBufferUnlockBaseAddress(pixel,[])}
        guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:CVPixelBufferGetBaseAddress(pixel),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(pixel),space:color,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else {throw OSwindError.unavailable("Cannot draw workflow video frame")}
        context.setFillColor(CGColor(red:0.035,green:0.055,blue:0.09,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
        text(draft.title,size:32,color:CGColor(gray:1,alpha:1),x:48,y:664,width:1184,context:context)
        text(draft.steps[index].title,size:23,color:CGColor(gray:0.84,alpha:1),x:48,y:625,width:1184,context:context)
        let plate=CGRect(x:48,y:120,width:1184,height:480)
        context.saveGState();context.addPath(CGPath(roundedRect:plate,cornerWidth:10,cornerHeight:10,transform:nil));context.clip()
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(plate)
        let scale=min(plate.width/CGFloat(image.width),plate.height/CGFloat(image.height)),size=CGSize(width:CGFloat(image.width)*scale,height:CGFloat(image.height)*scale)
        let target=CGRect(x:plate.midX-size.width/2,y:plate.midY-size.height/2,width:size.width,height:size.height)
        context.interpolationQuality = .high;context.draw(image,in:target);context.restoreGState()
        text(String(format:"STEP %02d / %02d",index+1,draft.steps.count),size:17,color:CGColor(red:0.35,green:0.84,blue:0.73,alpha:1),x:48,y:75,width:1184,context:context)
        text(frame.source.kind == .video ? "Retained replay frame":"Retained screen snapshot",size:16,color:CGColor(gray:0.65,alpha:1),x:48,y:45,width:1184,context:context)
        return pixel
    }
    private static func text(_ value:String,size:CGFloat,color:CGColor,x:CGFloat,y:CGFloat,width:Double,context:CGContext) {
        let font=CTFontCreateUIFontForLanguage(.system,size,nil) ?? CTFontCreateWithName("Helvetica" as CFString,size,nil)
        let attributes:[NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,NSAttributedString.Key(kCTForegroundColorAttributeName as String):color]
        let line=CTLineCreateWithAttributedString(NSAttributedString(string:value,attributes:attributes)),ellipsis=CTLineCreateWithAttributedString(NSAttributedString(string:"…",attributes:attributes))
        let fitted=CTLineCreateTruncatedLine(line,width,.end,ellipsis) ?? line
        context.saveGState();context.textMatrix = .identity;context.textPosition=CGPoint(x:x,y:y);CTLineDraw(fitted,context);context.restoreGState()
    }
}
