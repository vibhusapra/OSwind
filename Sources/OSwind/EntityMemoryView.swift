import SwiftUI
import OSwindCore

struct EntityMemoryView:View {
    @EnvironmentObject var m:AppModel
    @ObservedObject var model:EntityMemoryModel
    @State private var creating=false
    @State private var edit:MemoryEntity?
    @State private var mergeTarget=""
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:6) {
                    Label("CONNECTED MEMORY",systemImage:"point.3.connected.trianglepath.dotted").font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundStyle(OSwindTheme.accent)
                    Text("People & projects").font(.system(size:30,weight:.medium,design:.rounded))
                    Text("Follow a name back to the moments behind it.").foregroundStyle(.secondary)
                };Spacer();Button("New",systemImage:"plus") {creating=true}.buttonStyle(.borderedProminent)
            }
            HStack {
                TextField("Find a name or alias",text:$model.query).textFieldStyle(.roundedBorder).onSubmit {model.reload()}
                Picker("Kind",selection:$model.kind) {Text("All kinds").tag(EntityKind?.none);ForEach(EntityKind.allCases,id:\.self) {Text($0.rawValue.capitalized).tag(Optional($0))}}.frame(width:160).onChange(of:model.kind) {_,_ in model.reload()}
                Button("Find") {model.reload()}
            }
            HStack(spacing:12) {
                if model.indexing {ProgressView().controlSize(.small);Text("Indexing locally…");Button("Stop") {model.cancel()}}
                else {Button("Build / resume",systemImage:"sparkle.magnifyingglass") {model.build()}}
                Text("\(model.progress.indexed) / \(model.progress.eligible) sources").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Toggle("Keep up with capture",isOn:$m.settings.entityAutomaticIndex).toggleStyle(.checkbox).onChange(of:m.settings.entityAutomaticIndex) {_,enabled in if enabled {model.build()}else {model.cancel()}}
            }.font(.caption)
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            if model.progress.limited>0 {Text("\(model.progress.limited) sources reached the 256-entity limit; their suggestions are incomplete.").font(.caption).foregroundStyle(.orange)}
            if let error=model.error {Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)}
            HSplitView {
                ScrollView {
                    LazyVStack(spacing:7) {
                        if model.entities.isEmpty {ContentUnavailableView("Start with a project",systemImage:"folder",description:Text("Create a project and add its aliases, or build suggestions from saved text. Nothing leaves this Mac."))}
                        ForEach(model.entities) {entity in
                            Button {model.selectedID=entity.id} label:{
                                HStack(alignment:.top,spacing:12) {
                                    Image(systemName:entity.kind == .project ? "folder":entity.kind == .person ? "person":"building.2").foregroundStyle(OSwindTheme.accent).frame(width:22)
                                    VStack(alignment:.leading,spacing:4) {Text(entity.name).font(.headline);Text("\(entity.kind.rawValue.capitalized) · \(entity.curated ? "Curated":"On-device suggestion")").font(.caption).foregroundStyle(.secondary)}
                                    Spacer();Text("\(entity.sourceCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }.padding(14).background(model.selectedID==entity.id ? OSwindTheme.accent.opacity(0.12):Color.primary.opacity(0.03),in:RoundedRectangle(cornerRadius:10))
                            }.buttonStyle(.plain)
                        }
                        Text("Showing up to 100 groups. Refine by name or kind.").font(.caption2).foregroundStyle(.secondary).padding(8)
                    }.padding(.trailing,10)
                }.frame(minWidth:250,idealWidth:330)
                ScrollView {
                    if let entity=model.selected {
                        VStack(alignment:.leading,spacing:16) {
                            HStack {Text(entity.name).font(.title2.weight(.medium));Spacer();Button("Edit") {edit=entity}}
                            Text(entity.curated ? "Curated label · \(entity.sourceCount) recorded sources":"Suggested by Apple’s on-device name tagging · review before relying on this grouping").font(.caption).foregroundStyle(.secondary)
                            if !entity.detail.isEmpty {Text(entity.detail).textSelection(.enabled)}
                            Text(entity.aliases.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            HStack {Button("Search sources") {m.browseEntity(entity,ask:false)};Button("Ask about sources",systemImage:"sparkles") {m.browseEntity(entity,ask:true)}}.buttonStyle(.bordered)
                            Divider()
                            ForEach(model.sources) {source in
                                VStack(alignment:.leading,spacing:7) {
                                    Button {m.openEntitySource(source)} label:{Text(source.title.isEmpty ? source.app:source.title).font(.headline).frame(maxWidth:.infinity,alignment:.leading)}.buttonStyle(.plain)
                                    Text("\(source.app) · \(source.timestamp.formatted(date:.abbreviated,time:.shortened)) · \(source.origin == "manual" ? "Linked by you":"Text mention")").font(.caption2).foregroundStyle(.secondary)
                                    if !source.surface.isEmpty {Text("“\(source.surface)”").font(.callout).textSelection(.enabled)}
                                    Button("Remove link") {model.mutate {try $0.unlinkEntity(entity.id,from:source.id)}}.font(.caption).disabled(model.editing)
                                }.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary.opacity(0.4),in:RoundedRectangle(cornerRadius:10))
                            }
                            if model.sources.isEmpty {Text("No recorded sources yet. Open a memory and choose Link to entity, or add project aliases and rebuild.").foregroundStyle(.secondary)}
                            Text("Showing up to 100 source links. Search sources to browse further. Automatic grouping uses recorded text, not face or voice recognition. A shared name may refer to different people.").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Merge into another group") {
                                Picker("Destination",selection:$mergeTarget) {Text("Choose…").tag("");ForEach(model.entities.filter {$0.kind==entity.kind && $0.id != entity.id}) {Text($0.name).tag($0.id)}}
                                Text("Moves aliases, notes and source links into the selected group. This is your identity decision.").font(.caption).foregroundStyle(.secondary)
                                Button("Merge groups") {let destination=mergeTarget;model.mutate {try $0.mergeEntity(entity.id,into:destination)};mergeTarget=""}.disabled(mergeTarget.isEmpty || model.editing)
                            }
                            Text(entity.id).font(.system(size:10,design:.monospaced)).foregroundStyle(.tertiary).textSelection(.enabled)
                        }.padding(.leading,16)
                    }else {ContentUnavailableView("Every connection has a source",systemImage:"text.quote",description:Text("Choose a group to inspect its recorded mentions, correct a label or ask a scoped question."))}
                }.frame(minWidth:330)
            }
        }.padding(28).onAppear {model.visible=true;model.reload()}.onDisappear {model.visible=false}
        .sheet(isPresented:$creating) {EntityEditor(model:model,entity:nil)}
        .sheet(item:$edit) {EntityEditor(model:model,entity:$0)}
    }
}
private struct EntityEditor:View {
    @ObservedObject var model:EntityMemoryModel
    var entity:MemoryEntity?
    @Environment(\.dismiss) private var dismiss
    @State private var name=""
    @State private var notes=""
    @State private var aliases=""
    @State private var kind:EntityKind = .project
    @State private var submitted=false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text(entity==nil ? "Create a connection":"Edit connection").font(.title2)
            if entity==nil {Picker("Kind",selection:$kind) {ForEach(EntityKind.allCases,id:\.self) {Text($0.rawValue.capitalized).tag($0)}}}
            TextField("Name",text:$name).textFieldStyle(.roundedBorder)
            Text("Aliases, one per line").font(.caption);TextEditor(text:$aliases).frame(height:90)
            Text("Your notes").font(.caption);TextEditor(text:$notes).frame(height:110)
            Text("Project aliases match recorded text after Build / resume. Notes are yours; OSwind does not generate a biography. Saved labels and notes remain if their sources are deleted. Delete the group or wipe the library to erase them.").font(.caption).foregroundStyle(.secondary)
            if let error=model.error {Text(error).foregroundStyle(.orange).font(.caption)}
            HStack {Button("Cancel") {dismiss()};Spacer();if let entity {Button("Delete group",role:.destructive) {submitted=true;model.mutate {try $0.deleteEntity(entity.id)}}};Button("Save") {
                let name=self.name,notes=self.notes,kind=self.kind,aliases=self.aliases.components(separatedBy:.newlines).filter {!$0.trimmingCharacters(in:.whitespaces).isEmpty};submitted=true
                model.mutate {store in if let entity {try store.editEntity(entity.id,name:name,detail:notes,aliases:aliases)}else {_=try store.createEntity(kind:kind,name:name,detail:notes,aliases:aliases)}}
            }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in:.whitespaces).isEmpty)}.disabled(model.editing)
        }.padding(24).frame(width:500).onAppear {if let entity {name=entity.name;notes=entity.detail;kind=entity.kind;aliases=entity.aliases.joined(separator:"\n")}}
        .onChange(of:model.editing) {_,busy in if submitted && !busy && model.error==nil {dismiss()}}
    }
}

struct EntityLinkSheet:View {
    @EnvironmentObject var m:AppModel
    @Environment(\.dismiss) private var dismiss
    let sourceID:String
    @State private var rows=[MemoryEntity]()
    @State private var target=""
    @State private var error:String?
    @State private var busy=false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Link this source").font(.title2)
            Text("Choose a saved group. This adds a deliberate source link; it does not verify someone’s identity.").foregroundStyle(.secondary)
            Picker("Connection",selection:$target) {Text("Choose…").tag("");ForEach(rows) {Text("\($0.name) · \($0.kind.rawValue)").tag($0.id)}}
            if rows.isEmpty {Text("Create a group in People & projects first.").font(.caption)}
            if let error {Text(error).foregroundStyle(.orange).font(.caption)}
            HStack {Button("Cancel") {dismiss()};Spacer();if busy {ProgressView().controlSize(.small)};Button("Link source") {link()}.buttonStyle(.borderedProminent).disabled(target.isEmpty || busy)}
        }.padding(24).frame(width:480).task {
            let store=m.store,worker=Task.detached(priority:.utility) {try store.entities(limit:500)}
            do {let value=try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()};guard !Task.isCancelled else {return};rows=value}catch {self.error=error.localizedDescription}
        }
    }
    private func link() {
        busy=true;let store=m.store,id=target,sourceID=self.sourceID
        Task {let worker=Task.detached(priority:.utility) {try store.linkEntity(id,to:sourceID)}
            do {try await worker.value;m.entityMemory.reload();dismiss()}catch {self.error=error.localizedDescription};busy=false
        }
    }
}
