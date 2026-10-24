import SwiftUI
import OSwindCore

@MainActor final class HistoryErasureModel:ObservableObject {
    @Published private(set) var preview:HistoryErasurePreview?
    @Published private(set) var result:HistoryErasureResult?
    @Published private(set) var busy=false
    @Published private(set) var phase=""
    @Published private(set) var error:String?
    private var task:Task<Void,Never>?
    private var cancelWorker:(()->Void)?
    func invalidate() {guard !busy else {return};preview=nil;result=nil;error=nil;phase=""}
    func cancel() {cancelWorker?()}
    func inspect(store:MemoryStore,scope:HistoryErasureScope) {
        guard !busy else {return};preview=nil;result=nil
        run(phase:"Checking source records and dependent answers…",operation:{try store.previewErasure(scope)}) {self.preview=$0;self.phase="Preview ready. Capture stays paused."}
    }
    func apply(store:MemoryStore,completion:@escaping ()->Void) {
        guard !busy,let preview else {return}
        self.preview=nil
        run(phase:"Erasing sources, then cleaning retained media…",operation:{try store.eraseHistory(preview.scope,expectedToken:preview.token)}) {self.result=$0;self.phase="Erasure committed. Capture stays paused.";completion()}
    }
    func retry(store:MemoryStore) {
        guard !busy else {return};preview=nil;result=nil
        run(phase:"Retrying retained-media cleanup…",operation:{store.retryErasureCleanup()}) {self.result=$0;self.phase="Media cleanup checked."}
    }
    private func run<T:Sendable>(phase:String,operation:@escaping @Sendable () throws -> T,completion:@escaping (T)->Void) {
        busy=true;error=nil;self.phase=phase
        let worker=Task.detached(priority:.utility) {try operation()};cancelWorker={worker.cancel()}
        task=Task {
            defer {busy=false;cancelWorker=nil;task=nil}
            do {completion(try await worker.value)}
            catch is CancellationError {self.phase="Cancelled before erasure committed. Preview again to continue."}
            catch {self.error=error.localizedDescription;self.phase="Nothing was erased by this attempt. Preview again to continue."}
        }
    }
}
struct HistoryErasureView:View {
    @EnvironmentObject var m:AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model=HistoryErasureModel()
    @State private var timeBound=true
    @State private var start=Date().addingTimeInterval(-3600)
    @State private var end=Date()
    @State private var app=""
    @State private var bundle=""
    @State private var domain=""
    @State private var subdomains=true
    @State private var kind="all"
    @State private var confirm=false
    private var scope:HistoryErasureScope {.init(start:timeBound ? start:nil,end:timeBound ? end:nil,app:app.isEmpty ? nil:app,bundleID:bundle.isEmpty ? nil:bundle,domain:domain.isEmpty ? nil:domain,includeSubdomains:subdomains,kind:MemoryKind(rawValue:kind))}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("Erase part of your history.").font(.title2.weight(.medium));Spacer();Button("Done") {dismiss()}.disabled(model.busy).keyboardShortcut(.cancelAction)}
            Text("Choose a time, app or website. Review the matching sources before deleting them.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    GroupBox {
                        VStack(alignment:.leading,spacing:12) {
                            Toggle("Limit to a time range",isOn:$timeBound)
                            if timeBound {DatePicker("From",selection:$start);DatePicker("To, exclusive",selection:$end)}
                            TextField("Exact app name · optional",text:$app).accessibilityLabel("Exact app name")
                            TextField("Bundle ID · optional",text:$bundle).accessibilityLabel("Application bundle ID")
                            TextField("Website hostname · optional",text:$domain).accessibilityLabel("Website hostname")
                            if !domain.isEmpty {Toggle("Include subdomains",isOn:$subdomains)}
                            Picker("Source type",selection:$kind) {Text("All types").tag("all");ForEach(MemoryKind.allCases,id:\.rawValue) {Text($0.rawValue.capitalized).tag($0.rawValue)}}
                        }.padding(8).textFieldStyle(.roundedBorder)
                    }.disabled(model.busy)
                    Text("All selected filters intersect. Time matches overlapping recordings; entire clips are removed, including parts outside the range. Website filters match recorded HTTP(S) URLs. Saved notes and favorites are included when they match.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Pause & preview") {m.pauseAll(discardReplay:true);model.inspect(store:m.store,scope:scope)}.disabled(model.busy || m.libraryTransfer.busy)
                        if model.busy {ProgressView().controlSize(.small);Button("Cancel") {model.cancel()}}
                        Spacer()
                        Button("Retry media cleanup") {model.retry(store:m.store)}.disabled(model.busy || m.libraryTransfer.busy)
                    }
                    if !model.phase.isEmpty {Text(model.phase).font(.callout).accessibilityIdentifier("history-erasure-status")}
                    if let error=model.error {Text(error).foregroundStyle(.red).textSelection(.enabled)}
                    if let preview=model.preview {
                        GroupBox {
                            VStack(alignment:.leading,spacing:10) {
                                if preview.linkedRecaps>0 {Text("\(preview.matchedSources) matching sources + \(preview.linkedRecaps) linked recaps outside these filters").font(.callout).foregroundStyle(.secondary)}
                                Text("\(preview.sources) sources · \(preview.conversationTurns) dependent answers · \(preview.mediaReferences) media references").font(.headline)
                                ForEach(preview.samples,id:\.id) {sample in VStack(alignment:.leading,spacing:2) {Text(sample.title).lineLimit(2);Text("\(sample.app) · \(sample.timestamp.formatted())").font(.caption).foregroundStyle(.secondary)}}
                                if preview.sources>preview.samples.count {Text("Showing the latest \(preview.samples.count) of \(preview.sources) sources.").font(.caption).foregroundStyle(.secondary)}
                                Button("Erase \(preview.sources) sources…",role:.destructive) {confirm=true}.disabled(preview.sources==0 || model.busy || m.libraryTransfer.busy)
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                        }
                    }
                    if let result=model.result {
                        VStack(alignment:.leading,spacing:8) {
                            Text("Removed \(result.sources) sources and \(result.conversationTurns) dependent answers.").font(.headline)
                            Text("\(result.removedMedia) media files removed · \(result.sharedMedia) still used by other sources · \(result.pendingMedia) pending cleanup").font(.callout)
                            ForEach(result.warnings,id:\.self) {Text($0).foregroundStyle(.orange)}
                        }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.quaternary,in:RoundedRectangle(cornerRadius:10))
                    }
                    Text("This cannot be undone. Exports, backups and other copies remain. Earlier independent recap copies remain unless they match these filters. Source-linked recaps follow their originals. This removes live history and invalidates search caches; it does not securely overwrite SSD blocks. Capture stays paused until you resume it.").font(.caption).foregroundStyle(.secondary)
                }.padding(2)
            }
        }.padding(24).frame(width:720,height:760)
        .onChange(of:scope) {_,_ in model.invalidate()}
        .interactiveDismissDisabled(model.busy)
        .alert("Erase the previewed history?",isPresented:$confirm) {
            Button("Cancel",role:.cancel) {}
            Button("Erase sources",role:.destructive) {
                m.pauseAll(discardReplay:true);m.cancelAnswer();m.routines.cancel();m.cancelOpeningMemory();m.selected=nil;m.answer=nil
                model.apply(store:m.store) {m.refreshChats();m.routines.reload();m.invalidateStorageEstimate();m.refresh(forceStatistics:true)}
            }
        } message: {Text("Matching sources, retained media and entire answers that cite them will be removed. Shared media stays when another source still uses it. If history changed, you will need a new preview.")}
    }
}
