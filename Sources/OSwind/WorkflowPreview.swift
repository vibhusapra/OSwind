#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import OSwindCore

/// Authored sample pixels only. Offscreen rendering never inspects the desktop.
@MainActor enum WorkflowPreview {
    static func make(store:MemoryStore,empty:Bool=false)async throws->WorkflowModel {
        let hash=String(repeating:"a",count:64)
        let env=WorkflowEnvironment(preview:{id,_ in
            let color=CGColorSpaceCreateDeviceRGB()
            guard let context=CGContext(data:nil,width:640,height:360,bitsPerComponent:8,bytesPerRow:640*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw OSwindError.unavailable("Cannot prepare authored preview")}
            context.setFillColor(CGColor(red:0.06,green:0.1,blue:0.16,alpha:1));context.fill(CGRect(x:0,y:0,width:640,height:360))
            context.setFillColor(CGColor(red:0.16,green:0.65,blue:0.55,alpha:1));context.fill(CGRect(x:24,y:24,width:160,height:312))
            for row in 0..<5 {context.setFillColor(CGColor(gray:row==0 ? 0.9:0.4,alpha:1));context.fill(CGRect(x:210,y:280-row*46,width:row==0 ? 370:300,height:14))}
            let data=NSMutableData()
            guard let image=context.makeImage(),let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else {throw OSwindError.unavailable("Cannot encode authored preview")}
            CGImageDestinationAddImage(destination,image,nil);guard CGImageDestinationFinalize(destination) else {throw OSwindError.unavailable("Cannot encode authored preview")}
            return WorkflowEditorFrame(source:.init(library:hash,memoryID:id,revision:hash,mediaSHA256:hash,kind:.image),title:id=="owned-search" ? "Find the original decision":"Review the linked source",app:"OSwind · authored sample",timestamp:Date(timeIntervalSince1970:1793523600),png:data as Data)
        },export:{_,_,_,_,_ in throw OSwindError.unavailable("Sample preview cannot export")},locked:{false})
        let model=WorkflowModel(store:store,settings:AppSettings(),environment:env);model.allowed={true};model.helperPath="/usr/bin/true"
        guard !empty else {return model}
        model.title="From a question to the original decision"
        for id in ["owned-search","owned-source"] {
            model.add(memoryID:id)
            let deadline=ContinuousClock.now.advanced(by:.seconds(5));while model.busy,ContinuousClock.now<deadline {try await Task.sleep(for:.milliseconds(5))}
            guard !model.busy,let step=model.steps.last else {throw OSwindError.unavailable("Authored workflow preview did not load")}
            model.edit(step.id,narration:id=="owned-search" ? "Start with the decision you remember. Search your retained history, then narrow the results to the application and day.":"Open the original source to check the wording and context. Keep the source linked so the next person can see where this explanation came from.")
        }
        return model
    }
}
#endif
