import Foundation

/// Saved connection choices are not launch/call authority. Every operation is
/// separately reviewed; no server starts while decoding or restoring settings.
public struct MCPConnectionProfile:Codable,Equatable,Sendable,Identifiable {
    public var id:String
    public var name:String
    public var command:MCPServerCommand
    public init(id:String=UUID().uuidString.lowercased(),name:String,command:MCPServerCommand) {self.id=id;self.name=name;self.command=command}
    public static func ==(a:Self,b:Self)->Bool {Data(a.id.utf8)==Data(b.id.utf8) && Data(a.name.utf8)==Data(b.name.utf8) && a.command==b.command}
    public func validate()throws {
        guard UUID(uuidString:id)?.uuidString.lowercased()==id,name.utf8.count<=256,!name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!name.unicodeScalars.contains(where:{$0.value<32 || (127...159).contains($0.value)}) else {throw OSwindError.invalid("Give this connection a bounded name and valid identity")}
        try command.validate()
    }
    public var credentialPrefix:String {"mcp."+id+"."}
    public static func validate(_ profiles:[Self])throws {
        guard profiles.count<=8,Set(profiles.map(\.id)).count==profiles.count else {throw OSwindError.invalid("Use at most eight distinct MCP connections")}
        for p in profiles {try p.validate()}
    }
}

/// Only explicitly selected result text is admitted. Arguments, credential
/// values, executable paths, binary content and resource URLs are not retained.
public struct MCPResultSourceDraft:Sendable {
    public let profileID:String
    public let callID:String
    public let collectorID:String
    public let sourceID:String
    public let batch:Data
    public init(profile:MCPConnectionProfile,callID:String,output:MCPToolOutput)throws {
        try profile.validate()
        guard UUID(uuidString:callID)?.uuidString.lowercased()==callID,output.tool.range(of:#"^[A-Za-z0-9_.-]{1,128}$"#,options:.regularExpression) != nil,!output.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,output.text.utf8.count<=262144,!output.text.utf8.contains(0) else {throw OSwindError.invalid("Only bounded nonempty tool text can be saved")}
        for hash in [output.commandFingerprint,output.toolFingerprint,output.argumentsFingerprint] {guard hash.range(of:#"^[0-9a-f]{64}$"#,options:.regularExpression) != nil else {throw OSwindError.invalid("Tool result provenance is incomplete")}}
        guard output.completedAt.utf8.count<=80,([MCPWire.modern]+MCPWire.legacyVersions).contains(output.protocolVersion) else {throw OSwindError.invalid("Tool result protocol or time is unsupported")}
        _ = try QueryScopeResolver.instant(output.completedAt)
        self.profileID=profile.id;self.callID=callID;collectorID="org.oswind.mcp."+profile.id;sourceID=try TextCollector.sourceID(collectorID:collectorID,key:callID)
        let text="""
        Unverified external MCP result
        Connection: \(profile.name)
        Tool: \(output.tool)
        Protocol: \(output.protocolVersion)
        Completed: \(output.completedAt)
        Command SHA-256: \(output.commandFingerprint)
        Definition SHA-256: \(output.toolFingerprint)
        Arguments SHA-256: \(output.argumentsFingerprint)
        Server reported an error: \(output.isError ? "yes":"no")

        Result text:
        \(output.text)
        """
        let record:[String:Any]=["key":callID,"app":"External MCP","bundleID":"org.oswind.mcp","title":profile.name+" · "+output.tool,"text":text,"timestamp":output.completedAt]
        batch=try JSONSerialization.data(withJSONObject:["format":"OSwind collector batch","version":1,"collectorID":collectorID,"records":[record]],options:[.sortedKeys])
    }
}
