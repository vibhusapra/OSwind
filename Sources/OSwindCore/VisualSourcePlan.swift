import Foundation
import CryptoKit

/// A visual vector must identify actual retained pixels. A text-only hash is
/// insufficient when an image, movie, frame plan or preprocessing changes.
struct VisualSourcePlan:Equatable,Sendable {
    enum Kind:String,Codable,Sendable {case image,video}
    struct Point:Codable,Equatable,Sendable {var ordinal:Int;var time:Double?}
    static let preprocessingID="imageio-srgb-white-bilinear224-nchw-v1;gemma-unigram-swift1.3.5-eos1-pad0-right64"
    let memoryID:String
    let kind:Kind
    let path:String
    let points:[Point]
    let revision:String
    private struct Revision:Encodable {
        var memoryID:String
        var evidence:String
        var endTimestamp:Date?
        var bundleID:String
        var kind:Kind
        var path:String
        var points:[Point]
    }
    static func make(_ memory:Memory) throws -> Self? {
        guard memory.searchPreview==nil else {throw OSwindError.invalid("Hydrate the source before planning visual indexing")}
        guard memory.imagePath != nil || memory.videoPath != nil else {return nil}
        guard memory.kind == .screen,memory.transcript==nil,memory.recap==nil else {throw OSwindError.invalid("Retained visual indexing requires a complete screen source")}
        let kind:Kind,path:String,points:[Point]
        if let video=memory.videoPath {
            guard let recording=memory.visualRecording else {throw OSwindError.invalid("Replay indexing requires validated frame metadata")}
            _ = try recording.validated()
            guard memory.text==recording.text else {throw OSwindError.invalid("Replay text and frame metadata differ")}
            kind = .video;path=video;points=recording.frames.enumerated().map {Point(ordinal:$0.offset,time:$0.element.time)}
        } else {
            // A poster must not be presented as coverage of every replay frame.
            guard memory.visualRecording==nil else {throw OSwindError.unavailable("Retained replay video is missing; a poster cannot substitute for frame coverage")}
            kind = .image;path=memory.imagePath!;points=[Point(ordinal:0,time:nil)]
        }
        let parts=try BackupFileTree.components(path)
        guard parts.count>=2,parts.first==(kind == .image ? "images":"video"),!parts.contains(".staging") else {throw OSwindError.invalid("Visual source must be an admitted image or video member, outside staging")}
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        let metadata=Revision(memoryID:memory.id,evidence:memory.evidenceHash,endTimestamp:memory.endTimestamp,bundleID:memory.bundleID,kind:kind,path:path,points:points)
        let revision=SHA256.hash(data:try encoder.encode(metadata)).map {String(format:"%02x",$0)}.joined()
        return Self(memoryID:memory.id,kind:kind,path:path,points:points,revision:revision)
    }
    func vectorRevision(mediaSHA256:String,modelID:String,point:Point,preprocessingID:String=Self.preprocessingID) throws -> String {
        guard mediaSHA256.utf8.count==64,mediaSHA256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),
              points.contains(point),!modelID.isEmpty,modelID.utf8.count<=512,!modelID.utf8.contains(0),
              !preprocessingID.isEmpty,preprocessingID.utf8.count<=512,!preprocessingID.utf8.contains(0)
        else {throw OSwindError.invalid("Invalid visual vector identity")}
        struct Identity:Encodable {var source:String;var media:String;var model:String;var preprocessing:String;var point:Point}
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data:try encoder.encode(Identity(source:revision,media:mediaSHA256,model:modelID,preprocessing:preprocessingID,point:point))).map {String(format:"%02x",$0)}.joined()
    }
}
