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
    @Published var settings: AppSettings { didSet { capture.settings = settings; audio.settings = settings; do { try settings.save(root: store.root) } catch { errorMessage = error.localizedDescription } } }
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
        capture.onCapture = { [weak self] _ in self?.refresh() }; audio.onCapture = { [weak self] _ in self?.refresh() }
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
        refreshTask?.cancel(); let filter = self.filter, mode = self.mode, store = self.store, embedder = self.embedder
        refreshing = true
        refreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds:150_000_000); guard !Task.isCancelled else { return }
            do {
                let result = try await Task.detached(priority:.userInitiated) { let start = Date(); let vector = filter.query.isEmpty || mode == .keyword ? nil : embedder.embed(filter.query); return (try store.search(filter,mode:mode,vector:vector,modelID:embedder.modelID),try store.stats(),Date().timeIntervalSince(start)*1000) }.value
                guard !Task.isCancelled else { return }; self?.hits = result.0; self?.stats = result.1; self?.searchMS = result.2; self?.refreshing = false
            } catch { self?.errorMessage = error.localizedDescription; self?.refreshing = false }
        }
    }
    func ask(_ prompt: String? = nil, summarize: Bool = false) {
        let text = prompt ?? question; guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, !asking else { return }
        asking = true; let f = filter, config = settings.ai, engine = AnswerEngine(store:store,embedder:embedder)
        Task { do { answer = try await engine.answer(text,configuration:config,filter:f,summarize:summarize) } catch { errorMessage = error.localizedDescription }; asking = false }
    }
    func saveAnswer() { guard let answer else { return }; addNote(answer.text, title:"Recap · \(Date().formatted(date:.abbreviated,time:.shortened))",kind:.summary) }
    func addNote(_ text: String, title: String = "Quick note", kind: MemoryKind = .note) {
        let clean = settings.privacy.sanitize(text).text; let embedder = self.embedder, store = self.store
        Task { do { try await Task.detached(priority:.utility) { var m = Memory(kind:kind,app:"OSwind",title:title,text:clean); m.embedding = embedder.embed(m.searchableText); m.embeddingModel = m.embedding == nil ? nil : embedder.modelID; try store.insert(m) }.value; refresh() } catch { errorMessage = error.localizedDescription } }
    }
    func favorite(_ memory: Memory) { do { try store.setFavorite(memory.id,value:!memory.favorite); if selected?.id == memory.id { selected = try store.get(memory.id) }; refresh() } catch { errorMessage = error.localizedDescription } }
    func delete(_ memory: Memory) { do { try store.delete(memory.id); if selected?.id == memory.id { selected = nil }; refresh() } catch { errorMessage = error.localizedDescription } }
    func maintain() { let store = self.store, policy = settings.privacy; Task { do { _ = try await Task.detached(priority:.utility) { try store.prune(before:Date().addingTimeInterval(-Double(policy.retentionDays)*86400),maxBytes:Int64(policy.maxStorageGB)*1_000_000_000) }.value; refresh() } catch { errorMessage = error.localizedDescription } } }
    func pauseAll() { pauseTimer?.invalidate(); pauseTimer = nil; pauseUntil = nil; capture.pause(); audio.stop() }
    func pauseFor(minutes: Int) {
        let screenWasRunning = capture.running, audioWasRunning = audio.running
        pauseAll(); pauseUntil = Date().addingTimeInterval(Double(minutes)*60)
        pauseTimer = Timer.scheduledTimer(withTimeInterval:Double(minutes)*60,repeats:false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.pauseUntil = nil; if screenWasRunning { self.capture.start() }; if audioWasRunning && !SessionState.locked { await self.audio.start() } }
        }
    }
    func toggleCapture() { pauseTimer?.invalidate(); pauseUntil = nil; if capture.running { pauseAll() } else { capture.start() } }
    func exportData() { pauseAll(); let panel = NSSavePanel(); panel.nameFieldStringValue = "OSwind-export.json"; panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { do { try store.exportJSON(to:url) } catch { errorMessage = error.localizedDescription } } }
    func importData() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; if panel.runModal() == .OK, let url = panel.url { let store = store, embedder = embedder, policy = settings.privacy; Task { do { _ = try await Task.detached(priority:.utility) { try store.importJSON(from:url,embedder:embedder,policy:policy) }.value; refresh() } catch { errorMessage = error.localizedDescription } } } }
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
