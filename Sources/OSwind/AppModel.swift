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
    let libraryTransfer = LibraryTransferModel()
    @Published var settingsTab = "Capture"
    @Published var settings: AppSettings { didSet {
        capture.settings = settings; audio.settings = settings
        if oldValue.search != settings.search { indexGeneration = UUID(); indexTask?.cancel(); store.cancelSearchIndexBuild(); if settings.search.indexPolicy == .exact { store.releaseSearchIndex() }; automaticIndexTask?.cancel(); pendingIndex.removeAll(); indexing = false; indexStatus = "Search settings changed; prepare the selected index" }
        do { try settings.save(root:store.root) } catch { errorMessage = error.localizedDescription }
    } }
    @Published var section = "Memories"
    @Published var searchFocusRequest: UUID?
    @Published var query = ""
    @Published var mode: SearchMode = .hybrid
    @Published var appFilter = "All apps"
    @Published var range = "All time"
    @Published var date = Date()
    @Published var hits = [SearchHit]()
    @Published var stats = StoreStats()
    @Published var storageUpdatedAt: Date?
    @Published var selected: Memory?
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
    init(root selectedRoot: URL? = nil, startServices: Bool = true) throws {
        demo = CommandLine.arguments.contains("--demo")
        let resolved = LibraryLocationPreferences.selection(demo:demo)
        let root = selectedRoot ?? resolved.url
        if selectedRoot == nil { try resolved.validate() }
        store = try MemoryStore(root:root)
        let loaded = AppSettings.load(root:root)
        settings = loaded
        capture = CaptureController(store:store, embedder:embedder, settings:loaded)
        audio = AudioController(store:store, embedder:embedder, settings:loaded)
        capture.onCapture = { [weak self] memory in self?.captured(memory) }; audio.onCapture = { [weak self] memory in self?.captured(memory) }
        capture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in:&cancellables)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            NSWorkspace.shared.notificationCenter.publisher(for:name).sink { [weak self] _ in self?.audio.stop() }.store(in:&cancellables)
        }
        if demo { try? seedDemo() }
        showOnboarding = !demo && !UserDefaults.standard.bool(forKey:"onboarded")
        refresh(forceStatistics:true); refreshChats(); if startServices { startConfiguredServices() }
        housekeeping = Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in Task { @MainActor in self?.maintain(automatic:true) } }
    }
    func startConfiguredServices() { if settings.apiEnabled { startAPI() }; if settings.captureOnLaunch && !demo { capture.start() } }
    func prepareForLibrarySwitch() {
        audioImportTask?.cancel(); pauseAll(); cancelAnswer(); cancelIndexing(); automaticIndexTask?.cancel(); pendingIndex.removeAll(); pullTask?.cancel(); refreshTask?.cancel(); statisticsTask?.cancel(); diskUsageTask?.cancel(); housekeeping?.invalidate(); housekeeping = nil; api?.stop(); api = nil
    }
    var filter: SearchFilter { filter(at:Date()) }
    func filter(at now: Date) -> SearchFilter {
        let calendar = Calendar.current; var start: Date?, end: Date?
        switch range {
        case "Today": let day = calendar.dateInterval(of:.day,for:now); start = day?.start; end = day?.end
        case "Yesterday": end = calendar.startOfDay(for:now); start = calendar.date(byAdding:.day,value:-1,to:end!)
        case "7 days": start = calendar.date(byAdding:.day,value:-7,to:now); end = now
        case "Choose day": start = calendar.startOfDay(for:date); end = calendar.date(byAdding:.day,value:1,to:start!)
        default: break
        }
        return SearchFilter(query:query,app:appFilter == "All apps" ? nil : appFilter,kind:section == "Conversations" ? .audio : section == "Notes" ? .note : section == "Recaps" ? .summary : nil,start:start,end:end,favoritesOnly:section == "Saved",limit:200)
    }
    var activeSearchQuery: String { resolvedSearch?.originalQuery == query ? resolvedSearch!.filter.query : query }
    func focusSearch() {
        section = "Memories"; showSettings = false; selected = nil
        searchFocusRequest = UUID()
    }
    @Published var selectedPassage: PassageRange?
    func openMemory(_ memory: Memory, query: String, passage: PassageRange? = nil) { selectedEvidenceQuery = query; selectedPassage = passage; selected = memory }
    func refresh(forceStatistics: Bool = false) {
        refreshStatistics(force:forceStatistics)
        searchInputError = nil
        refreshTask?.cancel(); let now = Date(), mode = self.mode
        let filter = self.filter(at:now), interpret = interpretQuery, store = self.store, configuration = settings.search, engine = RetrievalEngine(store:store,apple:embedder)
        refreshing = true
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds:150_000_000); guard !Task.isCancelled else { return }
            do {
                let result = try await engine.search(filter,mode:mode,configuration:configuration,interpretQuery:interpret,now:now)
                guard !Task.isCancelled else { return }; self?.hits = result.hits; self?.resolvedSearch = result.resolution; self?.searchMS = result.duration*1000; self?.searchStrategy = result.strategy ?? ""; self?.searchWarnings = result.warnings; self?.refreshing = false; if self?.pendingRefresh == true { self?.pendingRefresh = false; self?.refresh() }
            } catch is CancellationError { }
            catch let error as QuerySyntaxError { guard !Task.isCancelled else { return }; self?.hits = []; self?.resolvedSearch = nil; self?.searchWarnings = []; self?.searchInputError = error.localizedDescription; self?.searchMS = 0; self?.searchStrategy = ""; self?.refreshing = false }
            catch { guard !Task.isCancelled else { return }; self?.errorMessage = error.localizedDescription; self?.refreshing = false }
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
    func saveAnswer() { guard let answer else { return }; addNote(answer.text, title:"Recap · \(Date().formatted(date:.abbreviated,time:.shortened))",kind:.summary) }
    func addNote(_ text: String, title: String = "Quick note", kind: MemoryKind = .note) {
        let clean = settings.privacy.sanitize(text).text; let embedder = self.embedder, store = self.store
        Task { do { let memory = try await Task.detached(priority:.utility) { var m = Memory(kind:kind,app:"OSwind",title:title,text:clean); m.embedding = embedder.embed(m.searchableText); m.embeddingModel = m.embedding == nil ? nil : embedder.modelID; try store.insert(m); return m }.value; captured(memory) } catch { errorMessage = error.localizedDescription } }
    }
    private func captured(_ memory: Memory) {
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
    func delete(_ memory: Memory) { do { try store.delete(memory.id); if selected?.id == memory.id { selected = nil }; invalidateStorageEstimate(); refresh(forceStatistics:true); refreshChats() } catch { errorMessage = error.localizedDescription } }
    func maintain(automatic: Bool = false) {
        let store = self.store, policy = settings.privacy, allowLowPower = settings.search.indexOnLowPower, shouldPrune = !automatic || settings.automaticMaintenance
        Task {
            do {
                _ = try await Task.detached(priority:.utility) {
                    let removed = shouldPrune ? try store.prune(before:Date().addingTimeInterval(-Double(policy.retentionDays)*86400),maxBytes:Int64(policy.maxStorageGB)*1_000_000_000) : 0
                    try store.checkpointSearchIndexIfIdle(allowLowPower:allowLowPower)
                    return removed
                }.value
                invalidateStorageEstimate(); refresh(forceStatistics:true); refreshChats(); await catchUpIndex()
            } catch { errorMessage = error.localizedDescription }
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
    func pauseAll() { pauseTimer?.invalidate(); pauseTimer = nil; pauseUntil = nil; capture.pause(); audio.stop() }
    func pauseFor(minutes: Int) {
        let screenWasRunning = capture.running, audioWasRunning = audio.running
        pauseAll(); pauseUntil = Date().addingTimeInterval(Double(minutes)*60)
        pauseTimer = Timer.scheduledTimer(withTimeInterval:Double(minutes)*60,repeats:false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.pauseUntil = nil; if screenWasRunning { self.capture.start() }; if audioWasRunning && !SessionState.locked { await self.audio.start() } }
        }
    }
    var isCapturing: Bool { capture.running || audio.running }
    func toggleCapture() { pauseTimer?.invalidate(); pauseUntil = nil; if isCapturing { pauseAll() } else { capture.start() } }
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
                let clip=try await AudioClipSnapshot.prepare(file); defer { withExtendedLifetime(clip) {} }
                audioImportStatus="Transcribing locally…"
                var transcript=try await audio.recognizer.transcribe(file:clip.speechFile,settings:configuration,timeout:1800)
                try Task.checkCancellation(); transcript.duration=clip.duration
                if configuration.diarization.enabled {
                    audioImportStatus="Identifying speakers locally…"
                    transcript=try await audio.speakers.annotate(transcript,file:clip.speechFile,configuration:configuration.diarization)
                }
                try Task.checkCancellation()
                let memory=try AudioAdmission.save(transcript,file:clip.file,store:store,settings:settings,timestamp:Date(),source:"Imported audio",title:file.deletingPathExtension().lastPathComponent,sessionID:UUID().uuidString,recordedLive:false,embedder:embedder)
                captured(memory); audioImportStatus="Transcript saved · find it in Conversations"
            } catch is CancellationError { audioImportStatus="Import cancelled" }
            catch { audioImportStatus=error.localizedDescription }
        }
    }
    func cancelAudioImport() { audioImportTask?.cancel() }
    func exportData() { pauseAll(); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-export.json"; panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { do { try store.exportJSON(to:url) } catch { errorMessage = error.localizedDescription } } }
    func importData() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { let store = store, embedder = embedder, policy = settings.privacy; Task { do { _ = try await Task.detached(priority:.utility) { try store.importJSON(from:url,embedder:embedder,policy:policy) }.value; invalidateStorageEstimate(); refresh(forceStatistics:true); await catchUpIndex() } catch { errorMessage = error.localizedDescription } } } }
    func startAPI() { do { if api == nil { api = try LocalAPIServer(store:store,embedder:embedder) }; api?.onState = { [weak self] text in Task { @MainActor in self?.apiStatus = text } }; try api?.start(); settings.apiEnabled = true } catch { apiStatus = error.localizedDescription } }
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
