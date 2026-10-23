import SwiftUI
import Combine
import OSwindCore
import AppKit
import ServiceManagement

@MainActor final class AppModel: ObservableObject {
    let store: MemoryStore
    let embedder = LocalEmbedder()
    let capture: CaptureController
    let audio: AudioController
    @Published var settings: AppSettings { didSet {
        capture.settings = settings; audio.settings = settings
        if oldValue.search != settings.search { indexGeneration = UUID(); indexTask?.cancel(); automaticIndexTask?.cancel(); pendingIndex.removeAll(); indexing = false; indexStatus = "Search model changed; build or resume its index" }
        do { try settings.save(root:store.root) } catch { errorMessage = error.localizedDescription }
    } }
    @Published var section = "Memories"
    @Published var query = ""
    @Published var mode: SearchMode = .hybrid
    @Published var appFilter = "All apps"
    @Published var range = "All time"
    @Published var date = Date()
    @Published var hits = [SearchHit]()
    @Published var stats = StoreStats()
    @Published var selected: Memory?
    @Published var answer: Answer?
    @Published var question = ""
    @Published var asking = false
    @Published var errorMessage: String?
    @Published var showSettings = false
    @Published var showOnboarding = false
    @Published var pauseUntil: Date?
    private var pauseTimer: Timer?
    @Published var apiStatus = "API off"
    @Published var searchMS = 0.0
    @Published var refreshing = false
    @Published var searchWarnings = [String]()
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
    private var housekeeping: Timer?
    init() {
        demo = CommandLine.arguments.contains("--demo")
        let root = ProcessInfo.processInfo.environment["OSWIND_DATA_DIR"].map { URL(fileURLWithPath:$0) } ?? (demo ? Paths.data.deletingLastPathComponent().appendingPathComponent("OSwind-Demo") : Paths.data)
        do { store = try MemoryStore(root:root) } catch { fatalError("OSwind cannot open its local data directory: \(error.localizedDescription)") }
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
        refresh(); if settings.apiEnabled { startAPI() }; if settings.captureOnLaunch && !demo { capture.start() }
        housekeeping = Timer.scheduledTimer(withTimeInterval:300,repeats:true) { [weak self] _ in Task { @MainActor in self?.maintain() } }
    }
    var filter: SearchFilter {
        let calendar = Calendar.current; var start: Date?, end: Date?
        switch range { case "Today": start = calendar.startOfDay(for:Date()); case "Yesterday": end = calendar.startOfDay(for:Date()); start = calendar.date(byAdding:.day,value:-1,to:end!); case "7 days": start = calendar.date(byAdding:.day,value:-7,to:Date()); case "Choose day": start = calendar.startOfDay(for:date); end = calendar.date(byAdding:.day,value:1,to:start!); default: break }
        return SearchFilter(query:query, app:appFilter == "All apps" ? nil : appFilter, kind:section == "Conversations" ? .audio : section == "Notes" ? .note : section == "Recaps" ? .summary : nil, start:start, end:end, favoritesOnly:section == "Saved",limit:200)
    }
    func refresh() {
        refreshTask?.cancel(); let filter = self.filter, mode = self.mode, store = self.store, configuration = settings.search, engine = RetrievalEngine(store:store,apple:embedder)
        refreshing = true
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds:150_000_000); guard !Task.isCancelled else { return }
            do {
                let result = try await engine.search(filter,mode:mode,configuration:configuration); let stats = try await Task.detached(priority:.utility) { try store.stats() }.value
                guard !Task.isCancelled else { return }; self?.hits = result.hits; self?.stats = stats; self?.searchMS = result.duration*1000; self?.searchWarnings = result.warnings; self?.refreshing = false; if self?.pendingRefresh == true { self?.pendingRefresh = false; self?.refresh() }
            } catch is CancellationError { } catch { guard !Task.isCancelled else { return }; self?.errorMessage = error.localizedDescription; self?.refreshing = false }
        }
    }
    func ask(_ prompt: String? = nil, summarize: Bool = false) {
        let text = prompt ?? question; guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !asking else { return }
        asking = true; let f = filter, config = settings.ai, searchConfig = settings.search, engine = AnswerEngine(store:store,embedder:embedder)
        Task { do { answer = try await engine.answer(text,configuration:config,filter:f,summarize:summarize,searchConfiguration:searchConfig) } catch { errorMessage = error.localizedDescription }; asking = false }
    }
    func saveAnswer() { guard let answer else { return }; addNote(answer.text, title:"Recap · \(Date().formatted(date:.abbreviated,time:.shortened))",kind:.summary) }
    func addNote(_ text: String, title: String = "Quick note", kind: MemoryKind = .note) {
        let clean = settings.privacy.sanitize(text).text; let embedder = self.embedder, store = self.store
        Task { do { let memory = try await Task.detached(priority:.utility) { var m = Memory(kind:kind,app:"OSwind",title:title,text:clean); m.embedding = embedder.embed(m.searchableText); m.embeddingModel = m.embedding == nil ? nil : embedder.modelID; try store.insert(m); return m }.value; captured(memory) } catch { errorMessage = error.localizedDescription } }
    }
    private func captured(_ memory: Memory) {
        if refreshing { pendingRefresh = true } else { refresh() }
        guard settings.search.provider == .ollama else { return }
        guard settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { indexStatus = "GPU indexing deferred in Low Power Mode; keyword/Apple capture continues"; return }
        if pendingIndex.count >= 64 { indexStatus = "GPU index is behind capture. Rebuild to catch up."; return }
        pendingIndex.removeAll { $0.id == memory.id }; pendingIndex.append(memory)
        startAutomaticIndexer()
    }
    private func startAutomaticIndexer() {
        guard automaticIndexTask == nil, settings.search.provider == .ollama, settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        automaticIndexTask = Task { [weak self] in
            guard let self else { return }; defer { self.automaticIndexTask = nil; if !self.pendingIndex.isEmpty { self.startAutomaticIndexer() } }
            while !self.pendingIndex.isEmpty && !Task.isCancelled {
                guard self.settings.search.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { self.indexStatus = "GPU indexing deferred in Low Power Mode"; break }
                let batch = Array(self.pendingIndex.prefix(16)); self.pendingIndex.removeFirst(batch.count)
                do { _ = try await RetrievalEngine(store:self.store,apple:self.embedder).index(batch,configuration:self.settings.search) }
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
    func cancelIndexing() { indexTask?.cancel() }
    func favorite(_ memory: Memory) { do { try store.setFavorite(memory.id,value:!memory.favorite); if selected?.id == memory.id { selected = try store.get(memory.id) }; refresh() } catch { errorMessage = error.localizedDescription } }
    func delete(_ memory: Memory) { do { try store.delete(memory.id); if selected?.id == memory.id { selected = nil }; refresh() } catch { errorMessage = error.localizedDescription } }
    func maintain() { let store = self.store, policy = settings.privacy; Task { do { _ = try await Task.detached(priority:.utility) { try store.prune(before:Date().addingTimeInterval(-Double(policy.retentionDays)*86400),maxBytes:Int64(policy.maxStorageGB)*1_000_000_000) }.value; refresh(); await catchUpIndex() } catch { errorMessage = error.localizedDescription } } }
    private func catchUpIndex() async {
        let configuration = settings.search
        guard configuration.provider == .ollama, !indexing, configuration.indexOnLowPower || !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }
        do { let model = try await OllamaClient.shared.models(endpoint:configuration.endpoint).first { $0.name == configuration.model || $0.name == configuration.model + ":latest" }; guard settings.search == configuration, let model else { return }; let prefix = "ollama:\(model.name)@\(model.digest):desktop-v1:"; let indexed = try store.semanticIndexes().filter { $0.key.hasPrefix(prefix) }.map(\.value).max() ?? 0; if indexed < (try store.matchingCount()) { rebuildIndex() } } catch { indexStatus = "Index catch-up waiting for the local model server" }
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
    func exportData() { pauseAll(); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-export.json"; panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { do { try store.exportJSON(to:url) } catch { errorMessage = error.localizedDescription } } }
    func importData() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { let store = store, embedder = embedder, policy = settings.privacy; Task { do { _ = try await Task.detached(priority:.utility) { try store.importJSON(from:url,embedder:embedder,policy:policy) }.value; refresh(); await catchUpIndex() } catch { errorMessage = error.localizedDescription } } } }
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
