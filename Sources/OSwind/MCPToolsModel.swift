import Foundation
import Combine
import OSwindCore

struct MCPClientRunner:Sendable {
    var discover:@Sendable (MCPServerCommand,[String:String]) async throws->MCPToolReview
    var call:@Sendable (MCPServerCommand,[String:String],MCPToolReview,String,Data) async throws->MCPToolOutput
    static var native:Self {.init(discover:{try await MCPClient.discover($0,credentials:$1)},call:{try await MCPClient.call($0,credentials:$1,review:$2,tool:$3,argumentsJSON:$4)})}
}
struct MCPActionReview:Identifiable {
    enum Kind {case discovery,call}
    let id=UUID(),generation:UUID
    let kind:Kind,profile:MCPConnectionProfile,tool:MCPReviewedTool?,catalog:MCPToolReview?,arguments:Data?
    var title:String {kind == .discovery ? "Start this server?":"Run this exact tool call?"}
}
struct MCPVisibleResult {
    let profile:MCPConnectionProfile,callID:String,output:MCPToolOutput
}

@MainActor final class MCPToolsModel:ObservableObject {
    @Published private(set) var profiles:[MCPConnectionProfile]
    @Published private(set) var selectedID:String?
    @Published private(set) var catalog:MCPToolReview?
    @Published private(set) var selectedTool:String?
    @Published var argumentsText="{}" {didSet {if oldValue != argumentsText {pendingReview=nil}}}
    @Published private(set) var result:MCPVisibleResult?
    @Published private(set) var pendingReview:MCPActionReview?
    @Published private(set) var busy=false
    @Published private(set) var stopping=false
    @Published private(set) var status="Choose a connection, review its command, then discover its tools."
    @Published private(set) var error:String?
    @Published private(set) var savedSourceID:String?
    @Published private(set) var redactionEpoch=UUID()
    @Published var credentialDrafts=[String:String]()
    @Published var showingConfiguration=false
    var allowed:()->Bool={true}
    var saveProfiles:(([MCPConnectionProfile])throws->Void)?
    var saveSource:((MCPResultSourceDraft) async throws->CollectorImportResult)?
    private let store:MemoryStore,runner:MCPClientRunner,locked:()->Bool
    private let readCredential:(String)->String?,writeCredential:(String,String)throws->Void
    private var settings:AppSettings,generation=UUID(),operationID:UUID?
    private var worker:Task<Void,Never>?
    init(store:MemoryStore,settings:AppSettings,runner:MCPClientRunner = .native,locked:@escaping ()->Bool={SessionState.locked},readCredential:@escaping (String)->String?={MCPKeychainCredentials.read($0)},writeCredential:@escaping (String,String)throws->Void={try MCPKeychainCredentials.write($0,$1)}) {
        self.store=store;self.settings=settings;self.runner=runner;self.locked=locked;self.readCredential=readCredential;self.writeCredential=writeCredential
        profiles=(try? MCPConnectionProfile.validate(settings.mcpConnections)) != nil ? settings.mcpConnections:[];selectedID=profiles.first?.id
    }
    var selectedProfile:MCPConnectionProfile? {profiles.first {$0.id==selectedID}}
    var tool:MCPReviewedTool? {catalog?.tools.first {$0.name==selectedTool}}
    private var usable:Bool {!store.isClosed && !locked() && allowed()}
    private func usable(_ profile:MCPConnectionProfile,tool:String?=nil)->Bool {
        usable && profiles.contains(profile) && settings.privacy.exclusion(app:"org.oswind.mcp",title:profile.name+(tool.map {" · "+$0} ?? ""),url:nil)==nil
    }
    private func work<T:Sendable>(_ body:@escaping @Sendable ()throws->T)async throws->T {
        let task=Task.detached(priority:.utility,operation:body)
        return try await withTaskCancellationHandler {try await task.value} onCancel:{task.cancel()}
    }
    func apply(_ value:AppSettings) {
        if settings.mcpConnections != value.mcpConnections || settings.privacy != value.privacy || settings.piiImports != value.piiImports {suspend()}
        settings=value;profiles=(try? MCPConnectionProfile.validate(value.mcpConnections)) != nil ? value.mcpConnections:[]
        if !profiles.contains(where:{$0.id==selectedID}) {selectedID=profiles.first?.id}
    }
    func select(_ id:String?) {
        guard id != selectedID,!busy else {return};suspend();selectedID=profiles.first(where:{$0.id==id})?.id
    }
    func chooseTool(_ name:String?) {
        guard !busy,tool?.name != name else {return};pendingReview=nil;result=nil;savedSourceID=nil
        selectedTool=catalog?.tools.first(where:{$0.name==name})?.name;argumentsText="{}"
    }
    func cancelReview() {pendingReview=nil}
    func requestDiscovery() {
        guard !busy,let profile=selectedProfile,usable(profile) else {error="Tools are unavailable while this library is locked, busy or excluded.";return}
        do {try profile.validate();pendingReview = .init(generation:generation,kind:.discovery,profile:profile,tool:nil,catalog:nil,arguments:nil);error=nil}catch {self.error=error.localizedDescription}
    }
    func requestCall() {
        guard !busy,let profile=selectedProfile,let catalog,let tool,usable(profile,tool:tool.name) else {error="Discover and select a tool before reviewing a call.";return}
        do {
            guard argumentsText.utf8.count<=65536 else {throw OSwindError.invalid("Tool arguments exceed64KiB")}
            let arguments=Data(argumentsText.utf8);try MCPClient.validateArgumentsJSON(arguments)
            pendingReview = .init(generation:generation,kind:.call,profile:profile,tool:tool,catalog:catalog,arguments:arguments);error=nil
        }catch {self.error=error.localizedDescription}
    }
    /// Only the currently displayed review token authorizes this operation.
    /// Configuration, scope, privacy and edits invalidate the token.
    func confirm(_ id:UUID) {
        guard !busy,let review=pendingReview,review.id==id,review.generation==generation,review.profile==selectedProfile,usable(review.profile,tool:review.tool?.name) else {pendingReview=nil;return}
        if review.kind == .call {guard review.catalog==catalog,review.tool?.name==selectedTool,review.arguments==Data(argumentsText.utf8) else {pendingReview=nil;return}}
        pendingReview=nil;result=nil;savedSourceID=nil;error=nil;busy=true;stopping=false
        let op=UUID(),scope=generation;operationID=op;status=review.kind == .discovery ? "Starting the reviewed server…":"Running the reviewed call…"
        worker=Task {[weak self] in
            guard let self else {return};defer {finish(op)}
            do {
                let store=self.store;try await work {try store.validateDirectoryIdentity()}
                guard current(scope,review.profile,tool:review.tool?.name) else {return}
                var credentials=[String:String]()
                for name in review.profile.command.credentialNames {
                    guard let value=readCredential(review.profile.credentialPrefix+name) else {throw OSwindError.unavailable("Save the "+name+" credential for this connection before starting it.")};credentials[name]=value
                }
                guard current(scope,review.profile,tool:review.tool?.name) else {return}
                if review.kind == .discovery {
                    let value=try await runner.discover(review.profile.command,credentials)
                    try await work {try store.validateDirectoryIdentity()}
                    guard current(scope,review.profile) else {return};catalog=value;selectedTool=nil;status=value.tools.isEmpty ? "This server exposes no tools. Review its configuration.":"\(value.tools.count) \(value.tools.count==1 ? "tool":"tools") discovered. Select one and review its exact arguments."
                }else {
                    guard let catalog=review.catalog,let tool=review.tool,let arguments=review.arguments else {throw OSwindError.invalid("The call review is incomplete")}
                    let value=try await runner.call(review.profile.command,credentials,catalog,tool.name,arguments)
                    try await work {try store.validateDirectoryIdentity()}
                    guard current(scope,review.profile,tool:tool.name) else {return}
                    result = .init(profile:review.profile,callID:UUID().uuidString.lowercased(),output:value)
                    status=value.isError ? "The server reported a tool error. Review its untrusted result below.":"Call finished. Review the result before saving any text."
                }
            }catch is CancellationError {if generation==scope {status="Call stopped. Check external state before any retry."}}
            catch {if generation==scope,usable {self.error=error.localizedDescription;status="The operation did not complete. No automatic retry was made."}}
        }
    }
    private func current(_ scope:UUID,_ profile:MCPConnectionProfile,tool:String?=nil)->Bool {scope==generation && !Task.isCancelled && usable(profile,tool:tool)}
    private func finish(_ id:UUID) {guard operationID==id else {return};let wasStopping=stopping;worker=nil;operationID=nil;busy=false;stopping=false;if wasStopping {status="Stopped. Review external state before any retry."}}
    func suspend() {
        generation=UUID();redactionEpoch=UUID();pendingReview=nil;catalog=nil;selectedTool=nil;argumentsText="{}";result=nil;savedSourceID=nil;credentialDrafts=[:];showingConfiguration=false;error=nil
        worker?.cancel();stopping=worker != nil;status=stopping ? "Stopping the owned server or import; external outcome may be unknown…":"Tools are stopped. Nothing starts automatically."
    }
    func cancelAndWait() async {suspend();let task=worker;await task?.value}
    private func prepareLocalEdit() async throws {
        guard !busy,usable else {throw OSwindError.unavailable("Finish current tool work before editing connections")}
        let scope=generation,store=self.store;try await work {try store.validateDirectoryIdentity()}
        guard scope==generation,!busy,usable else {throw CancellationError()}
    }
    func saveProfile(_ profile:MCPConnectionProfile) async throws {
        try await prepareLocalEdit()
        guard !busy,usable else {throw OSwindError.unavailable("Finish current tool work before editing connections")}
        try profile.validate();var next=profiles;next.removeAll {$0.id==profile.id};next.append(profile);try MCPConnectionProfile.validate(next)
        guard let saveProfiles else {throw OSwindError.unavailable("Connection settings are not attached to an open library")};try saveProfiles(next)
        var value=settings;value.mcpConnections=next;apply(value);selectedID=profile.id;status="Connection saved. Review its command before starting it."
    }
    func removeProfile(_ id:String) async throws {
        try await prepareLocalEdit()
        guard !busy,usable,let profile=profiles.first(where:{$0.id==id}),let saveProfiles else {throw OSwindError.unavailable("This connection is unavailable")}
        try profile.validate()
        // Keep the profile visible if credential removal fails, so it can be
        // retried. macOS Keychain and settings are not one transaction.
        for name in profile.command.credentialNames {try writeCredential(profile.credentialPrefix+name,"")}
        let next=profiles.filter {$0.id != id};try saveProfiles(next);var value=settings;value.mcpConnections=next;apply(value);status="Connection and its saved credential entries removed."
    }
    func saveCredential(_ name:String) async throws {
        try await prepareLocalEdit()
        guard !busy,let profile=selectedProfile,usable(profile),profile.command.credentialNames.contains(name),let value=credentialDrafts[name],!value.isEmpty,value.utf8.count<=16384,!value.utf8.contains(0) else {throw OSwindError.invalid("Enter a bounded credential for the selected connection")}
        try profile.validate();try writeCredential(profile.credentialPrefix+name,value);suspend();status="Credential saved in Keychain. Discover the tools again before making a call."
    }
    func removeCredential(_ name:String) async throws {
        try await prepareLocalEdit()
        guard !busy,let profile=selectedProfile,usable(profile),profile.command.credentialNames.contains(name) else {throw OSwindError.invalid("Select this connection's credential")}
        try writeCredential(profile.credentialPrefix+name,"");suspend();status="Credential removed."
    }
    func saveResultText() {
        guard !busy,savedSourceID==nil,let result,usable(result.profile,tool:result.output.tool),let saveSource else {return}
        do {
            let draft=try MCPResultSourceDraft(profile:result.profile,callID:result.callID,output:result.output),scope=generation,op=UUID();operationID=op;busy=true;error=nil;status="Checking privacy and saving selected result text…"
            worker=Task {[weak self] in
                guard let self else {return};defer {finish(op)}
                do {let saved=try await saveSource(draft);guard current(scope,result.profile,tool:result.output.tool) else {return};savedSourceID=saved.imported>0 ? draft.sourceID:nil;status=saved.imported>0 ? "Result text saved with provenance. It is available in Memories and Ask.":"Current privacy rules excluded this result; nothing was saved."}
                catch is CancellationError {if generation==scope {status="Save stopped. Review memory before retrying."}}
                catch {if generation==scope,usable {self.error=error.localizedDescription;status="The result was not confirmed saved."}}
            }
        }catch {self.error=error.localizedDescription}
    }
}
