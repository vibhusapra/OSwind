import Foundation
import OSwindCore
import Darwin

private struct WorkflowCLIFrame:Codable {
    let source:WorkflowSourceBinding
    let title:String
    let app:String
    let timestamp:String
    let frames:[WorkflowFrameChoice]
    let draft:WorkflowDraft
}

@MainActor func runWorkflowCLI()async throws {
    guard let action=args.first,["frame","export"].contains(action) else {throw OSwindError.invalid("Use workflow frame ID [--frame N], or workflow export --draft JSON --output NEW_DIR [--helper FILE]")};args.removeFirst()
    if action=="frame" {
        let value=try validatedOption("--frame") ?? "0"
        guard let ordinal=Int(value),(0..<240).contains(ordinal),args.count==1,!args[0].hasPrefix("--") else {throw OSwindError.invalid("Use workflow frame MEMORY_ID [--frame 0..239]")}
        let id=args[0],store=try MemoryStore(root:root);defer {try? store.close()}
        try await piiOutput {
            let preview=try await runAsyncCLI(cancellationMessage:"Stopping retained-frame inspection and joining local work.") {try await NarratedWorkflow.preview(store:store,memoryID:id,frameOrdinal:ordinal)}
            let title=preview.title.isEmpty ? "Retained source":preview.title
            return WorkflowCLIFrame(source:preview.source,title:title,app:preview.app,timestamp:ISO8601DateFormatter().string(from:preview.timestamp),frames:preview.frames,draft:.init(steps:[.init(source:preview.source,title:title,narration:"")]))
        }
    }else {
        guard let input=try validatedOption("--draft"),let output=try validatedOption("--output") else {throw OSwindError.invalid("Use workflow export --draft JSON --output NEW_DIR [--helper FILE]")}
        let helper=try validatedOption("--helper");guard args.isEmpty else {throw OSwindError.invalid("Unknown workflow export option")}
        let descriptor=open(input,O_RDONLY|O_CLOEXEC|O_NONBLOCK)
        guard descriptor>=0 else {throw OSwindError.invalid("Cannot open workflow draft")}
        let file=FileHandle(fileDescriptor:descriptor,closeOnDealloc:false);defer {try? file.close()}
        var metadata=stat();guard fstat(descriptor,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_size<=128*1024 else {throw OSwindError.invalid("Choose a regular workflow JSON file up to 128 KiB")}
        let bytes=try file.read(upToCount:128*1024+1) ?? Data();guard bytes.count<=128*1024 else {throw OSwindError.invalid("Workflow draft exceeds 128 KiB")}
        let draft=try JSONDecoder().decode(WorkflowDraft.self,from:bytes).validated(),destination=URL(fileURLWithPath:output),options=WorkflowExportOptions(narrationHelper:helper.map {URL(fileURLWithPath:$0)})
        let store=try MemoryStore(root:root);defer {try? store.close()}
        try await piiOutput {
            try await runAsyncCLI(cancellationMessage:"Stopping workflow export; joining local work and removing unpublished output.") {
                try await NarratedWorkflow.export(store:store,draft:draft,destination:destination,options:options,progress:{value in
                    let message=value.phase.rawValue+(value.step>0 ? " \(value.step)/\(value.totalSteps)":"")
                    FileHandle.standardError.write(Data((message+"\n").utf8))
                })
            }
        }
    }
}
