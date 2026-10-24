import SwiftUI
import Combine
import OSwindCore
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    let store: MemoryStore
    let embedder = LocalEmbedder()
    let capture: CaptureController
    let audio: AudioController
    let activity:ActivityCalendarModel
    @Published var calendarSlice:DateInterval?
    @Published var calendarSliceZone:String?
    let libraryTransfer = LibraryTransferModel()
    let libraryWipe=LibraryWipeModel()
    private var noteTasks=[UUID:Task<Void,Never>]()
    let routines:RoutinesModel
    let nativeModels:NativeModelSetupModel
    let visualModelSetup:VisualModelSetupModel
    @Published var settingsTab = "Capture"
    @Published var settings: AppSettings { didSet {
        capture.settings = settings; audio.settings = settings;routines.apply(settings)
        if oldValue.search.visual != settings.search.visual || oldValue.privacy != settings.privacy || oldValue.search.indexOnLowPower != settings.search.indexOnLowPower {cancelVisualIndexing();if mode == .visual {cancelOpeningMemory();hits=[];selected=nil;selectedVisual=nil;refresh()}}
        // Visual model controls do not invalidate the independent text index.
        var oldTextSearch=oldValue.search;oldTextSearch.visual=settings.search.visual
        if oldTextSearch != settings.search { indexGeneration = UUID(); indexTask?.cancel(); store.cancelSearchIndexBuild(); if settings.search.indexPolicy == .exact { store.releaseSearchIndex() }; automaticIndexTask?.cancel(); pendingIndex.removeAll(); indexing = false; indexStatus = "Search settings changed; prepare the selected index" }
        do { try settings.save(root:store.root) } catch { errorMessage = error.localizedDescription }
    } }
    @Published var section = "Memories"
    @Published var searchFocusRequest: UUID?
    @Published var query = ""
    @Published var mode: SearchMode = .hybrid
    @Published var visualIndexing=false
    @Published var visualAutomaticIndexing=false
    var visualAutoResumeAllowed=true
    @Published var visualIndexProgress=0.0
    @Published var visualIndexStatus="Enable a local visual model to index retained screenshots and replay frames."
    var visualGeneration=UUID()
    var visualIndexTask:Task<Void,Never>?
    var visualAutomaticTask:Task<Void,Never>?
    var pendingVisualIDs=[String]()
    @Published var appFilter = "All apps"
    @Published var range = "All time"
    @Published var date = Date()
    @Published var hits = [SearchHit]()
    @Published var stats = StoreStats()
    @Published var storageUpdatedAt: Date?
    @Published var selected: Memory? {didSet {if selected==nil {selectedVisual=nil}}}
    @Published private(set) var openingMemoryID:String?
    private var detailTask:Task<Void,Never>?
    private var detailGeneration=UUID()
    @Published var selectedEvidenceQuery = ""
    @Published var answer: Answer?
    @Published var question = ""
    @Published var asking = false
    @Published var chats = [ChatSession]()
    @Published var chatTurns = [ChatTurn]()
    @Published var currentChatID: String?
    private var answerTask: Task<Void,Never>?
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showOnboarding = false
    @Published var pauseUntil: Date?
    private var pauseTimer: Timer?
    @Published var apiStatus = "API off"
    @Published var searchMS = 0.0
    @Published var searchStrategy = ""
    @Published var refreshing = false
    @Published private(set) var deletingID:String?
    @Published var deletionStatus:String?
    @Published private(set) var savingRecap=false
    @Published var recapSaveStatus:String?
    @Published private(set) var importingJSON=false
    @Published private(set) var importStatus=""
    private var jsonImportTask:Task<Void,Never>?
    private var recapSaveTask:Task<Void,Never>?
    private var libraryOperationGeneration=UUID()
    @Published private(set) var maintenanceBusy=false
    @Published private(set) var maintenanceStatus=""
    @Published var searchWarnings = [String]()
    @Published var interpretQuery = true
    @Published var resolvedSearch: QueryResolution?
    @Published var searchInputError: String?
    @Published var answerInputError: String?
    @Published var installedModels = [InstalledModel]()
    @Published var localRuntime = ""
    @Published var startingModelServer = false
    @Published var modelStatus = "Check the local server to discover installed models"
    @Published var pullProgress: ModelPullProgress?
    @Published var pullingModel: String?
    @Published var indexing = false
    @Published var indexStatus = "Apple vectors are indexed during capture"
    @Published var indexProgress = 0.0
    private var indexGeneration = UUID()
    private var indexTask: Task<Void,Never>?
    private var pullTask: Task<Void,Never>?
    private var automaticIndexTask: Task<Void,Never>?
    private var pendingIndex = [Memory]()
    private var pendingRefresh = false
    let demo: Bool
    private var api: LocalAPIServer?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTask: Task<Void,Never>?
    private var statisticsTask: Task<Void,Never>?
    private var diskUsageTask: Task<Void,Never>?
    private var statisticsUpdatedAt = Date.distantPast
    private var statisticsPending = false
    private var storageGeneration = UUID()
    @Published var importingAudio=false
    @Published var audioImportStatus=""
    private var audioImportTask: Task<Void,Never>?
    private var housekeeping: Timer?
    init(root selectedRoot: URL? = nil, startServices: Bool = true, nativeModelSetup:NativeModelSetupModel?=nil,visualSetup:VisualModelSetupModel?=nil) throws {
        nativeModels=nativeModelSetup ?? NativeModelSetupModel()
        visualModelSetup=visualSetup ?? VisualModelSetupModel()
        demo = CommandLine.arguments.contains("--demo")
        let resolved = LibraryLocationPreferences.selection(demo:demo)
        let root = selectedRoot ?? resolved.url
        if selectedRoot == nil { try resolved.validate() }
        store = try MemoryStore(root:root)
        let loaded = AppSettings.load(root:root)
        settings = loaded
        capture = CaptureController(store:store, embedder:embedder, settings:loaded)
        audio = AudioController(store:store, embedder:embedder, settings:loaded)
        activity=ActivityCalendarModel(store:store)
        routines=RoutinesModel(store:store,embedder:embedder,settings:loaded)
        routines.onChange = {[weak self] in self?.refreshChats()}
        libraryWipe.pendingCleanup=(try? store.hasPendingLibraryWipeCleanup()) ?? false
        visualModelSetup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        libraryWipe.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        capture.onCapture = { [weak self] memory in self?.captured(memory) }; audio.onCapture = { [weak self] memory in self?.captured(memory) }
        capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for:name).sink { [weak self] _ in self?.audio.stop() }.store(in:&cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.didWakeNotification).sink { [weak self] _ in self?.routines.tick(); self?.resumeAutomaticVisualIndex() }.store(in:&cancellables)
        if demo { try? seedDemo() }
        showOnboarding = !demo && !UserDefaults.standard.bool(forKey:"onboarded")
        refresh(forceStatistics:true); refreshChats(); if startServices { startConfiguredServices() }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange,ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.publisher(for:name).sink { [weak self] _ in Task {@MainActor in self?.resumeAutomaticVisualIndex()} }.store(in:&cancellables)
        }
        NSWorkspace.shared.notificationCenter.publisher(for:NSWorkspace.sessionDidBecomeActiveNotification).sink { [weak self] _ in Task {@MainActor in self?.resumeAutomaticVisualIndex()} }.store(in:&cancellables)
        startHousekeeping()
    }
    private func startHousekeeping() {housekeeping?.invalidate();housekeeping = Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in Task { @MainActor in self?.maintain(automatic:true) } }}
    func startConfiguredServices() {visualAutoResumeAllowed=true;guard !libraryWipe.busy,!libraryWipe.pendingCleanup else {return};if !demo {routines.start()}; if settings.apiEnabled { startAPI() }; if settings.captureOnLaunch && !demo { capture.start() };resumeAutomaticVisualIndex() }
    func selectPreparedVisualModel(_ installed:VisualModelInstallation) {
        guard !store.isClosed else {return}
        settings.search.visual.modelDirectory=installed.directory.path
        visualIndexStatus=settings.search.visual.enabled ? "Local visual models are ready. Build / resume to search existing history.":"Local visual models are ready. Enable visual memory, then build / resume its index."
    }
    func prepareForLibrarySwitch() {
        activity.deactivate(clear:true)
        visualAutoResumeAllowed=false;cancelVisualIndexing();visualModelSetup.cancel()
        libraryOperationGeneration=UUID();jsonImportTask?.cancel();recapSaveTask?.cancel();for task in noteTasks.values {task.cancel()};libraryWipe.cancel()
        routines.stop();capture.pause(discardReplay:true); cancelOpeningMemory(); selected=nil; nativeModels.cancel(); audioImportTask?.cancel(); pauseAll(); cancelAnswer(); cancelIndexing(); automaticIndexTask?.cancel(); pendingIndex.removeAll(); pullTask?.cancel(); refreshTask?.cancel(); statisticsTask?.cancel(); diskUsageTask?.cancel(); housekeeping?.invalidate(); housekeeping = nil; api?.stop(); api = nil;apiStatus="API off"
    }
    func clearForVaultLock() {
        prepareForLibrarySwitch();libraryTransfer.cancel();routines.clearForLock()
        calendarSlice=nil;calendarSliceZone=nil
        hits.removeAll();selected=nil;selectedVisual=nil;answer=nil;chats.removeAll();chatTurns.removeAll();currentChatID=nil;query="";question="";resolvedSearch=nil;selectedEvidenceQuery="";errorMessage=nil
    }
    var filter: SearchFilter { filter(at:Date()) }
    func filter(at now: Date) -> SearchFilter {
        let calendar = Calendar.current; var start: Date?, end: Date?
        switch range {
        case "Today": let day = calendar.dateInterval(of:.day,for:now); start = day?.start; end = day?.end
        case "Yesterday": end = calendar.startOfDay(for:now); start = calendar.date(byAdding:.day,value:-1,to:end!)
        case "7 days": start = calendar.date(byAdding:.day,value:-7,to:now); end = now
        case "Calendar slice":
            start=calendarSlice?.start ?? .distantFuture;end=calendarSlice?.end ?? .distantPast
        case "Choose day": start = calendar.startOfDay(for:date); end = calendar.date(byAdding:.day,value:1,to:start!)
        default: break
        }
        return SearchFilter(query:query,app:appFilter == "All apps" ? nil : appFilter,kind:section == "Conversations" ? .audio : section == "Notes" ? .note : section == "Recaps" ? .summary : nil,start:start,end:end,favoritesOnly:section == "Saved",limit:200)
    }
    func browseActivity(start:Date,end:Date,snapshot:ActivityCalendarSnapshot) {
        guard !store.isClosed else {return}
        let lower=max(start,snapshot.scope.start ?? start),upper=min(end,snapshot.scope.end ?? end)
        guard lower<upper else {errorMessage="The selected calendar interval and source filters do not overlap";return}
        func quoted(_ value:String)->String {String(data:(try? JSONEncoder().encode(value)) ?? Data(),encoding:.utf8) ?? "\"\""}
        var terms=[String]()
        if let kind=snapshot.scope.kind {terms.append("kind:"+kind.rawValue)}
        if snapshot.scope.favoritesOnly {terms.append("is:favorite")}
        if let tag=snapshot.scope.tag {terms.append("tag:"+quoted(tag))}
        if let speaker=snapshot.scope.speaker {terms.append("speaker:"+quoted(speaker))}
        cancelOpeningMemory();selected=nil;hits=[];resolvedSearch=nil;searchInputError=nil
        calendarSlice=DateInterval(start:lower,end:upper);calendarSliceZone=snapshot.timeZone
        appFilter=snapshot.scope.app ?? "All apps";query=terms.joined(separator:" ");interpretQuery=true;mode = .keyword
        range="Calendar slice";section="Memories";refresh()
    }
    var activeSearchQuery: String { resolvedSearch?.originalQuery == query ? resolvedSearch!.filter.query : query }
    func focusSearch() {
        cancelOpeningMemory(); section = "Memories"; showSettings = false; selected = nil
        searchFocusRequest = UUID()
    }
    @Published var selectedPassage: PassageRange?
    @Published var selectedVisual:VisualMatch?
    func cancelOpeningMemory() {
        detailTask?.cancel();detailTask=nil;detailGeneration=UUID();openingMemoryID=nil
    }
    func openMemory(_ memory:Memory,query:String,passage:PassageRange?=nil,visual:VisualMatch?=nil) {
        let store=self.store
        openSource(id:memory.id,query:query,passage:passage,visual:visual) {try store.hydrate([SearchHit(memory:memory,score:0,match:"",passage:passage,visual:visual)])[0].memory}
    }
    func openRecapSource(_ card:RecapSourceCard) {
        let store=self.store
        openSource(id:card.id,query:"",passage:card.passage) {
            guard let current=try store.get(card.id),current.evidenceHash==card.revision else {throw OSwindError.unavailable("This original changed or was removed. Open the current history instead.")}
            if let passage=card.passage,passage.text(in:current.text)==nil {throw OSwindError.invalid("The saved source anchor is no longer available")}
            return current
        }
    }
    private func openSource(id:String,query:String,passage:PassageRange?,visual:VisualMatch?=nil,load:@escaping @Sendable () throws -> Memory) {
        cancelOpeningMemory();let generation=detailGeneration
        openingMemoryID=id
        detailTask=Task { [weak self] in
            let worker=Task.detached(priority:.userInitiated) {try load()}
            do {
                let full=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
                guard let self,!Task.isCancelled,self.detailGeneration==generation else {return}
                self.selectedEvidenceQuery=query;self.selectedPassage=passage;self.selectedVisual=visual;self.selected=full;self.openingMemoryID=nil;self.detailTask=nil
            } catch {
                guard let self,!Task.isCancelled,self.detailGeneration==generation else {return}
                self.openingMemoryID=nil;self.detailTask=nil;self.errorMessage=error.localizedDescription
            }
        }
    }
    func refresh(forceStatistics: Bool = false) {
        refreshStatistics(force:forceStatistics)
        if section=="Calendar" {refreshTask?.cancel();refreshing=false;activity.resumeAndInvalidate();return}
        searchInputError = nil
        refreshTask?.cancel(); let now = Date(), mode = self.mode
        let filter = self.filter(at:now), interpret = interpretQuery, store = self.store, configuration = settings.search, engine = RetrievalEngine(store:store,apple:embedder)
        refreshing = true
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds:150_000_000); guard !Task.isCancelled else { return }
            do {
                let result = try await engine.search(filter,mode:mode,configuration:configuration,interpretQuery:interpret,now:now,detail:.preview)
                guard !Task.isCancelled else { return }; self?.hits = result.hits; self?.resolvedSearch = result.resolution; self?.searchMS = result.duration*1000; self?.searchStrategy = result.strategy ?? ""; self?.searchWarnings = result.warnings; self?.refreshing = false; if self?.pendingRefresh == true { self?.pendingRefresh = false; self?.refresh() }
            } catch is CancellationError { }
            catch let error as QuerySyntaxError { guard !Task.isCancelled else { return }; self?.hits = []; self?.resolvedSearch = nil; self?.searchWarnings = []; self?.searchInputError = error.localizedDescription; self?.searchMS = 0; self?.searchStrategy = ""; self?.refreshing = false }
            catch { guard !Task.isCancelled else { return };if mode == .visual {self?.hits=[];self?.searchWarnings=[error.localizedDescription]} else {self?.errorMessage = error.localizedDescription}; self?.refreshing = false }
        }
    }
    private func refreshStatistics(force: Bool) {
        if statisticsTask != nil { if force { statisticsPending = true }; return }
        guard force || Date().timeIntervalSince(statisticsUpdatedAt) >= 5 else { return }
        let store = self.store
        statisticsTask = Task { [weak self] in
            do {
                var value = try await Task.detached(priority:.utility) { try store.stats(includeDiskUsage:false) }.value
                guard let self else { return }; value.bytes = self.stats.bytes
                self.stats = value; self.statisticsUpdatedAt = Date()
            } catch { self?.errorMessage = error.localizedDescription }
            guard let self else { return }; self.statisticsTask = nil
            if self.statisticsPending { self.statisticsPending = false; self.refreshStatistics(force:true) }
        }
        // Storage traversal is independent of both query publication and SQL
        // counts. Coalesce it across captures/keystrokes, including large stores.
        refreshStorageEstimate()
    }
    func invalidateStorageEstimate() { storageGeneration = UUID(); storageUpdatedAt = nil }
    private func refreshStorageEstimate() {
        guard diskUsageTask == nil, storageUpdatedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        let store = self.store, generation = storageGeneration
        diskUsageTask = Task { [weak self] in
            let bytes = await Task.detached(priority:.utility) { store.diskBytes() }.value
            guard let self else { return }; self.diskUsageTask = nil
            if generation == self.storageGeneration { self.stats.bytes = bytes; self.storageUpdatedAt = Date() }
            else { self.refreshStorageEstimate() }
        }
    }
    func ask(_ prompt: String? = nil, summarize: Bool = false) {
        let text = settings.privacy.sanitize(prompt ?? question).text
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !asking else { return }
        answerInputError = nil
        if prompt != nil { question = text }
        let now = Date(), sessionID = currentChatID, interpret = interpretQuery
        let f = filter(at:now)
        let config = settings.ai, searchConfig = settings.search, engine = AnswerEngine(store:store,embedder:embedder)
        let history = summarize ? [] : ConversationContext.questions(chatTurns), policy = settings.privacy
        asking = true
        answerTask = Task {
            do {
                let result = try await engine.answer(text,configuration:config,filter:f,summarize:summarize,searchConfiguration:searchConfig,previousQuestions:history,interpretQuery:interpret,now:now)
                try Task.checkCancellation()
                let targetID: String
                if let sessionID { targetID = sessionID }
                else { targetID = try store.createChat().id; currentChatID = targetID }
                let turn = try store.appendChatTurn(sessionID:targetID,question:text,answer:result,filter:f,policy:policy)
                answer = turn.answer; if question == text { question = "" }; refreshChats()
            } catch is CancellationError { }
            catch let error as QuerySyntaxError { if !Task.isCancelled { answerInputError = error.localizedDescription } }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
            asking = false
        }
    }
    func cancelAnswer() { answerTask?.cancel() }
    func newChat() { guard !asking else { return }; currentChatID = nil; chatTurns = []; answer = nil; question = "" }
    func selectChat(_ id: String) { guard !asking else { return }; currentChatID = id; question = ""; refreshChats() }
    func refreshChats() {
        do { chats = try store.chats(); if let id = currentChatID { if try store.chat(id) != nil { chatTurns = try store.chatTurns(id); answer = chatTurns.last?.answer } else { currentChatID = nil; chatTurns = []; answer = nil } } }
        catch { errorMessage = error.localizedDescription }
    }
    func deleteCurrentChat() { guard !asking, let id = currentChatID else { return }; do { try store.deleteChat(id); newChat(); refreshChats() } catch { errorMessage = error.localizedDescription } }
    func exportChat() {
        guard let id = currentChatID else { return }
        do { guard let session = try store.chat(id) else { return }; let text = ConversationContext.markdown(session,turns:try store.chatTurns(id,limit:1000)); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-conversation.md"; if panel.runModal() == .OK, let url = panel.url { try text.write(to:url,atomically:true,encoding:.utf8); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path) } } catch { errorMessage = error.localizedDescription }
    }
    func saveAnswer(_ value:Answer?=nil) {
        guard !libraryWipe.busy,!savingRecap,let result=value ?? answer,!result.sources.isEmpty else {return}
        savingRecap=true;recapSaveStatus="Saving a source-linked recap…"
        let store=self.store,embedder=self.embedder,policy=settings.privacy,generation=libraryOperationGeneration
        let worker=Task.detached(priority:.utility) {try store.saveRecap(result,title:"Recap · \(Date().formatted(date:.abbreviated,time:.shortened))",policy:policy,embedder:embedder)}
        recapSaveTask=Task {
            defer {savingRecap=false;recapSaveTask=nil}
            do {
                let memory=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
                guard libraryOperationGeneration==generation else {return}
                recapSaveStatus="Saved to Recaps with \(result.sources.count) original \(result.sources.count==1 ? "source":"sources").";captured(memory)
            } catch {
                guard libraryOperationGeneration==generation else {return}
                recapSaveStatus="Recap was not saved.";errorMessage=error.localizedDescription
            }
        }
    }
    func addNote(_ text:String,title:String="Quick note",kind:MemoryKind = .note) {
        guard !libraryWipe.busy else {return}
        let clean=settings.privacy.sanitize(text).text,embedder=self.embedder,store=self.store,id=UUID(),generation=libraryOperationGeneration
        let worker=Task.detached(priority:.utility) {var m=Memory(kind:kind,app:"OSwind",title:title,text:clean);m.embedding=embedder.embed(m.searchableText);m.embeddingModel=m.embedding==nil ? nil:embedder.modelID;try Task.checkCancellation();try store.insert(m);return m}
        noteTasks[id]=Task {
            defer {noteTasks[id]=nil}
            do {let memory=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()};guard libraryOperationGeneration==generation else {return};captured(memory)}
            catch {guard libraryOperationGeneration==generation,!Task.isCancelled else {return};errorMessage=error.localizedDescription}
        }
    }
    private func captured(_ memory: Memory) {
        queueVisualIndex(memory)
        refreshStatistics(force:true)
        if refreshing { pendingRefresh = true } else { refresh() }
        guard settings.search.provider == .ollama || memory.text.utf16.count > 2400 else { return }
        guard settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { indexStatus = "GPU indexing deferred in Low Power Mode; keyword/Apple capture continues"; return }
        if pendingIndex.count >= 64 { indexStatus = "GPU index is behind capture. Rebuild to catch up."; return }
        pendingIndex.removeAll { $0.id == memory.id }; pendingIndex.append(memory)
        startAutomaticIndexer()
    }
    private func startAutomaticIndexer() {
        guard automaticIndexTask == nil, settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        automaticIndexTask = Task { [weak self] in
            guard let self else { return }; defer { self.automaticIndexTask = nil; if !self.pendingIndex.isEmpty { self.startAutomaticIndexer() } }
            while !self.pendingIndex.isEmpty && !Task.isCancelled {
                guard self.settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { self.indexStatus = "GPU indexing deferred in Low Power Mode"; break }
                let batch = Array(self.pendingIndex.prefix(16)); self.pendingIndex.removeFirst(batch.count)
                let configuration = self.settings.search
                do { _ = try await RetrievalEngine(store:self.store,apple:self.embedder).index(batch,configuration:configuration,shouldContinue:{ configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled }) }
                catch is CancellationError { break }
                catch { if !Task.isCancelled { self.indexStatus = error.localizedDescription; self.pendingIndex.removeAll() }; break }
            }
        }
    }
    func startModelServer() {
        guard !startingModelServer else { return }; startingModelServer = true
        Task { do { modelStatus = try await LocalModelServer.shared.start(endpoint:settings.search.endpoint); inspectLocalModels() } catch { modelStatus = error.localizedDescription }; startingModelServer = false }
    }
    func inspectLocalModels() {
        let endpoint = settings.search.endpoint; installedModels = []; modelStatus = "Checking local server…"
        Task { do { let models = try await OllamaClient.shared.models(endpoint:endpoint); let runtime = try await OllamaClient.shared.runtime(endpoint:endpoint); guard settings.search.endpoint == endpoint else { return }; installedModels = models; localRuntime = runtime; modelStatus = models.isEmpty ? "Server ready; download a model below" : "\(models.count) local models available" } catch { modelStatus = "Local server unavailable: " + error.localizedDescription } }
    }
    func downloadModel(_ name: String) {
        guard pullingModel == nil else { return }; pullingModel = name; pullProgress = nil; let endpoint = settings.search.endpoint
        pullTask = Task {
            do { try await OllamaClient.shared.pull(name,endpoint:endpoint) { progress in Task { @MainActor in self.pullProgress = progress } }; modelStatus = "Downloaded \(name)" }
            catch is CancellationError { modelStatus = "Download request cancelled; cached layers can be resumed" }
            catch { modelStatus = error.localizedDescription }
            pullingModel = nil; pullProgress = nil; inspectLocalModels()
        }
    }
    func cancelModelDownload() { pullTask?.cancel() }
    func rebuildIndex() {
        guard !indexing else { return }; let configuration = settings.search
        guard configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { indexStatus = "Disable Low Power Mode or allow indexing below"; return }
        indexGeneration = UUID(); let generation = indexGeneration
        indexing = true; indexProgress = 0; indexStatus = "Preparing the selected local model…"
        indexTask = Task {
            do { let final = try await RetrievalEngine(store:store,apple:embedder).rebuild(configuration:configuration,shouldContinue:{ configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled }) { state in Task { @MainActor in guard self.indexGeneration == generation else { return }; self.indexProgress = state.total > 0 ? min(1,Double(state.indexed)/Double(state.total)) : 1; self.indexStatus = "\(state.indexed) / \(state.total) memories indexed" } }; guard indexGeneration == generation else { return }; indexStatus = final.indexed == final.total ? "Search index ready · \(final.indexed) memories" : "Index pass complete · \(final.indexed)/\(final.total); new captures may still be indexing"; refresh() }
            catch is CancellationError { guard indexGeneration == generation else { return }; indexStatus = "Indexing cancelled; completed batches are saved" }
            catch { guard indexGeneration == generation else { return }; indexStatus = error.localizedDescription }
            indexing = false
        }
    }
    private func watchFastIndex(_ generation: UUID) -> Task<Void,Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:500_000_000) } catch { return }
                guard let self, self.indexGeneration == generation else { return }
                let state = self.store.searchIndexStatus
                self.indexStatus = state.message + (state.total > 0 ? " · \(state.indexed)/\(state.total)" : "")
                if state.total > 0 { self.indexProgress = min(1,Double(state.indexed)/Double(state.total)) }
            }
        }
    }
    func prepareFastIndex() {
        guard !indexing else { return }
        let configuration = settings.search, localEmbedder = embedder; indexGeneration = UUID(); let generation = indexGeneration
        indexing = true; indexProgress = 0; indexStatus = "Preparing fast retrieval…"
        indexTask = Task {
            let observer = watchFastIndex(generation); defer { observer.cancel() }
            do {
                let identity: String, dimensions: Int
                if configuration.provider == .ollama { let batch = try await OllamaClient.shared.embed(["search index identity"],configuration:configuration); identity = batch.modelID; dimensions = batch.vectors[0].count }
                else { guard let vector = await Task.detached(priority:.utility,operation:{ localEmbedder.embed("search index identity") }).value else { throw OSwindError.unavailable("Apple sentence embeddings are unavailable") }; identity = localEmbedder.modelID; dimensions = vector.count }
                let state = try await store.buildSearchIndex(modelID:identity,dimensions:dimensions,allowLowPower:configuration.indexOnLowPower)
                guard indexGeneration == generation else { return }; indexStatus = "Fast retrieval ready · \(state.indexed) vectors"; indexProgress = 1; refresh()
            } catch { guard indexGeneration == generation else { return }; indexStatus = Task.isCancelled ? "Preparation cancelled; source vectors are retained" : error.localizedDescription }
            if indexGeneration == generation { indexing = false }
        }
    }
    func cancelIndexing() { indexTask?.cancel(); store.cancelSearchIndexBuild(pauseAutomatic:true) }
    func favorite(_ memory: Memory) { do { try store.setFavorite(memory.id,value:!memory.favorite); if selected?.id == memory.id { selected = try store.get(memory.id) }; refresh() } catch { errorMessage = error.localizedDescription } }
    func delete(_ memory:Memory) {
        guard !libraryWipe.busy,deletingID==nil,!maintenanceBusy else {return};deletingID=memory.id;deletionStatus="Deleting source and checking retained media…"
        if openingMemoryID==memory.id {cancelOpeningMemory()};if selected?.id==memory.id {selected=nil}
        let store=self.store
        Task {
            defer {deletingID=nil}
            do {
                let result=try await Task.detached(priority:.utility) {try store.delete(memory.id)}.value
                deletionStatus="Removed \(result.sources) \(result.sources==1 ? "source":"sources") · \(result.sharedMedia) shared \(result.sharedMedia==1 ? "file":"files") kept · \(result.pendingMedia) pending cleanup"
                if !result.warnings.isEmpty {errorMessage="The source deletion committed. "+result.warnings.joined(separator:" ")}
                activity.forgetCounts();invalidateStorageEstimate();refresh(forceStatistics:true);refreshChats()
            } catch {deletionStatus="Source was not deleted.";errorMessage=error.localizedDescription}
        }
    }
    func maintain(automatic:Bool=false) {
        guard !automatic || !libraryWipe.pendingCleanup else {return}
        guard !libraryWipe.busy,!maintenanceBusy,deletingID==nil else {return}
        let store=self.store,policy=settings.privacy,allowLowPower=settings.search.indexOnLowPower,shouldPrune = !automatic || settings.automaticMaintenance
        maintenanceBusy=true;maintenanceStatus=shouldPrune ? "Checking retention and retained media…":"Checking search cache…"
        Task {
            defer {maintenanceBusy=false}
            do {
                let (result,indexError)=try await Task.detached(priority:.utility) { () -> (RetentionCleanupResult?,String?) in
                    let report=shouldPrune ? try store.pruneHistory(before:Date().addingTimeInterval(-Double(policy.retentionDays)*86400),maxBytes:Int64(policy.maxStorageGB)*1_000_000_000):nil
                    do {try store.checkpointSearchIndexIfIdle(allowLowPower:allowLowPower);return (report,nil)}
                    catch {return (report,"Search cache maintenance did not finish: "+error.localizedDescription)}
                }.value
                if let result {
                    let budget=result.budgetMet==false ? "Storage target not reached.":"Storage target met."
                    maintenanceStatus="Removed \(result.erasure.sources) \(result.erasure.sources==1 ? "source":"sources") · \(result.erasure.pendingMedia) media files pending cleanup. "+budget+" "+result.erasure.warnings.joined(separator:" ")
                } else {maintenanceStatus="Automatic retention is off."}
                if let indexError {maintenanceStatus += " "+indexError}
                if let result,result.erasure.sources>0 {activity.forgetCounts()}
                invalidateStorageEstimate();refresh(forceStatistics:true);refreshChats();await catchUpIndex()
            } catch {maintenanceStatus="Cleanup did not complete: "+error.localizedDescription;if !automatic {errorMessage=maintenanceStatus}}
        }
    }
    private func catchUpIndex() async {
        let configuration = settings.search
        guard !indexing, configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        if configuration.provider == .apple {
            if (try? store.passageBacklog(modelID:embedder.modelID,filter:SearchFilter())) ?? 0 > 0 { rebuildIndex() }
            return
        }
        do {
            let model = try await OllamaClient.shared.models(endpoint:configuration.endpoint).first { $0.name == configuration.model || $0.name == configuration.model + ":latest" }
            guard settings.search == configuration, let model else { return }
            let prefix = "ollama:\(model.name)@\(model.digest):desktop-v1:"
            let indexes = try store.semanticIndexes().filter { $0.key.hasPrefix(prefix) }
            let indexed = indexes.values.max() ?? 0
            let pendingPassages = try indexes.keys.contains { try store.passageBacklog(modelID:$0,filter:SearchFilter())>0 }
            if indexed < (try store.matchingCount()) || pendingPassages { rebuildIndex() }
        } catch { indexStatus = "Index catch-up waiting for the local model server" }
    }
    func wipeLocalLibrary(retry:Bool=false) {
        guard !libraryWipe.busy,!maintenanceBusy,deletingID==nil,!libraryTransfer.busy else {return}
        prepareForLibrarySwitch()
        settings.captureOnLaunch=false;settings.apiEnabled=false;settings.routinesEnabled=false
        let generation=libraryOperationGeneration
        libraryWipe.run(store:store,retry:retry) {[weak self] result in
            guard let self,self.libraryOperationGeneration==generation else {return}
            self.routines.reload();self.answer=nil;self.chatTurns=[];self.currentChatID=nil;self.selected=nil;self.hits=[]
            self.invalidateStorageEstimate();self.refresh(forceStatistics:true);self.refreshChats();self.startHousekeeping()
        } onFailure: {[weak self] in guard let self,self.libraryOperationGeneration==generation else {return};self.startHousekeeping()}
    }
    func pauseAll(discardReplay:Bool=false) { pauseTimer?.invalidate(); pauseTimer = nil; pauseUntil = nil; capture.pause(discardReplay:discardReplay); audio.stop() }
    func pauseForHistoryErasure() {
        activity.deactivate(clear:true)
        // Stop readers holding media reservations before asking erasure to take
        // an exclusive reservation. Wake/power callbacks must not restart them.
        visualAutoResumeAllowed=false;cancelVisualIndexing()
        pauseAll(discardReplay:true);cancelAnswer();routines.cancel();cancelOpeningMemory();selected=nil;answer=nil
    }
    func pauseFor(minutes: Int) {
        let screenWasRunning = capture.running, audioWasRunning = audio.running
        pauseAll(); pauseUntil = Date().addingTimeInterval(Double(minutes)*60)
        pauseTimer = Timer.scheduledTimer(withTimeInterval:Double(minutes)*60,repeats:false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.pauseUntil = nil; if screenWasRunning { self.capture.start() }; if audioWasRunning && !SessionState.locked { await self.audio.start() } }
        }
    }
    var isCapturing: Bool { capture.running || audio.running }
    func captureNow() async {guard !libraryWipe.busy else {return};await capture.captureOnce(manual:true)}
    func toggleAudio() async {guard !libraryWipe.busy else {return};if audio.running {audio.finish()} else {await audio.start()}}
    func toggleCapture() {guard !libraryWipe.busy else {return};pauseTimer?.invalidate(); pauseUntil = nil; if isCapturing { pauseAll() } else { capture.start() } }
    func installNativeModel(_ kind:NativeModelKind,cache:URL?=nil,verifyOnly:Bool=false) {
        let speech=settings.speech,diarization=settings.diarization
        nativeModels.start(kind,cache:cache,verifyOnly:verifyOnly) { [weak self] result in
            guard let self else{return}
            let unchanged=kind == .parakeet ? self.settings.speech==speech:self.settings.diarization==diarization
            guard unchanged,!self.audio.hasActiveWork,!self.importingAudio else {
                self.nativeModels.message((result.reused ? "Verified.":"Installed.")+" Select Use model after current audio work finishes or to apply your new choice.",for:kind);return
            }
            self.useNativeModel(result)
        }
    }
    func useNativeModel(_ result:NativeModelInstallation) {
        guard !audio.hasActiveWork,!importingAudio else {nativeModels.message("Finish current audio work before changing models.",for:result.kind);return}
        switch result.kind {
        case .parakeet:
            var value=settings.speech;value.engine = .parakeet;value.modelDirectory=result.directory.path;settings.speech=value
        case .speakers:
            guard SpeakerDiarizer.supported else {nativeModels.message("Speaker labels require macOS 15 or later.",for:.speakers);return}
            var value=settings.diarization;value.modelDirectory=result.directory.path;value.enabled=true;settings.diarization=value
        }
        nativeModels.message("Ready for local transcription.",for:result.kind)
    }
    func importAudio() {
        guard !importingAudio else { return }
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.audio]; panel.allowsMultipleSelection=false; panel.message="Transcribe this file locally. Clip retention follows your Audio setting."
        guard panel.runModal() == .OK,let file=panel.url else { return }
        importingAudio=true; audioImportStatus="Preparing audio…"; let configuration=settings
        audioImportTask=Task {
            defer { importingAudio=false; audioImportTask=nil }
            do {
                if configuration.diarization.enabled {
                    guard SpeakerDiarizer.supported else { throw OSwindError.unavailable("Speaker labels require macOS 15 or later") }
                    _ = try configuration.diarization.localDirectory()
                }
                let clip=try await AudioClipSnapshot.prepare(file,store:store); defer { withExtendedLifetime(clip) {} }
                audioImportStatus="Transcribing locally…"
                var transcript=try await audio.recognizer.transcribe(file:clip.speechFile,settings:configuration,timeout:1800,workspaceParent:clip.speechFile.deletingLastPathComponent())
                try Task.checkCancellation(); transcript=try transcript.bounded(toSourceDuration:clip.duration)
                if configuration.diarization.enabled {
                    audioImportStatus="Identifying speakers locally…"
                    transcript=try await audio.speakers.annotate(transcript,file:clip.speechFile,configuration:configuration.diarization)
                }
                try Task.checkCancellation()
                let memory=try AudioAdmission.save(transcript,file:clip.file,store:store,settings:settings,timestamp:Date(),source:"Imported audio",title:file.deletingPathExtension().lastPathComponent,sessionID:UUID().uuidString,recordedLive:false,embedder:embedder,admission:clip.mediaActivity)
                captured(memory); audioImportStatus="Transcript saved · find it in Conversations"
            } catch is CancellationError { audioImportStatus="Import cancelled" }
            catch { audioImportStatus=error.localizedDescription }
        }
    }
    func cancelAudioImport() { audioImportTask?.cancel() }
    func exportData() { pauseAll(); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-export.json"; panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { do { try store.exportJSON(to:url) } catch { errorMessage = error.localizedDescription } } }
    func importData() {
        guard !importingJSON else {return};let panel=NSOpenPanel();panel.allowedContentTypes=[.json]
        if panel.runModal() == .OK,let url=panel.url {importJSONFile(url)}
    }
    func cancelJSONImport() {jsonImportTask?.cancel()}
    func importJSONFile(_ url:URL) {
        guard !libraryWipe.busy,!importingJSON else {return};importingJSON=true;importStatus="Importing sources and checking recap links…"
        let store=self.store,embedder=self.embedder,policy=settings.privacy,generation=libraryOperationGeneration
        let worker=Task.detached(priority:.utility) {try store.importJSONDetailed(from:url,embedder:embedder,policy:policy)}
        jsonImportTask=Task {
            defer {importingJSON=false;jsonImportTask=nil}
            do {
                let result=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
                guard libraryOperationGeneration==generation else {return}
                importStatus="Imported \(result.imported) records · \(result.excluded) excluded · \(result.skippedLinkedRecaps) linked recaps omitted because an original was excluded, redacted or stale."
                selected=nil;invalidateStorageEstimate();refresh(forceStatistics:true);refreshChats();await catchUpIndex()
            } catch is CancellationError {guard libraryOperationGeneration==generation else {return};importStatus="Import cancelled before publication."}
            catch {guard libraryOperationGeneration==generation else {return};importStatus="Import did not complete: "+error.localizedDescription;errorMessage=error.localizedDescription}
        }
    }

    func startAPI() {guard !libraryWipe.busy else {return};do { if api == nil { api = try LocalAPIServer(store:store,embedder:embedder) }; api?.onState = { [weak self] text in Task { @MainActor in self?.apiStatus = text } }; try api?.start(); settings.apiEnabled = true } catch { apiStatus = error.localizedDescription } }
    func stopAPI() { api?.stop(); api = nil; apiStatus = "API off"; settings.apiEnabled = false }
    func login(_ enabled: Bool) { do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { errorMessage = error.localizedDescription } }
    func seedDemo() throws {
        guard try store.stats().count == 0 else { return }
        let examples: [(String,String,String,MemoryKind)] = [
            ("Safari","Designing a quieter desktop","Research notes: event-driven capture reduces duplicate frames. Keep a clear pause control and searchable evidence. The interface should feel calm and immediate.",.screen),
            ("Xcode","OSwind / CaptureEngine.swift","Implementation decision: use ScreenCaptureKit for capture, Apple Vision for OCR, SQLite FTS5 for lexical retrieval, and local sentence embeddings for semantic recall.",.screen),
            ("System audio","Product sync · sample transcript","Alex: Let's ship the local-first experience first. Sam: I will own the retrieval benchmark by Friday. Decision: default to Balanced mode and keep cloud providers opt-in.",.audio),
            ("Notes","A small idea worth keeping","A memory tool should help you get back to the work, with the original source one click away. Never hide an evidence gap behind a confident answer.",.note),
            ("Safari","Apple Vision documentation","Vision recognizes text on device. Benchmark OCR fidelity with screenshots containing small text, dark backgrounds, multiple languages and different display scales.",.screen),
            ("OSwind","Today’s sample recap","Built a capture prototype and discussed retrieval quality. Next: verify privacy boundaries and measure idle energy. This is sample data, not your recorded activity.",.summary)
        ]
        for (i,item) in examples.enumerated() { var m = Memory(timestamp:Date().addingTimeInterval(-Double(i*1100)),kind:item.3,app:item.0,title:item.1,text:item.2,favorite:i == 3,tags:["sample"]); m.embedding = embedder.embed(m.searchableText); m.embeddingModel = embedder.modelID; try store.insert(m) }
    }
}
