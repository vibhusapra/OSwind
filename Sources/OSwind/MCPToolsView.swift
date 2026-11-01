import SwiftUI
import AppKit
import OSwindCore

private func toolDisplay(_ text:String)->String {
    text.unicodeScalars.map {s in (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value) ? String(format:"\\u%04x",s.value):String(s)}.joined()
}
struct MCPToolsView:View {
    @ObservedObject var model:MCPToolsModel
    @EnvironmentObject var m:AppModel
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:7) {Text("The tools you choose.").font(.system(size:32,weight:.medium,design:.rounded));Text("Review a call. Bring back context. Keep what matters.").foregroundStyle(.secondary)}
                Spacer();Button("Manage connections") {model.showingConfiguration=true}.disabled(model.busy)
            }
            HStack {
                Label(model.status,systemImage:model.stopping ? "stop.circle":"puzzlepiece.extension").font(.callout)
                Spacer();if model.busy {ProgressView().controlSize(.small);Button("Stop") {model.suspend()}.disabled(model.stopping)}
            }.padding(14).background(OSwindTheme.accent.opacity(0.07),in:RoundedRectangle(cornerRadius:12))
            if let error=model.error {Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)}
            if model.profiles.isEmpty {
                ContentUnavailableView {Label("Connect your own tools",systemImage:"puzzlepiece.extension")} description: {Text("Add a local MCP server. OSwind starts it only after you review its command. No tool runs automatically.")} actions: {Button("Add a connection") {model.showingConfiguration=true}}
                .frame(maxWidth:.infinity,maxHeight:.infinity)
            }else {
                ScrollViewReader {scroll in
                ScrollView {
                    VStack(alignment:.leading,spacing:18) {
                        ViewThatFits(in:.horizontal) {
                            HStack {connectionPicker;Button("Review server & discover") {model.requestDiscovery()}.disabled(model.busy)}
                            VStack(alignment:.leading) {connectionPicker;Button("Review server & discover") {model.requestDiscovery()}.disabled(model.busy)}
                        }
                        if let profile=model.selectedProfile,!profile.command.credentialNames.isEmpty {credentials(profile)}
                        if let catalog=model.catalog {
                            VStack(alignment:.leading,spacing:12) {
                                HStack {Text("Choose a tool").font(.headline);Spacer();Text(catalog.protocolVersion+" · stdio").font(.caption).foregroundStyle(.secondary)}
                                Picker("Tool",selection:Binding(get:{model.selectedTool},set:{model.chooseTool($0)})) {
                                    Text("Select a tool…").tag(Optional<String>.none)
                                    ForEach(catalog.tools) {tool in Text(tool.name).tag(Optional(tool.name))}
                                }.disabled(model.busy)
                                if let tool=model.tool {
                                    if !tool.description.isEmpty {Text(toolDisplay(tool.description)).font(.callout).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)}
                                    DisclosureGroup("Tool definition · untrusted server metadata") {toolCode(tool.definitionJSON,height:170)}
                                    Text("Arguments · JSON object").font(.subheadline.weight(.semibold))
                                    TextEditor(text:$model.argumentsText).font(.system(.body,design:.monospaced)).frame(minHeight:100,maxHeight:180).padding(8).background(.background,in:RoundedRectangle(cornerRadius:9)).overlay(RoundedRectangle(cornerRadius:9).strokeBorder(.primary.opacity(0.12))).accessibilityLabel("Tool arguments JSON").disabled(model.busy)
                                    HStack {Text("A tool may read files, contact services or change external data.").font(.caption).foregroundStyle(.secondary);Spacer();Button("Review call") {model.requestCall()}.buttonStyle(.borderedProminent).disabled(model.busy)}
                                }
                            }.padding(18).background(.background,in:RoundedRectangle(cornerRadius:12))
                        }
                        if let result=model.result {
                            VStack(alignment:.leading,spacing:12) {
                                HStack {Label(result.output.isError ? "Tool reported an error":"Result",systemImage:result.output.isError ? "exclamationmark.circle":"text.alignleft").font(.headline);Spacer();Text(result.output.tool).font(.system(.caption,design:.monospaced))}
                                Text("External, unverified content · "+result.output.completedAt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if result.output.text.isEmpty {Text("This result has no plain text. Binary content and resource links are not fetched or saved.").foregroundStyle(.secondary)}else {toolCode(result.output.text,height:180,wrap:true)}
                                DisclosureGroup("Raw result JSON") {toolCode(String(decoding:result.output.resultJSON,as:UTF8.self),height:160)}
                                Text("Saving keeps only this text and provenance under current privacy settings. Arguments and credentials are omitted. Imported text can be found in Memories and used by Ask.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Save text to memory") {model.saveResultText()}.disabled(model.busy || result.output.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || model.savedSourceID != nil)
                                    if let id=model.savedSourceID {Button("Open saved source") {m.openMCPSource(id)}}
                                }
                            }.padding(18).background(.background,in:RoundedRectangle(cornerRadius:12)).id("tool-result")
                        }
                    }.padding(.vertical,2)
                }
                .onChange(of:model.result?.callID) {_,id in if id != nil {withAnimation {scroll.scrollTo("tool-result",anchor:.top)}}}
                .onAppear {if model.result != nil {Task {@MainActor in await Task.yield();scroll.scrollTo("tool-result",anchor:.top)}}}
                }
            }
            Text("Local stdio servers only. Server code runs with your Mac account's authority. Descriptions and read-only annotations are claims; every call needs your review. Stop never retries an unknown external action.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(26).tint(OSwindTheme.accent)
        .sheet(isPresented:$model.showingConfiguration) {MCPConnectionsView(model:model)}
        .sheet(item:Binding(get:{model.pendingReview},set:{if $0==nil {model.cancelReview()}})) {review in MCPActionReviewView(review:review,cancel:{model.cancelReview()},confirm:{model.confirm(review.id)})}
    }
    private var connectionPicker:some View {
        Picker("Connection",selection:Binding(get:{model.selectedID},set:{model.select($0)})) {ForEach(model.profiles) {profile in Text(toolDisplay(profile.name)).tag(Optional(profile.id))}}.disabled(model.busy)
    }
    private func credentials(_ profile:MCPConnectionProfile)->some View {
        DisclosureGroup("Connection credentials · Keychain") {
            VStack(alignment:.leading,spacing:9) {
                ForEach(profile.command.credentialNames,id:\.self) {name in
                    HStack {SecureField(name,text:Binding(get:{model.credentialDrafts[name] ?? ""},set:{model.credentialDrafts[name]=$0}));Button("Save") {Task {do {try await model.saveCredential(name)}catch {m.errorMessage=error.localizedDescription}}}.disabled(model.credentialDrafts[name]?.isEmpty != false);Button("Remove") {Task {do {try await model.removeCredential(name)}catch {m.errorMessage=error.localizedDescription}}}}
                }
                Text("Only these named values are loaded after you confirm a server launch or call. No other process environment or model-provider key is inherited. Saving or removing a value clears the current tool review.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy).padding(.top,8)
        }
    }
}
private func toolCode(_ text:String,height:CGFloat,wrap:Bool=false)->some View {
    GeometryReader {geometry in
        ScrollView(wrap ? [.vertical]:[.horizontal,.vertical]) {
            Text(toolDisplay(text)).font(.system(size:12,design:.monospaced)).textSelection(.enabled)
                .fixedSize(horizontal:!wrap,vertical:true)
                .frame(minWidth:max(0,geometry.size.width-20),maxWidth:wrap ? max(0,geometry.size.width-20):nil,minHeight:max(0,geometry.size.height-20),alignment:.topLeading).padding(10)
        }
    }.frame(height:height).background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8))
}
struct MCPActionReviewView:View {
    let review:MCPActionReview
    var cancel:()->Void,confirm:()->Void
    private var commandJSON:String {let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];return (try? String(decoding:e.encode(review.profile.command),as:UTF8.self)) ?? "Unavailable"}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack {Image(systemName:"puzzlepiece.extension").foregroundStyle(OSwindTheme.accent);Text(review.title).font(.title2.weight(.medium));Spacer()}
            Text(toolDisplay(review.profile.name)).font(.headline)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    Text("Command and explicitly named credentials").font(.subheadline.weight(.semibold));toolCode(commandJSON,height:160)
                    Text("Starting this server runs local code with your account's filesystem and network authority. Discovery itself starts that code. The working directory and filtered environment are not a sandbox.").font(.callout).foregroundStyle(.secondary)
                    if let tool=review.tool,let args=review.arguments {
                        Divider();Text("Tool: "+tool.name).font(.headline)
                        Text("Exact arguments").font(.subheadline.weight(.semibold));toolCode(String(decoding:args,as:UTF8.self),height:130)
                        DisclosureGroup("Complete tool definition · server claim") {toolCode(tool.definitionJSON,height:180)}
                        Text("Definition SHA-256: "+tool.fingerprint).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                        Text("This may change external data. Review the tool and arguments yourself; read-only annotations do not grant permission. OSwind forwards these arguments and the named credentials; it does not attach your memory library. The server can still access files with your account authority. A timeout or Stop can leave an unknown outcome.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Invisible directional formatting characters are escaped in this preview. The reviewed JSON values remain unchanged.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider();HStack {Button("Cancel",action:cancel).keyboardShortcut(.cancelAction);Spacer();Button(review.kind == .discovery ? "Start server & discover":"Run exact call",action:confirm).buttonStyle(.borderedProminent)}
        }.padding(24).frame(width:680,height:720).tint(OSwindTheme.accent)
    }
}
struct MCPConnectionsView:View {
    @ObservedObject var model:MCPToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingID:String?
    @State private var name=""
    @State private var executable=""
    @State private var arguments="[]"
    @State private var credentialNames=""
    @State private var error:String?
    @State private var removeID:String?
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("Your external tools.").font(.title2.weight(.medium));Spacer();Button("Done") {dismiss()}.keyboardShortcut(.cancelAction)}
            Text("Up to eight local stdio connections. Saving a connection does not start it or approve any tool call.").font(.callout).foregroundStyle(.secondary)
            if !model.profiles.isEmpty {
                Picker("Edit connection",selection:Binding(get:{editingID},set:{load($0)})) {Text("New connection").tag(Optional<String>.none);ForEach(model.profiles) {p in Text(toolDisplay(p.name)).tag(Optional(p.id))}}
            }
            Form {
                TextField("Connection name",text:$name)
                HStack {TextField("Absolute executable path",text:$executable);Button("Choose…") {let panel=NSOpenPanel();panel.canChooseFiles=true;panel.canChooseDirectories=false;panel.allowsMultipleSelection=false;if panel.runModal() == .OK,let url=panel.url {executable=url.path}}}
                Text("Argument array · JSON strings").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$arguments).font(.system(.body,design:.monospaced)).frame(height:105).accessibilityLabel("Server argument array JSON")
                Text("Example: [\"/absolute/path/server.js\"]. No shell expansion occurs. Put secrets in the credential fields after saving, not in arguments.").font(.caption).foregroundStyle(.secondary)
                Text("Credential variable names · one per line").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$credentialNames).font(.system(.body,design:.monospaced)).frame(height:65).accessibilityLabel("Credential variable names")
                Text("Examples: GITHUB_TOKEN or API_TOKEN. Values stay in Keychain and are supplied only to this connection after explicit review.").font(.caption).foregroundStyle(.secondary)
            }.disabled(model.busy)
            if let error {Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)}
            HStack {
                if let id=editingID {Button("Remove connection & credentials",role:.destructive) {removeID=id}.disabled(model.busy)}
                Spacer();Button("Save connection") {save()}.buttonStyle(.borderedProminent).disabled(model.busy || (editingID==nil && model.profiles.count>=8))
            }
        }.padding(24).frame(width:700,height:680).tint(OSwindTheme.accent)
        .onChange(of:model.redactionEpoch) {_,_ in editingID=nil;name="";executable="";arguments="[]";credentialNames="";error=nil}
        .confirmationDialog("Remove this connection and its saved credential entries?",isPresented:Binding(get:{removeID != nil},set:{if !$0 {removeID=nil}})) {
            Button("Remove connection & credentials",role:.destructive) {if let id=removeID {Task {do {try await model.removeProfile(id);removeID=nil;load(nil)}catch {self.error=error.localizedDescription}}}}
            Button("Cancel",role:.cancel) {removeID=nil}
        }
    }
    private func load(_ id:String?) {
        editingID=id;error=nil
        guard let profile=model.profiles.first(where:{$0.id==id}) else {name="";executable="";arguments="[]";credentialNames="";return}
        name=profile.name;executable=profile.command.executable;let e=JSONEncoder();e.outputFormatting=[.prettyPrinted];arguments=(try? String(decoding:e.encode(profile.command.arguments),as:UTF8.self)) ?? "[]";credentialNames=profile.command.credentialNames.joined(separator:"\n")
    }
    private func save() {
        do {
            guard arguments.utf8.count<=65536 else {throw OSwindError.invalid("Argument JSON exceeds64KiB")}
            let values=try JSONDecoder().decode([String].self,from:Data(arguments.utf8)),names=credentialNames.split(whereSeparator:\.isNewline).map {String($0).trimmingCharacters(in:.whitespaces)}
            let profile=MCPConnectionProfile(id:editingID ?? UUID().uuidString.lowercased(),name:name.trimmingCharacters(in:.whitespacesAndNewlines),command:.init(executable:executable,arguments:values,credentialNames:names))
            try profile.validate();Task {do {try await model.saveProfile(profile);dismiss()}catch {self.error=error.localizedDescription}}
        }catch {self.error=error.localizedDescription}
    }
}
