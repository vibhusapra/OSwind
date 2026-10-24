import Foundation
import CoreGraphics
import ImageIO

extension MemoryStore {
    /// A preview is decoded from a reserved immutable source snapshot. It must
    /// match the returned search evidence; an unrelated replay poster is unsafe.
    public func visualPreview(memory:Memory,match:VisualMatch,maxDimension:Int=640) async throws -> CGImage {
        guard (64...2048).contains(maxDimension),match.preprocessingID==VisualSourcePlan.preprocessingID else {throw OSwindError.invalid("Invalid visual preview request")}
        let policy=AppSettings.load(root:root).privacy
        guard let current=try get(memory.id),VisualRetrievalEngine.allowed(current,policy:policy) else {throw OSwindError.unavailable("Visual preview is excluded by current privacy rules")}
        guard let plan=try VisualSourcePlan.make(memory) else {throw OSwindError.unavailable("No retained image or replay")}
        let snapshot:any VisualMediaSnapshot
        if plan.kind == .image {
            guard let image=try VisualImageSnapshot.make(store:self,id:memory.id) else {throw OSwindError.unavailable("Source no longer exists")};snapshot=image
        } else {
            guard let video=try VisualVideoSnapshot.make(store:self,id:memory.id) else {throw OSwindError.unavailable("Source no longer exists")};snapshot=video
        }
        defer {snapshot.release()}
        guard snapshot.plan.revision==match.sourceRevision,snapshot.sha256==match.mediaSHA256,
              snapshot.plan.points.contains(where:{$0.ordinal==match.frameOrdinal && $0.time==match.frameTime}) else {throw OSwindError.unavailable("Visual source changed; refresh its match")}
        _ = try snapshot.withAdmission(for:self) {current in guard VisualRetrievalEngine.allowed(current,policy:policy) else {throw OSwindError.unavailable("Visual preview is excluded by current privacy rules")};return current}
        if let image=snapshot as? VisualImageSnapshot {
            try Task.checkCancellation()
            guard match.frameTime==nil,match.decodedTime==nil,
                  let source=CGImageSourceCreateWithData(image.data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let result=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:maxDimension,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else {throw OSwindError.unavailable("Cannot decode the matched image")}
            return result
        }
        guard let video=snapshot as? VisualVideoSnapshot,let time=match.decodedTime,let frame=match.frameTime,time.isFinite,time>=0,abs(time-frame)<=0.1 else {throw OSwindError.invalid("Invalid matched replay time")}
        let decoder=try await VisualReplayDecoder.open(video.url,maxDimension:maxDimension);defer {decoder.close()}
        return try await decoder.image(at:time).image
    }
}
