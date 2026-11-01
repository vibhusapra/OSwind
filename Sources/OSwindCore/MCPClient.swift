import Foundation
import CryptoKit

public struct MCPServerCommand:Codable,Equatable,Sendable {
    public var executable:String
    public var arguments:[String]
    /// Environment variable names only. Values are supplied separately at run
    /// time and are never encoded into this configuration or its review record.
    public var credentialNames:[String]
    public init(executable:String,arguments:[String]=[],credentialNames:[String]=[]) {self.executable=executable;self.arguments=arguments;self.credentialNames=credentialNames}
    public func validate()throws {
        guard executable.hasPrefix("/"),executable.utf8.count<=4096,!executable.utf8.contains(0),arguments.count<=64,arguments.reduce(0,{$0+$1.utf8.count})<=32768,arguments.allSatisfy({!$0.utf8.contains(0)}),credentialNames.count<=32,Set(credentialNames).count==credentialNames.count else {throw OSwindError.invalid("Use an absolute MCP executable and bounded argument array")}
        for name in credentialNames {
            guard name.range(of:#"^[A-Z][A-Z0-9_]{0,63}$"#,options:.regularExpression) != nil,!Self.reserved(name) else {throw OSwindError.invalid("MCP credential variable is invalid or changes runtime loading")}
        }
    }
    public static func decodeConfiguration(_ data:Data)throws->Self {
        let value=try MCPValue.decode(data,maximum:65536)
        guard let fields=value.fields,Set(fields.keys).isSubset(of:["executable","arguments","credentialNames"]) else {throw OSwindError.invalid("Unsupported MCP command configuration")}
        let command=try JSONDecoder().decode(Self.self,from:data);try command.validate();return command
    }
    private static func reserved(_ n:String)->Bool {["PATH","HOME","TMPDIR","SHELL","ENV","BASH_ENV","ZDOTDIR","PYTHONPATH","PYTHONHOME","NODE_OPTIONS","RUBYOPT","PERL5OPT"].contains(n) || ["DYLD_","LD_","XPC_"].contains(where:n.hasPrefix)}
    func identity()throws->String {
        try validate();let url=URL(fileURLWithPath:executable).resolvingSymlinksInPath()
        let attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,let size=attributes[.size] as? NSNumber,size.intValue<=256*1024*1024,FileManager.default.isExecutableFile(atPath:url.path) else {throw OSwindError.invalid("MCP executable must be a regular executable file up to256MiB")}
        let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()};var hash=SHA256(),total=0
        while let part=try handle.read(upToCount:65536),!part.isEmpty {try Task.checkCancellation();total+=part.count;guard total<=256*1024*1024 else {throw OSwindError.invalid("MCP executable grew beyond its limit")};hash.update(data:part)}
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys];hash.update(data:try e.encode(self));return hash.finalize().map {String(format:"%02x",$0)}.joined()
    }
}
public struct MCPReviewedTool:Codable,Equatable,Sendable,Identifiable {
    public var id:String {name}
    public let name:String
    public let description:String
    public let definitionJSON:Data
    public let fingerprint:String
    init(_ value:MCPValue)throws {
        guard let name=value["name"]?.text,name.range(of:#"^[A-Za-z0-9_.-]{1,128}$"#,options:.regularExpression) != nil,value["inputSchema"]?.fields != nil else {throw OSwindError.invalid("MCP tool needs a bounded name and object schema")}
        let raw=value.encoded();guard raw.count<=65536 else {throw OSwindError.invalid("MCP tool definition exceeds64KiB")}
        self.name=name;description=value["description"]?.text ?? "";definitionJSON=raw;fingerprint=Self.hash(raw)
    }
    static func hash(_ data:Data)->String {SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()}
}
public struct MCPToolReview:Codable,Equatable,Sendable {
    public let format:String
    public let commandFingerprint:String
    public let protocolVersion:String
    public let tools:[MCPReviewedTool]
    public let reviewedAt:Date
    enum CodingKeys:String,CodingKey {case format,commandFingerprint,protocolVersion,tools,reviewedAt}
    public init(from decoder:Decoder)throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        format=try c.decode(String.self,forKey:.format);commandFingerprint=try c.decode(String.self,forKey:.commandFingerprint);protocolVersion=try c.decode(String.self,forKey:.protocolVersion);tools=try c.decode([MCPReviewedTool].self,forKey:.tools);reviewedAt=try ISOTime.decode(from:c.superDecoder(forKey:.reviewedAt))
    }
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(format,forKey:.format);try c.encode(commandFingerprint,forKey:.commandFingerprint);try c.encode(protocolVersion,forKey:.protocolVersion);try c.encode(tools,forKey:.tools);try ISOTime.encode(reviewedAt,to:c.superEncoder(forKey:.reviewedAt))
    }
    public static func decodeReview(_ data:Data)throws->Self {
        _ = try MCPValue.decode(data,maximum:2*1024*1024)
        let review=try JSONDecoder().decode(Self.self,from:data);try review.validate();return review
    }
    func validate()throws {
        guard format=="OSwind MCP tool review v1",commandFingerprint.range(of:#"^[0-9a-f]{64}$"#,options:.regularExpression) != nil,tools.count<=128,Set(tools.map(\.name)).count==tools.count else {throw OSwindError.invalid("Invalid MCP review record")}
        for tool in tools {guard tool.definitionJSON.count<=65536,try MCPReviewedTool(MCPValue.decode(tool.definitionJSON))==tool else {throw OSwindError.invalid("MCP review metadata does not match its definition")}}
    }
    init(commandFingerprint:String,protocolVersion:String,tools:[MCPReviewedTool]) {format="OSwind MCP tool review v1";self.commandFingerprint=commandFingerprint;self.protocolVersion=protocolVersion;self.tools=tools;reviewedAt=Date()}
}
public struct MCPToolOutput:Codable,Sendable {
    public let tool:String
    public let protocolVersion:String
    public let commandFingerprint:String
    public let toolFingerprint:String
    public let argumentsFingerprint:String
    public let resultJSON:Data
    public let text:String
    public let isError:Bool
    public let completedAt:String
}
/// One deliberate operation owns one child and never automatically replays a
/// call. No shell, inherited credentials, model loop or library access occurs.
public enum MCPClient {
    public static func discover(_ command:MCPServerCommand,credentials:[String:String]=[:]) async throws->MCPToolReview {
        try await perform(command,credentials:credentials) {wire,identity in
            let version=try wire.negotiate();return try MCPToolReview(commandFingerprint:identity,protocolVersion:version,tools:wire.tools(version))
        }
    }
    /// The caller must explicitly review the exact tool and JSON arguments.
    /// Annotations are descriptive and never grant read-only/write authority.
    public static func call(_ command:MCPServerCommand,credentials:[String:String]=[:],review:MCPToolReview,tool:String,argumentsJSON:Data) async throws->MCPToolOutput {
        try review.validate()
        guard review.format=="OSwind MCP tool review v1",review.tools.count<=128,let selected=review.tools.first(where:{$0.name==tool}),review.tools.filter({$0.name==tool}).count==1 else {throw OSwindError.invalid("Select exactly one reviewed MCP tool")}
        let arguments=try MCPValue.decode(argumentsJSON,maximum:65536);guard arguments.fields != nil else {throw OSwindError.invalid("MCP arguments must be a JSON object")}
        return try await perform(command,credentials:credentials,expectedIdentity:review.commandFingerprint) {wire,identity in
            guard identity==review.commandFingerprint else {throw OSwindError.invalid("MCP command changed; discover and review it again")}
            let version=try wire.negotiate();guard version==review.protocolVersion else {throw OSwindError.invalid("MCP protocol changed; review again")}
            let current=try wire.tools(version)
            guard let fresh=current.first(where:{$0.name==tool}),fresh.fingerprint==selected.fingerprint,MCPReviewedTool.hash(selected.definitionJSON)==selected.fingerprint else {throw OSwindError.invalid("MCP tool changed or was removed; review again")}
            let result=try wire.request("tools/call",fields:["name":.string(tool),"arguments":arguments],version:version,timeout:30)
            if version==MCPWire.modern {guard result["resultType"]?.text=="complete" else {throw OSwindError.unavailable("MCP server requires an unsupported additional-input workflow; call was not retried")}}
            guard let content=result["content"]?.items,content.count<=128,result["isError"]==nil || result["isError"]?.boolean != nil else {throw OSwindError.invalid("MCP tool returned an unsupported result")}
            let text=content.compactMap {item->String? in guard item["type"]?.text=="text" else {return nil};return item["text"]?.text}.joined(separator:"\n\n")
            return MCPToolOutput(tool:tool,protocolVersion:version,commandFingerprint:identity,toolFingerprint:fresh.fingerprint,argumentsFingerprint:MCPReviewedTool.hash(arguments.encoded()),resultJSON:result.encoded(),text:text,isError:result["isError"]?.boolean ?? false,completedAt:try ISOTime.string(Date()))
        }
    }
    private static func perform<T:Sendable>(_ command:MCPServerCommand,credentials:[String:String],expectedIdentity:String?=nil,_ operation:@escaping @Sendable (MCPWire,String)throws->T) async throws->T {
        try Task.checkCancellation();try command.validate()
        guard Set(credentials.keys)==Set(command.credentialNames),credentials.values.allSatisfy({$0.utf8.count<=16384 && !$0.utf8.contains(0)}),credentials.values.reduce(0,{$0+$1.utf8.count})<=65536 else {throw OSwindError.invalid("Supply only the explicitly configured MCP credentials")}
        let worker=Task.detached(priority:.utility) {() throws ->T in
            let identity=try command.identity();if let expectedIdentity {guard identity==expectedIdentity else {throw OSwindError.invalid("MCP executable or command changed; review before launching it")}};try Task.checkCancellation();let wire=try MCPWire(command:command,credentials:credentials)
            do {
                let value=try operation(wire,identity);try Task.checkCancellation()
                guard wire.close() else {throw OSwindError.unavailable("MCP child shutdown could not be verified; do not retry an unknown call")};return value
            }catch {
                guard wire.close() else {throw OSwindError.unavailable("MCP child shutdown could not be verified; preserve the unknown call outcome")};throw error
            }
        }
        return try await withTaskCancellationHandler {let value=try await worker.value;try Task.checkCancellation();return value} onCancel:{worker.cancel()}
    }
}
