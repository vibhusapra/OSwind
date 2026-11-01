#if DEBUG
import Foundation
import CryptoKit
import OSwindCore

@MainActor enum MCPToolsPreview {
    static func make(store:MemoryStore,stage:String) async throws->MCPToolsModel {
        let definition:[String:Any]=["name":"search_project_notes","description":"Search selected local project notes. Sample server metadata; always review the exact call.","inputSchema":["type":"object","properties":["query":["type":"string"],"project":["type":"string"]],"required":["query"]],"annotations":["readOnlyHint":true]]
        let bytes=try JSONSerialization.data(withJSONObject:definition,options:[.sortedKeys]),fingerprint=SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()
        let reviewData=try JSONSerialization.data(withJSONObject:["format":"OSwind MCP tool review v1","commandFingerprint":String(repeating:"a",count:64),"protocolVersion":"2026-07-28","reviewedAt":"2026-11-01T06:00:00Z","tools":[["name":"search_project_notes","description":definition["description"]!,"definitionJSON":String(decoding:bytes,as:UTF8.self),"fingerprint":fingerprint]]])
        let review=try MCPToolReview.decodeReview(reviewData),text="Marigold release review · sample\n\nMira owns the release checklist. The team agreed to ship the smaller rollout on Friday after the final device check.\n\nOpen item: finish the microphone route-recovery check. This is invented text for visual review."
        let raw=try JSONSerialization.data(withJSONObject:["content":[["type":"text","text":text]],"resultType":"complete","isError":false])
        let outputData=try JSONSerialization.data(withJSONObject:["tool":"search_project_notes","protocolVersion":"2026-07-28","commandFingerprint":String(repeating:"a",count:64),"toolFingerprint":fingerprint,"argumentsFingerprint":String(repeating:"c",count:64),"resultJSON":raw.base64EncodedString(),"text":text,"isError":false,"completedAt":"2026-11-01T06:00:00Z"]),output=try JSONDecoder().decode(MCPToolOutput.self,from:outputData)
        var settings=AppSettings();settings.mcpConnections=stage=="ToolsEmpty" ? []:[.init(name:"Local research · sample",command:.init(executable:"/absolute/path/to/research-server",arguments:["--project","marigold"],credentialNames:["RESEARCH_TOKEN"]))]
        let runner=MCPClientRunner(discover:{_,_ in review},call:{_,_,_,_,_ in output})
        let model=MCPToolsModel(store:store,settings:settings,runner:runner,locked:{false},readCredential:{_ in "owned-sample-not-a-credential"},writeCredential:{_,_ in throw OSwindError.unavailable("Preview does not write credentials")})
        if stage != "ToolsEmpty" && stage != "ToolsSetup" {
            model.requestDiscovery();if let action=model.pendingReview {model.confirm(action.id)};try await settle(model)
            guard model.catalog != nil else {throw OSwindError.unavailable("Owned tool preview did not discover its fixture")}
            model.chooseTool("search_project_notes");model.argumentsText="{\n  \"query\": \"release decisions and open items\",\n  \"project\": \"marigold\"\n}"
            if stage=="ToolsReview" {model.requestCall()}
            if stage=="ToolsResult" {model.requestCall();if let action=model.pendingReview {model.confirm(action.id)};try await settle(model);guard model.result != nil else {throw OSwindError.unavailable("Owned tool result preview did not finish")}}
        }
        return model
    }
    private static func settle(_ model:MCPToolsModel)async throws {
        let end=ContinuousClock.now.advanced(by:.seconds(5));while model.busy {guard ContinuousClock.now<end else {throw OSwindError.unavailable("Owned tool preview timed out")};try await Task.sleep(for:.milliseconds(10))}
    }
}
#endif
