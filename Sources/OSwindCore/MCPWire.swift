import Foundation
import Darwin

private enum MCPWireFailure:Error {case timeout,rpc(MCPValue)}
/// Used only inside one detached worker. Streams are nonblocking so cancellation
/// and finite byte/time budgets apply even when the child never reads stdin.
final class MCPWire {
    static let modern="2026-07-28"
    private let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
    private let root:URL
    private var buffer=Data(),outputBytes=0,errorBytes=0,notifications=0,serial=0
    private var staleIDs=Set<String>(),closed=false,stdoutEOF=false
    private let deadline=ContinuousClock.now.advanced(by:.seconds(120))
    init(command:MCPServerCommand,credentials:[String:String])throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("oswind-mcp-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        process.executableURL=URL(fileURLWithPath:command.executable);process.arguments=command.arguments;process.currentDirectoryURL=root
        process.environment=["HOME":root.path,"TMPDIR":root.path+"/","PATH":"/usr/bin:/bin:/usr/sbin:/sbin","LANG":"en_US.UTF-8"].merging(credentials,uniquingKeysWith:{$1})
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        do {
            try process.run()
            try input.fileHandleForReading.close();try output.fileHandleForWriting.close();try errors.fileHandleForWriting.close()
            for handle in [input.fileHandleForWriting,output.fileHandleForReading,errors.fileHandleForReading] {
                guard fcntl(handle.fileDescriptor,F_SETFL,fcntl(handle.fileDescriptor,F_GETFL)|O_NONBLOCK)>=0 else {throw OSwindError.unavailable("Cannot bound MCP stream I/O")}
            }
            guard fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)>=0 else {throw OSwindError.unavailable("Cannot protect MCP stream writes")}
        }catch {_ = close();throw OSwindError.unavailable("MCP server could not start with its explicit command and environment")}
    }
    deinit {_ = close()}
    @discardableResult func close()->Bool {
        guard !closed else {return !process.isRunning};closed=true;try? input.fileHandleForWriting.close()
        // Do not await EOF: a server may leave descendants holding the pipe.
        // Only this Process is owned; no global names or process groups killed.
        let grace=ContinuousClock.now.advanced(by:.milliseconds(300))
        while process.isRunning && ContinuousClock.now<grace {discard();Thread.sleep(forTimeInterval:0.01)}
        if process.isRunning {process.terminate();let end=ContinuousClock.now.advanced(by:.seconds(1));while process.isRunning && ContinuousClock.now<end {discard();Thread.sleep(forTimeInterval:0.01)}}
        if process.isRunning {kill(process.processIdentifier,SIGKILL);let end=ContinuousClock.now.advanced(by:.seconds(2));while process.isRunning && ContinuousClock.now<end {Thread.sleep(forTimeInterval:0.01)}}
        try? output.fileHandleForReading.close();try? errors.fileHandleForReading.close()
        try? input.fileHandleForReading.close();try? output.fileHandleForWriting.close();try? errors.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at:root)
        return !process.isRunning
    }
    private func discard() {
        for handle in [output.fileHandleForReading,errors.fileHandleForReading] {
            var data=[UInt8](repeating:0,count:16384)
            for _ in 0..<4 {if read(handle.fileDescriptor,&data,data.count)<=0 {break}}
        }
    }
    private func check(_ end:ContinuousClock.Instant)throws {try Task.checkCancellation();guard ContinuousClock.now<end,ContinuousClock.now<deadline else {throw MCPWireFailure.timeout}}
    private func pump()throws {
        for (handle,isError) in [(output.fileHandleForReading,false),(errors.fileHandleForReading,true)] {
            var bytes=[UInt8](repeating:0,count:16384)
            for _ in 0..<16 {
                let n=read(handle.fileDescriptor,&bytes,bytes.count)
                if n==0 {if !isError {stdoutEOF=true};break}
                if n<0 {if errno==EINTR {continue};if errno==EAGAIN {break};throw OSwindError.unavailable("MCP output stream failed")}
                if isError {errorBytes+=n;guard errorBytes<=262144 else {throw OSwindError.unavailable("MCP stderr exceeds256KiB; raw diagnostics are not retained")}}
                else {outputBytes+=n;guard outputBytes<=2*1024*1024,buffer.count+n<=524288 else {throw OSwindError.unavailable("MCP stdout exceeds its bound")};buffer.append(contentsOf:bytes.prefix(n))}
            }
        }
        if !buffer.contains(10),buffer.count>262144 {throw OSwindError.invalid("MCP frame exceeds256KiB")}
    }
    private func send(_ value:MCPValue,end:ContinuousClock.Instant)throws {
        var data=value.encoded();data.append(10);guard data.count<=262144 else {throw OSwindError.invalid("MCP request exceeds256KiB")};var offset=0
        while offset<data.count {
            try check(end);try pump()
            let n=data.withUnsafeBytes {raw in Darwin.write(input.fileHandleForWriting.fileDescriptor,raw.baseAddress!.advanced(by:offset),data.count-offset)}
            if n>0 {offset+=n}else if n<0 && errno != EAGAIN && errno != EINTR {throw OSwindError.unavailable("MCP server closed its input; any prior call outcome must be reviewed")}
            else {Thread.sleep(forTimeInterval:0.005)}
        }
    }
    private func metadata(_ version:String)->MCPValue {.object(["io.modelcontextprotocol/protocolVersion":.string(version),"io.modelcontextprotocol/clientInfo":.object(["name":.string("OSwind"),"version":.string("0.1.0")]),"io.modelcontextprotocol/clientCapabilities":.object([:])])}
    private func cancel(_ id:String) {
        var data=MCPValue.object(["jsonrpc":.string("2.0"),"method":.string("notifications/cancelled"),"params":.object(["requestId":.string(id),"reason":.string("OSwind stopped this request")])]).encoded();data.append(10)
        // Best effort on a nonblocking pipe, followed by bounded owned-child
        // shutdown. Never block cancellation waiting for a server to read.
        _ = data.withUnsafeBytes {Darwin.write(input.fileHandleForWriting.fileDescriptor,$0.baseAddress!,data.count)}
    }
    private func exchange(_ method:String,fields:[String:MCPValue],version:String?,timeout:Double)throws->MCPValue {
        serial+=1;let id="oswind-\(serial)",end=ContinuousClock.now.advanced(by:.seconds(timeout));var params=fields
        if let version,version==Self.modern {params["_meta"]=metadata(version)}
        try send(.object(["jsonrpc":.string("2.0"),"id":.string(id),"method":.string(method),"params":.object(params)]),end:end)
        do {
            while true {
                try check(end);try pump()
                while let newline=buffer.firstIndex(of:10) {
                    let frame=Data(buffer[..<newline]);buffer.removeSubrange(...newline)
                    guard !frame.isEmpty,frame.count<=262144 else {throw OSwindError.invalid("MCP server emitted an empty or oversized frame")}
                    let value=try MCPValue.decode(frame)
                    guard value.fields != nil,value["jsonrpc"]?.text=="2.0" else {throw OSwindError.invalid("MCP server emitted an invalid JSON-RPC envelope")}
                    if let method=value["method"]?.text {
                        guard value["id"]==nil,value["result"]==nil,value["error"]==nil,["notifications/progress","notifications/message","notifications/tools/list_changed","notifications/resources/list_changed","notifications/prompts/list_changed"].contains(method) else {throw OSwindError.invalid("MCP server requested an undeclared client capability or sent an unsupported message")}
                        notifications+=1;guard notifications<=64 else {throw OSwindError.invalid("MCP notification budget exceeded")};continue
                    }
                    guard let responseID=value["id"]?.text else {throw OSwindError.invalid("MCP response needs the exact string request ID")}
                    if staleIDs.remove(responseID) != nil {continue}
                    guard responseID==id,(value["result"]==nil) != (value["error"]==nil) else {throw OSwindError.invalid("MCP response ID or result/error envelope does not match")}
                    if let error=value["error"] {guard error.fields != nil,case .number(let code)?=error["code"],Int64(code) != nil,error["message"]?.text != nil else {throw OSwindError.invalid("MCP error envelope is malformed")};throw MCPWireFailure.rpc(error)}
                    guard let result=value["result"],result.fields != nil else {throw OSwindError.invalid("MCP response result must be an object")};return result
                }
                guard !stdoutEOF else {throw OSwindError.unavailable("MCP server exited before its complete response; no call is replayed")}
                Thread.sleep(forTimeInterval:0.005)
            }
        }catch MCPWireFailure.timeout {cancel(id);staleIDs.insert(id);throw MCPWireFailure.timeout}
        catch is CancellationError {cancel(id);throw CancellationError()}
    }
    func request(_ method:String,fields:[String:MCPValue]=[:],version:String,timeout:Double=8)throws->MCPValue {
        do {return try exchange(method,fields:fields,version:version,timeout:timeout)}
        catch MCPWireFailure.rpc {throw OSwindError.unavailable("MCP server returned a protocol error; raw server diagnostics are omitted and calls are not retried")}
        catch MCPWireFailure.timeout {throw OSwindError.unavailable("MCP request timed out; its outcome may be unknown and it was not retried")}
    }
    func negotiate()throws->String {
        var legacy=false
        do {
            let result=try exchange("server/discover",fields:[:],version:Self.modern,timeout:2)
            guard result["resultType"]?.text=="complete",let versions=result["supportedVersions"]?.items,versions.contains(.string(Self.modern)),result["capabilities"]?["tools"]?.fields != nil else {throw OSwindError.unavailable("MCP discovery has no supported modern tools protocol")}
            return Self.modern
        }catch MCPWireFailure.rpc(let error) {
            // These errors establish the modern era. In particular an advertised
            // legacy version is not permission to switch to initialize here.
            if case .number(let code)?=error["code"],["-32020","-32021","-32022"].contains(code) {throw OSwindError.unavailable("Modern MCP server rejected the version or client capabilities; no legacy fallback")}
            legacy=true
        }catch MCPWireFailure.timeout {legacy=true}
        guard legacy else {throw OSwindError.unavailable("MCP negotiation failed")}
        let result=try request("initialize",fields:["protocolVersion":.string("2025-11-25"),"capabilities":.object([:]),"clientInfo":.object(["name":.string("OSwind"),"version":.string("0.1.0")])],version:"2025-11-25")
        guard let version=result["protocolVersion"]?.text,["2024-11-05","2025-03-26","2025-06-18","2025-11-25"].contains(version),result["capabilities"]?["tools"]?.fields != nil else {throw OSwindError.unavailable("Legacy MCP server has no supported tools protocol")}
        try send(.object(["jsonrpc":.string("2.0"),"method":.string("notifications/initialized"),"params":.object([:])]),end:ContinuousClock.now.advanced(by:.seconds(2)))
        return version
    }
    func tools(_ version:String)throws->[MCPReviewedTool] {
        var result=[MCPReviewedTool](),seen=Set<String>(),cursors=Set<Data>(),cursor:String?
        for _ in 0..<16 {
            let page=try request("tools/list",fields:cursor.map {["cursor":MCPValue.string($0)]} ?? [:],version:version)
            guard version != Self.modern || page["resultType"]?.text=="complete",let values=page["tools"]?.items,values.count+result.count<=128 else {throw OSwindError.invalid("MCP tool page is invalid or exceeds128 tools")}
            for value in values {let tool=try MCPReviewedTool(value);guard seen.insert(tool.name).inserted else {throw OSwindError.invalid("MCP tool names repeat across pages")};result.append(tool)}
            guard let next=page["nextCursor"] else {return result}
            guard let raw=next.text,!raw.isEmpty,raw.utf8.count<=4096,cursors.insert(Data(raw.utf8)).inserted else {throw OSwindError.invalid("MCP tool cursor is invalid or repeats")};cursor=raw
        }
        throw OSwindError.invalid("MCP tools exceed16 pages")
    }
}
