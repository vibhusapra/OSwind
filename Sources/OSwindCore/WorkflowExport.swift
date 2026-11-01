import Foundation

/// Invalidation prevents a new commit. Once the short final commit has begun,
/// callers join it and report its actual result instead of promising rollback.
public final class WorkflowExportPermit:@unchecked Sendable {
    private let lock=NSLock()
    private var valid=true,committing=false
    public init() {}
    @discardableResult public func invalidate()->Bool {lock.withLock {valid=false;return !committing}}
    public var canCancel:Bool {lock.withLock {valid && !committing}}
    func check()throws {try Task.checkCancellation();try lock.withLock {guard valid,!committing else {throw CancellationError()}}}
    func beginCommit()throws {try Task.checkCancellation();try lock.withLock {guard valid,!committing else {throw CancellationError()};committing=true}}
}
public struct WorkflowExportOptions:Sendable {
    public var narrationHelper:URL
    public init(narrationHelper:URL?=nil) {self.narrationHelper=narrationHelper ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/kokoro-narrate")}
}
public struct WorkflowExportProgress:Sendable {
    public enum Phase:String,Sendable {case preparing,narrating,combining,encoding,verifying,copying,publishing}
    public let phase:Phase
    public let step:Int
    public let totalSteps:Int
}
public struct WorkflowExportInfo:Codable,Sendable {
    public let formatVersion:Int
    public let createdAt:String
    public let sourceSchema:Int
    public let draftRevision:String
    public let steps:Int
    public let duration:Double
    public let movieSHA256:String
    public let plaintextIndependentCopy:Bool
}
struct WorkflowExportEnvironment:Sendable {
    var narration:WorkflowNarrationEnvironment = .production()
    var hardwareRequired=true
}
public extension NarratedWorkflow {
    static func export(store:MemoryStore,draft:WorkflowDraft,destination:URL,options:WorkflowExportOptions = .init(),permit:WorkflowExportPermit = .init(),progress:@escaping @Sendable (WorkflowExportProgress) async throws->Void={_ in})async throws->WorkflowExportInfo {
        try await export(store:store,draft:draft,destination:destination,options:options,permit:permit,environment:.init(),progress:progress)
    }
}
extension NarratedWorkflow {
    static func export(store:MemoryStore,draft:WorkflowDraft,destination:URL,options:WorkflowExportOptions,permit:WorkflowExportPermit,environment:WorkflowExportEnvironment,progress:@escaping @Sendable (WorkflowExportProgress) async throws->Void)async throws->WorkflowExportInfo {
        let draft=try draft.validated();try permit.check();try BackupWorkspace.requireNewDestination(destination)
        let activity=try store.mediaWriteLease();defer {activity.release()}
        let source=try BackupFileTree(root:store.root.standardizedFileURL.resolvingSymlinksInPath()),parent=try BackupFileTree(root:destination.deletingLastPathComponent())
        try source.requireRootIdentity(at:store.root)
        guard try !source.isAncestor(of:parent) else {throw OSwindError.invalid("Save the independent workflow outside its source library")}
        let settings=try LibrarySettingsSnapshot.capture(root:store.root);defer {settings.release()}
        return try await withTaskCancellationHandler {
            if settings.settings.piiImports.enabled {
                return try await settings.settings.piiImports.withScanner {scanner in
                    try await WorkflowExportOperation.run(store:store,source:source,parent:parent,draft:draft,destination:destination,options:options,permit:permit,settings:settings,scanner:scanner,environment:environment,progress:progress)
                }
            }
            return try await WorkflowExportOperation.run(store:store,source:source,parent:parent,draft:draft,destination:destination,options:options,permit:permit,settings:settings,scanner:nil,environment:environment,progress:progress)
        } onCancel: {permit.invalidate()}
    }
}
private enum WorkflowExportOperation {
    static func run(store:MemoryStore,source:BackupFileTree,parent:BackupFileTree,draft:WorkflowDraft,destination:URL,options:WorkflowExportOptions,permit:WorkflowExportPermit,settings:LibrarySettingsSnapshot,scanner:PIIImportScanner?,environment:WorkflowExportEnvironment,progress:@escaping @Sendable (WorkflowExportProgress) async throws->Void)async throws->WorkflowExportInfo {
        let report:@Sendable (WorkflowExportProgress.Phase,Int) async throws->Void = {phase,step in
            try permit.check();try await progress(.init(phase:phase,step:step,totalSteps:draft.steps.count));try permit.check()
        }
        try await report(.preparing,0)
        for text in [draft.title]+draft.steps.flatMap({[$0.title,$0.narration]}) {try WorkflowFrameReservation.safeText(text,policy:settings.settings.privacy)}
        if let scanner {
            let text=draft.steps.map {$0.title+"\n"+$0.narration}.joined(separator:"\n\n")
            let checked=try await scanner.sanitize(Memory(kind:.note,title:draft.title,text:text),policy:settings.settings.privacy)
            guard !checked.redacted else {throw OSwindError.unavailable("Local privacy inspection found sensitive workflow text")}
        }
        var reservations=[WorkflowFrameReservation]();defer {for item in reservations {item.release()}}
        for step in draft.steps {
            try permit.check()
            let frame=try await WorkflowFrameReservation.make(store:store,memoryID:step.source.memoryID,frameOrdinal:step.source.frameOrdinal,settings:settings,scanner:scanner)
            guard frame.preview.source==step.source else {frame.release();throw OSwindError.unavailable("A selected workflow source changed. Review its current frame before exporting.")}
            reservations.append(frame)
        }
        let workspace=try await store.libraryWorkspaceAsync("oswind-workflow",bucket:.video)
        defer {withExtendedLifetime(workspace) {}}
        var narration=[WorkflowNarrationResult]()
        for (index,step) in draft.steps.enumerated() {
            try await report(.narrating,index+1)
            narration.append(try await LocalWorkflowNarrator.generate(script:step.narration,step:index+1,workspace:workspace,helper:options.narrationHelper,environment:environment.narration))
        }
        try await report(.combining,0)
        let timeline=try LocalWorkflowTimeline.combine(draft:draft,narrations:narration,workspace:workspace)
        try await report(.encoding,0)
        _ = try await WorkflowVideoFrames.render(draft:draft,frames:reservations.map(\.preview),timeline:timeline,workspace:workspace,hardwareRequired:environment.hardwareRequired)
        let movie=try await WorkflowVideoMux.make(timeline:timeline,workspace:workspace)
        try await report(.verifying,0)
        let verification=try await WorkflowMovieVerification.inspect(url:movie,timeline:timeline,narration:workspace.url.appendingPathComponent("narration.wav"))
        // Recheck all original source reservations before making the explicit
        // destination copy, and again atomically with its final publication.
        try withSources(reservations,store:store,settings:settings,permit:permit) {}
        try await report(.copying,0)
        try BackupWorkspace.requireNewDestination(destination)
        try parent.requireRootIdentity(at:destination.deletingLastPathComponent())
        try source.requireRootIdentity(at:store.root)
        guard try !source.isAncestor(of:parent) else {throw OSwindError.invalid("The workflow destination moved inside its source library")}
        _ = try BackupWorkspace.cleanupAbandoned(in:destination.deletingLastPathComponent(),labels:["oswind-workflow-partial"])
        let output=try BackupWorkspace(in:destination.deletingLastPathComponent(),label:"oswind-workflow-partial",parentIdentity:try parent.identity())
        defer {withExtendedLifetime(output) {}}
        let info=WorkflowExportInfo(formatVersion:1,createdAt:try ISOTime.string(Date()),sourceSchema:MemoryStore.schemaVersion,draftRevision:try draft.revision,steps:draft.steps.count,duration:timeline.duration,movieSHA256:try workspace.tree.digest("workflow.mp4",limit:256*1024*1024).sha256,plaintextIndependentCopy:true)
        try WorkflowExportFiles.write(draft:draft,reservations:reservations,narration:narration,timeline:timeline,verification:verification,info:info,workspace:workspace,output:output,permit:permit)
        try await report(.publishing,0)
        try withSources(reservations,store:store,settings:settings,permit:permit) {
            try parent.requireRootIdentity(at:destination.deletingLastPathComponent())
            try source.requireRootIdentity(at:store.root)
            guard try !source.isAncestor(of:parent) else {throw OSwindError.invalid("The workflow destination moved inside its source library")}
            try permit.beginCommit();try output.publish(as:destination)
        }
        // There is intentionally no cancellation check after a completed
        // rename: callers must report an already-created independent export.
        return info
    }
    private static func withSources<T>(_ values:[WorkflowFrameReservation],store:MemoryStore,settings:LibrarySettingsSnapshot,permit:WorkflowExportPermit,_ body:()throws->T)throws->T {
        func admitted(_ index:Int)throws->T {
            if index<values.count {return try values[index].snapshot.withAdmission(for:store) {_ in try admitted(index+1)}}
            return try store.withRoutineDatabase {_ in
                try settings.withCurrent(root:store.root,policy:settings.settings.privacy) {
                    try permit.check()
                    for value in values {
                        guard value.preview.source.library==WorkflowSourceBinding.libraryKey(store),let memory=try store.get(value.preview.source.memoryID),try VisualSourcePlan.make(memory)?.revision==value.preview.source.revision else {throw OSwindError.unavailable("A workflow source changed before publication")}
                        try WorkflowFrameReservation.allowed(memory,policy:settings.settings.privacy)
                    }
                    return try body()
                }
            }
        }
        return try admitted(0)
    }
}
