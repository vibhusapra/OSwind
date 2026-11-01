import Foundation
import CryptoKit

/// A draft binds a selected retained frame before narration is edited. Export
/// must reacquire and validate that binding; a memory ID alone is insufficient.
public struct WorkflowSourceBinding:Codable,Equatable,Sendable {
    public enum Kind:String,Codable,Sendable {case image,video}
    public var library:String
    public var memoryID:String
    public var revision:String
    public var mediaSHA256:String
    public var kind:Kind
    public var frameOrdinal:Int
    public var frameTime:Double?
    public init(library:String,memoryID:String,revision:String,mediaSHA256:String,kind:Kind,frameOrdinal:Int=0,frameTime:Double?=nil) {
        self.library=library;self.memoryID=memoryID;self.revision=revision;self.mediaSHA256=mediaSHA256;self.kind=kind;self.frameOrdinal=frameOrdinal;self.frameTime=frameTime
    }
    func validate()throws {
        guard [library,revision,mediaSHA256].allSatisfy(Self.isDigest),!memoryID.isEmpty,memoryID.utf8.count<=1024,!memoryID.utf8.contains(0),
              (0..<240).contains(frameOrdinal) else {throw OSwindError.invalid("Invalid retained workflow source binding")}
        switch kind {
        case .image:guard frameOrdinal==0,frameTime==nil else {throw OSwindError.invalid("A snapshot has one image, not replay frame coverage")}
        case .video:guard let frameTime,frameTime.isFinite,(0...120).contains(frameTime) else {throw OSwindError.invalid("Choose an exact retained replay frame")}
        }
    }
    static func isDigest(_ value:String)->Bool {value.utf8.count==64 && value.utf8.allSatisfy {(48...57).contains($0)||(97...102).contains($0)}}
    static func libraryKey(_ store:MemoryStore)->String {
        let identity=store.mediaRootIdentity
        return WorkflowDraft.digest(Data("OSwind workflow library v1:\(identity.device):\(identity.inode)".utf8))
    }
}

public struct WorkflowStep:Codable,Equatable,Identifiable,Sendable {
    public var id:UUID
    public var source:WorkflowSourceBinding
    public var title:String
    public var narration:String
    public init(id:UUID=UUID(),source:WorkflowSourceBinding,title:String,narration:String) {self.id=id;self.source=source;self.title=title;self.narration=narration}
}

/// Rendering is an explicit operation on a validated immutable draft. Editing a
/// title, order or script changes its revision; no edit launches model work.
public struct WorkflowDraft:Codable,Equatable,Sendable {
    public static let maximumSteps=8
    public static let maximumDuration:Double=120
    public var title:String
    public var steps:[WorkflowStep]
    public init(title:String="Workflow",steps:[WorkflowStep]=[]) {self.title=title;self.steps=steps}
    public func validated()throws->Self {
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count<=240,!title.contains(where:{$0.isNewline}),!title.utf8.contains(0),
              (1...Self.maximumSteps).contains(steps.count),Set(steps.map(\.id)).count==steps.count else {throw OSwindError.invalid("A workflow needs a title and one to eight distinct steps")}
        var scriptBytes=0
        for step in steps {
            try step.source.validate()
            guard !step.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,step.title.utf8.count<=240,!step.title.contains(where:{$0.isNewline}),!step.title.utf8.contains(0),
                  !step.narration.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,step.narration.utf8.count<=4000,!step.narration.utf8.contains(0),
                  step.source.library==steps[0].source.library else {throw OSwindError.invalid("Workflow steps need bounded titles/scripts from the same library")}
            scriptBytes+=step.narration.utf8.count
        }
        guard scriptBytes<=12000 else {throw OSwindError.invalid("Workflow narration exceeds 12,000 UTF-8 bytes")}
        return self
    }
    public var revision:String {
        get throws {
            _ = try validated()
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            return Self.digest(try encoder.encode(self))
        }
    }
    static func digest(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
}
