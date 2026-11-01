import Foundation
import Darwin
import OSwindCore

/// Explicit manual client operations never open a MemoryStore. A configured
/// server is arbitrary local code with the user's authority, not a sandbox.
func runMCPClientCLI(_ input:[String]) async throws {
    var args=input
    guard let action=args.first,["list","call"].contains(action) else {throw OSwindError.invalid("Use mcp-client list|call --config FILE --allow-server-process; call also requires --review FILE --tool NAME --arguments FILE --confirm-call")};args.removeFirst()
    func option(_ name:String)throws->String? {
        guard args.filter({$0==name}).count<=1 else {throw OSwindError.invalid("Duplicate MCP client option")}
        guard let i=args.firstIndex(of:name) else {return nil};guard i+1<args.count,!args[i+1].hasPrefix("--") else {throw OSwindError.invalid("MCP client option requires a value")};let value=args[i+1];args.removeSubrange(i...i+1);return value
    }
    func flag(_ name:String)throws->Bool {let count=args.filter {$0==name}.count;guard count<=1 else {throw OSwindError.invalid("Duplicate MCP client flag")};args.removeAll {$0==name};return count==1}
    guard let configPath=try option("--config") else {throw OSwindError.invalid("Select an explicit MCP command configuration")}
    let reviewPath=try option("--review"),tool=try option("--tool"),argumentsPath=try option("--arguments"),allowed=try flag("--allow-server-process"),confirmed=try flag("--confirm-call")
    guard args.isEmpty,allowed else {throw OSwindError.invalid("Review the configured executable/arguments, then use --allow-server-process; it runs local code with your account authority")}
    guard action=="call" ? (reviewPath != nil && tool != nil && argumentsPath != nil && confirmed):(reviewPath==nil && tool==nil && argumentsPath==nil && !confirmed) else {throw OSwindError.invalid("Review exact tool/arguments and use --confirm-call for a call; list takes only --config and --allow-server-process")}
    let command=try MCPServerCommand.decodeConfiguration(readMCPFile(configPath,maximum:65536))
    var credentials=[String:String]()
    // Reading these names is explicitly requested by this command's config;
    // no other parent environment entries are forwarded to the server.
    for name in command.credentialNames {guard let value=ProcessInfo.processInfo.environment[name] else {throw OSwindError.invalid("A configured MCP credential variable is missing")};credentials[name]=value}
    let secrets=credentials
    if action=="list" {
        let review=try await runAsyncCLI(cancellationMessage:"Stopping MCP discovery and its owned child.") {try await MCPClient.discover(command,credentials:secrets)}
        try encoded(review)
    }else {
        let review=try MCPToolReview.decodeReview(readMCPFile(reviewPath!,maximum:2*1024*1024)),arguments=try readMCPFile(argumentsPath!,maximum:65536),name=tool!
        let value=try await runAsyncCLI(cancellationMessage:"Stopping MCP call; its outcome may be unknown. Review before any retry.") {try await MCPClient.call(command,credentials:secrets,review:review,tool:name,argumentsJSON:arguments)}
        try encoded(value)
    }
}
private func readMCPFile(_ path:String,maximum:Int)throws->Data {
    let descriptor=Darwin.open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
    guard descriptor>=0 else {throw OSwindError.invalid("Cannot read the selected MCP JSON file")};let file=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer {try? file.close()}
    var stat=Darwin.stat();guard fstat(descriptor,&stat)==0,(stat.st_mode & S_IFMT)==S_IFREG,stat.st_size>=0,stat.st_size<=maximum else {throw OSwindError.invalid("Select a regular bounded MCP JSON file")}
    let data=try file.read(upToCount:maximum+1) ?? Data();guard data.count<=maximum else {throw OSwindError.invalid("MCP JSON file exceeds its byte limit")};return data
}
