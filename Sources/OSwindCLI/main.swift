import Foundation
import OSwindCore
import AppKit
import Metal
#if canImport(FoundationModels)
import FoundationModels
#endif

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? { guard let i = args.firstIndex(of:name), i+1 < args.count else { return nil }; let value = args[i+1]; args.removeSubrange(i...i+1); return value }
let root = option("--data").map { URL(fileURLWithPath:$0) } ?? ProcessInfo.processInfo.environment["OSWIND_DATA_DIR"].map { URL(fileURLWithPath:$0) } ?? Paths.data
let command = args.first ?? "help"
if !args.isEmpty { args.removeFirst() }
let literalQuery = args.contains("--literal")
func validatedOption(_ name: String) throws -> String? {
    let count = args.filter {$0 == name}.count
    guard count <= 1 else { throw OSwindError.invalid("Use \(name) only once") }
    guard count == 1 else { return nil }
    guard let value = option(name) else { throw OSwindError.invalid("Enter a value after \(name)") }; return value
}
func emit(_ object: Any) throws { let data = try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]); print(String(data:data,encoding:.utf8)!) }
func encoded<T: Encodable>(_ object: T) throws { try emit(Integration.json(object)) }
func searchFilter() throws -> SearchFilter {
    var values = [String:Any]()
    let fields = [("--app","app"),("--kind","kind"),("--from","start"),("--to","end"),("--tag","tag"),("--speaker","speaker"),("--limit","limit")]
    for (flag,name) in fields {
        guard args.filter({$0 == flag}).count <= 1 else { throw OSwindError.invalid("Use \(flag) only once") }
        if args.contains(flag) {
            guard let value = option(flag) else { throw OSwindError.invalid("Enter a value after \(flag)") }
            if name == "limit" { guard let limit = Int(value) else { throw OSwindError.invalid("limit must be an integer from 1 to 100") }; values[name] = limit }
            else { values[name] = value }
        }
    }
    if values["limit"] == nil { values["limit"] = 20 }
    values["favorites"] = args.contains("--favorites")
    args.removeAll {$0 == "--favorites" || $0 == "--json" || $0 == "--literal"}
    values["query"] = args.joined(separator:" ")
    return try Integration.filter(values)
}

do {
    if command == "help" || command == "--help" {
        print("""
        OSwind 0.1.0 · local desktop memory
        Usage: oswindctl [--data DIRECTORY] COMMAND
          doctor                         Inspect local permissions, GPU and models
          search [--preview] [--mode hybrid|keyword|semantic] [--app APP] [--kind KIND]
                 [--from ISO8601] [--to ISO8601] [--limit N] [--literal] WORDS
                 Query scopes: yesterday, last week, on:YYYY-MM-DD, app:"Safari", kind:audio, speaker:"Maya", tag:work, is:favorite
          get ID                         Read one complete source, including timed transcript
          ask [--provider evidence|apple|ollama|compatible|anthropic] QUESTION
          chat list|new|show ID|delete ID  Manage saved local conversations
          chat ask ID [--provider NAME] QUESTION  Recheck sources for a follow-up
          chat export ID PATH            Export a conversation to Markdown
          routine template|put FILE|list|history [ID]  Configure scheduled source-linked recaps
          routine run ID|tick [--at ISO8601]           Run once or process one due occurrence
          routine scheduler on|off|preview ID|delete ID
          note TEXT                      Save a redacted, searchable note
          stats                          Storage and capture counts
          config                         Print settings (no API keys)
          models list|status|pull NAME    Inspect/download local Ollama models
          reindex [--provider apple|ollama] [--model NAME] [--use-model]  Build/resume source and passage vectors
          index-search [--model NAME] [--rebuild] [--use-index]  Prepare fast local retrieval
          eval-retrieval [--model NAME]   Evaluate the diverse relevance fixture
          backup create PATH             Back up database, chats, settings and retained media
          backup inspect PATH            Verify a complete .oswindbackup package
          backup restore PATH --to DIR   Restore into a new, quiet library
          backup cleanup [--directory PARENT] Remove abandoned staging jobs
          export-markdown NEW_DIR [--include-media]  Export portable Markdown sources and conversations
          export PATH                    Export text and metadata JSON
          import PATH                    Import OSwind JSON, redact, rebuild vectors
          diarize PATH --speaker-model DIR [--repetitions N] [--output NEW_JSON]  Anonymous raw timeline, no library write
          import-audio PATH [--retain-audio] Transcribe and save an audio file locally
            [--engine parakeet --native-model DIR] [--speaker-model DIR]
          name-speaker ID --from LABEL --name NAME  Name a recording-local speaker
          native-model list             List pinned native model downloads
          native-model install|verify parakeet|speakers [--cache-root PATH]
          delete ID                      Delete one memory and its media
          prune [--days N] [--max-gb N]   Apply retention
          capture-replay --seconds N [--app-bundle ID]  Bounded hardware replay with existing permissions
          capture [--app-bundle ID]      Capture a chosen/current window once
          transcribe FILE --model PATH   Local whisper.cpp transcription
          serve                          Read-only token-auth API at 127.0.0.1:47831
          mcp                            Read-only MCP over stdio
          benchmark [--count N]          Isolated synthetic retrieval benchmark
          probe-visual-replay --output NEW_DIR [--frames 12] [--software]  Synthetic OCR/video/decode probe
          benchmark-audio-search --archive DIR [--prepare] [--detail full|preview]  Timed-transcript performance
          benchmark-vectors [--count N] [--dimensions N]  Vector scaling / optional --indexed --quality-queries N
          benchmark-stats --archive PATH  Compare synthetic archive metadata paths
        No cloud model is used unless explicitly configured. BYOK keys are read
        from Keychain; use the app's Models settings to configure them.
        """)
    } else if command == "native-model" {
        let operation=args.first ?? "list";if !args.isEmpty {args.removeFirst()}
        let cache=try validatedOption("--cache-root").map{URL(fileURLWithPath:$0)}
        if operation=="list" {
            guard args.isEmpty else {throw OSwindError.invalid("Use native-model list [--cache-root PATH]")}
            try emit(try NativeModelKind.allCases.map {kind -> [String:Any] in
                let catalog=try kind.catalog();return ["kind":kind.rawValue,"name":kind.title,"bytes":catalog.bytes,"revision":catalog.revision,"license":catalog.license,"directory":try NativeModelInstaller.destination(for:kind,cache:cache).path]
            })
        } else {
            guard ["install","verify"].contains(operation),args.count==1,let kind=NativeModelKind(rawValue:args[0]) else {throw OSwindError.invalid("Use native-model install|verify parakeet|speakers [--cache-root PATH]")}
            do {try encoded(await runNativeModelCLI(kind,cache:cache,verifyOnly:operation=="verify"))}
            catch is CancellationError {FileHandle.standardError.write(Data("Model setup cancelled.\n".utf8));exit(130)}
        }
    } else if command == "backup" {
        guard let action = args.first else { throw OSwindError.invalid("Use backup create PATH, inspect PATH, restore PATH --to NEW_DIRECTORY, or cleanup") }; args.removeFirst()
        let reporter = BackupCLIProgress()
        switch action {
        case "create":
            let attemptsText = try validatedOption("--max-attempts") ?? "3"
            guard let attempts = Int(attemptsText), (1...10).contains(attempts), args.count==1 else { throw OSwindError.invalid("Use backup create PATH [--max-attempts 1–10]") }
            let destination = URL(fileURLWithPath:args[0]); guard FileManager.default.fileExists(atPath:root.appendingPathComponent("memory.sqlite").path) else { throw OSwindError.invalid("The source library does not exist") }
            let store = try MemoryStore(root:root)
            try encoded(await runBackupCLI { try LibraryBackup.create(store:store,destination:destination,maxAttempts:attempts,progress:reporter.update) })
        case "inspect":
            guard args.count==1 else { throw OSwindError.invalid("Use backup inspect PATH") }; let archive = URL(fileURLWithPath:args[0])
            try encoded(await runBackupCLI { try LibraryBackup.inspect(archive,progress:reporter.update) })
        case "restore":
            guard let target = try validatedOption("--to") else { throw OSwindError.invalid("Use backup restore PATH --to NEW_DIRECTORY") }
            let fingerprint = try validatedOption("--fingerprint")
            guard args.count==1 else { throw OSwindError.invalid("Use backup restore PATH --to NEW_DIRECTORY [--fingerprint HASH]") }
            let archive = URL(fileURLWithPath:args[0]), destination = URL(fileURLWithPath:target)
            try encoded(await runBackupCLI { try LibraryBackup.restore(archive,to:destination,expectedFingerprint:fingerprint,progress:reporter.update) })
        case "cleanup":
            let directory = try validatedOption("--directory").map { URL(fileURLWithPath:$0) } ?? FileManager.default.temporaryDirectory
            guard args.isEmpty else { throw OSwindError.invalid("Use backup cleanup [--directory PARENT]") }
            try emit(["removed_jobs":BackupWorkspaceCleanup.run(in:directory)])
        default: throw OSwindError.invalid("Use backup create, inspect, restore or cleanup")
        }
    } else if command == "diarize" {
        guard let model=try validatedOption("--speaker-model") else {throw OSwindError.invalid("Use diarize AUDIO --speaker-model LOCAL_DIRECTORY")}
        let repeatText=try validatedOption("--repetitions") ?? "1",output=try validatedOption("--output")
        guard let repetitions=Int(repeatText),(1...10).contains(repetitions),args.count==1 else {throw OSwindError.invalid("Use one audio path and 1–10 repetitions")}
        if let output,FileManager.default.fileExists(atPath:output) {throw OSwindError.invalid("Timeline output must be a new file")}
        var configuration=DiarizationConfiguration();configuration.enabled=true;configuration.modelDirectory=model
        guard SpeakerDiarizer.supported else {throw OSwindError.unavailable("Speaker diarization requires macOS 15 or later")}
        _ = try configuration.localDirectory()
        let prepare=Date(),clip=try await AudioClipSnapshot.prepare(URL(fileURLWithPath:args[0]));defer {withExtendedLifetime(clip){}}
        let prepareSeconds=Date().timeIntervalSince(prepare),runtime=SpeakerDiarizer()
        // Repeated diagnostics promise one resident backend until explicit unload.
        await runtime.setRetention(.untilQuit)
        var runs=[[String:Any]]()
        for index in 0..<repetitions {
            let start=Date(),timeline=try await runtime.timeline(file:clip.speechFile,duration:clip.duration,configuration:configuration)
            let seconds=Date().timeIntervalSince(start)
            runs.append(["index":index,"resident_backend_reused":index>0,"seconds":seconds,"real_time_factor":seconds/clip.duration,"timeline":try Integration.json(timeline)])
        }
        try await runtime.unload()
        let result:[String:Any]=["format":"OSwind raw speaker timeline v1","policy":SpeakerDiarizer.policyVersion,"preparation_seconds":prepareSeconds,"runs":runs,"scope":"Anonymous recording-local turns before ASR attribution. First run includes model load; later runs reuse this process backend. OS/Core ML compilation caches uncontrolled. No library write, embeddings or voice profiles exported."]
        if let output {try writeNewPrivateJSON(result,to:output)}
        try emit(result)
    } else if command == "doctor" {
        let settings = AppSettings.load(root:root); let embedder = LocalEmbedder()
        var result: [String:Any] = ["version":"0.1.0","os":ProcessInfo.processInfo.operatingSystemVersionString,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "unavailable","screenRecording":CGPreflightScreenCaptureAccess(),"screenLocked":SessionState.locked,"accessibility":AXIsProcessTrusted(),"sentenceEmbeddings":embedder.available,"dataDirectory":root.path,"whisperExecutable":FileManager.default.isExecutableFile(atPath:settings.whisperBinary),"whisperModel":FileManager.default.fileExists(atPath:settings.whisperModel),"provider":settings.ai.provider.rawValue]
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { result["appleIntelligence"] = SystemLanguageModel.default.isAvailable }
        #endif
        try emit(result)
    } else if command == "benchmark-stats" {
        guard let path = option("--archive") else { throw OSwindError.invalid("Pass --archive with an existing synthetic vector benchmark directory") }
        let output = option("--output"), result = try StatisticsEvaluation.run(archive:URL(fileURLWithPath:path),repetitions:Int(option("--repetitions") ?? "5") ?? 5)
        if let output { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic) }; try emit(result)
    } else if command == "probe-visual-replay" {
        guard let path=try validatedOption("--output") else {throw OSwindError.invalid("Use probe-visual-replay --output NEW_DIRECTORY")}
        let framesText=try validatedOption("--frames") ?? "12"
        guard let frames=Int(framesText) else {throw OSwindError.invalid("frames must be 2–120")}
        let software=args.contains("--software");args.removeAll {$0=="--software"}
        guard args.isEmpty else {throw OSwindError.invalid("Unknown visual probe argument")}
        try emit(await VisualReplayBenchmark.run(directory:URL(fileURLWithPath:path),frames:frames,hardwareRequired:!software))
    } else if command == "benchmark-audio-search" {
        guard let path=try validatedOption("--archive") else {throw OSwindError.invalid("Use benchmark-audio-search --archive SYNTHETIC_DIRECTORY [--prepare --clips 32 --words 10000 | --detail full|preview --repetitions 7]")}
        let output=try validatedOption("--output"),detailText=try validatedOption("--detail") ?? "preview"
        guard let detail=SearchDetail(rawValue:detailText) else {throw OSwindError.invalid("detail must be full or preview")}
        let count=try validatedOption("--clips"),words=try validatedOption("--words"),repetitions=try validatedOption("--repetitions")
        let preparing=args.contains("--prepare");args.removeAll {$0=="--prepare"}
        guard args.isEmpty else {throw OSwindError.invalid("Unknown audio-search benchmark argument")}
        func integer(_ input:String?,default fallback:Int) throws -> Int {guard let input else {return fallback};guard let value=Int(input) else {throw OSwindError.invalid("Benchmark sizes must be integers")};return value}
        let archive=URL(fileURLWithPath:path),result:[String:Any]
        if preparing {result=try AudioSearchEvaluation.prepare(archive:archive,clips:integer(count,default:32),words:integer(words,default:10000))}
        else {guard count==nil,words==nil else {throw OSwindError.invalid("--clips and --words apply only with --prepare")};result=try AudioSearchEvaluation.run(archive:archive,detail:detail,repetitions:integer(repetitions,default:7))}
        if let output {try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)};try emit(result)
    } else if command == "benchmark-vectors" {
        let count = Int(option("--count") ?? "10000") ?? 10000, dimensions = Int(option("--dimensions") ?? "1024") ?? 1024, repetitions = Int(option("--repetitions") ?? "3") ?? 3, output = option("--output")
        let archive = option("--archive").map { URL(fileURLWithPath:$0) }
        let result = try await VectorScalingEvaluation.run(count:count,dimensions:dimensions,repetitions:repetitions,indexed:args.contains("--indexed"),archive:archive,qualityQueries:Int(option("--quality-queries") ?? "0") ?? 0,qualitySeedOffset:Int(option("--quality-seed-offset") ?? "17") ?? 17)
        if let output { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic) }; try emit(result)
    } else if command == "benchmark" {
        let count = min(50000,max(100,Int(option("--count") ?? "1000") ?? 1000))
        let output = option("--output")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("oswind-bench-"+UUID().uuidString); defer { try? FileManager.default.removeItem(at:scratch) }
        let store = try MemoryStore(root:scratch), embedder = LocalEmbedder()
        let corpus: [(String,String,String)] = [
            ("release","Release decision","Team agreed to ship OSwind v0 on Friday. Maya owns the checklist. Screen capture uses ScreenCaptureKit."),
            ("battery","Battery investigation","Laptop energy use drops when idle. We changed the light profile to take a screenshot every twenty seconds and stop during sleep."),
            ("lunch","Lunch plans","Meet Priya at the Italian restaurant at noon on Thursday. The reservation is for four people."),
            ("auth","Authentication bug","The login redirect fails because the cookie SameSite setting is strict. Fix the authentication callback before the release."),
            ("meeting","Customer call","Jamie asked for offline meeting transcripts and source citations. Action: Theo will prototype microphone capture by Monday."),
            ("design","Design review","Use a muted mint accent, clear typography, and a persistent pause button. The timeline should feel calm and immediate."),
            ("vector","Search architecture","Reciprocal rank fusion combines BM25 lexical ranking with cosine similarity over sentence embeddings. Reranking is a follow-up task."),
            ("privacy","Data retention policy","Delete screenshots older than thirty days. Password manager apps and banking websites must be excluded before capture."),
            ("audio","Speech pipeline","Whisper base.en transcribes local audio with Metal GPU acceleration. Voice activity detection discards silent segments."),
            ("invoice","Invoice follow-up","Acme invoice number 4821 is due on November 12. Email the receipt to Jordan after the payment clears."),
            ("recipe","Weekend cooking","Roast cauliflower at two hundred degrees. Add tahini, lemon, cumin, and parsley. Serve with warm flatbread."),
            ("travel","Conference travel","Flight to Seattle departs Tuesday at nine in the morning. Hotel check-in is at three. Bring the demo laptop.")
        ]
        let start = Date()
        for i in 0..<count { let topic = corpus[i % corpus.count]; var memory = Memory(id:"\(topic.0)-\(i)",timestamp:Date(timeIntervalSince1970:1792700000+Double(i)),kind:i%4 == 0 ? .audio : .screen,app:["Safari","Xcode","Slack"][i%3],title:topic.1,text:topic.2+"\nSession \(i). Local benchmark fixture."); memory.embedding = embedder.embed(memory.searchableText); memory.embeddingModel = memory.embedding == nil ? nil : embedder.modelID; try store.insert(memory) }
        let ingest = Date().timeIntervalSince(start)
        let queries: [(String,String)] = [("when do we ship OSwind","release"),("save laptop energy during inactivity","battery"),("Italian restaurant reservation","lunch"),("login cookie redirect","auth"),("what did Jamie request","meeting"),("mint typography timeline","design"),("reciprocal rank fusion","vector"),("delete old screenshots and exclude banks","privacy"),("offline speech recognition GPU","audio"),("Acme invoice due","invoice"),("tahini cauliflower recipe","recipe"),("Seattle flight hotel","travel")]
        var modes = [String:Any]()
        for mode in SearchMode.allCases {
            var times = [Double](), recall = 0.0, reciprocal = 0.0
            for _ in 0..<3 { for (query,expected) in queries { let before = Date(); let vector = mode == .keyword ? nil : embedder.embed(query); let hits = try store.search(SearchFilter(query:query,limit:5),mode:mode,vector:vector,modelID:embedder.modelID); times.append(Date().timeIntervalSince(before)*1000); if let rank = hits.firstIndex(where:{$0.id.hasPrefix(expected+"-")}) { recall += 1; reciprocal += 1/Double(rank+1) } } }
            let latency = try BenchmarkLatency(samples:times); let total = Double(queries.count*3)
            modes[mode.rawValue] = ["p50_ms":latency.median,"p95_ms":latency.p95,"max_ms":latency.maximum,"hit_rate_at_5":recall/total,"mrr_at_5":reciprocal/total,"queries":queries.count,"repetitions":3]
        }
        let result: [String:Any] = ["schema":2,"latency_quantiles":BenchmarkLatency.method,"timestamp":ISO8601DateFormatter().string(from:Date()),"os":ProcessInfo.processInfo.operatingSystemVersionString,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "none","records":count,"embedding_model":embedder.modelID,"embeddings_available":embedder.available,"ingest_seconds":ingest,"records_per_second":Double(count)/ingest,"disk_bytes":store.diskBytes(),"modes":modes,"scope":"Synthetic repeated-topic corpus, not a real-user relevance study or a competitor comparison. All vectors scanned for semantic retrieval."]
        if let output { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic) }; try emit(result)
    } else if command == "eval-retrieval" {
        let fixture = option("--fixture") ?? "benchmarks/fixtures/desktop-retrieval-v1.json", output = option("--output")
        var configuration = SearchConfiguration(); if let model = option("--model") { configuration.provider = .ollama; configuration.model = model }; configuration.endpoint = option("--endpoint") ?? configuration.endpoint
        if args.contains("--indexed") { configuration.indexPolicy = .indexed }
        let result = try await RetrievalEvaluation.run(fixture:URL(fileURLWithPath:fixture),configuration:configuration,repetitions:Int(option("--repetitions") ?? "3") ?? 3)
        if let output { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic) }
        try emit(result)
    } else {
        let store = try MemoryStore(root:root), embedder = LocalEmbedder()
        switch command {
        case "routine":
            try emit(await routinesCLI(args,store:store,embedder:embedder))
        case "index-search":
            var settings = AppSettings.load(root:root), configuration = settings.search
            if let model = option("--model") { configuration.provider = .ollama; configuration.model = model }
            configuration.endpoint = option("--endpoint") ?? configuration.endpoint
            let identity: String, dimensions: Int
            if configuration.provider == .ollama { let batch = try await OllamaClient.shared.embed(["search index identity"],configuration:configuration); identity = batch.modelID; dimensions = batch.vectors[0].count }
            else { guard let vector = embedder.embed("search index identity") else { throw OSwindError.unavailable("Apple sentence embeddings are unavailable") }; identity = embedder.modelID; dimensions = vector.count }
            let progress = Task { while !Task.isCancelled { let state = store.searchIndexStatus; FileHandle.standardError.write(Data("\(state.message) · \(state.indexed)/\(state.total)\n".utf8)); try? await Task.sleep(nanoseconds:500_000_000) } }; defer { progress.cancel() }
            let state = try await store.buildSearchIndex(modelID:identity,dimensions:dimensions,rebuild:args.contains("--rebuild"),allowLowPower:configuration.indexOnLowPower)
            if args.contains("--use-index") { configuration.indexPolicy = .indexed; settings.search = configuration; try settings.save(root:root) }
            try encoded(state)
        case "chat":
            let action = args.first ?? "list"; if !args.isEmpty { args.removeFirst() }
            if action == "list" { try encoded(store.chats()) }
            else if action == "new" { try encoded(store.createChat(title:args.isEmpty ? "New conversation" : args.joined(separator:" "))) }
            else {
                guard !args.isEmpty else { throw OSwindError.invalid("Enter a conversation ID") }; let id = args.removeFirst()
                guard let session = try store.chat(id) else { throw OSwindError.invalid("Conversation not found") }
                if action == "show" { try emit(["session":Integration.json(session),"turns":Integration.json(store.chatTurns(id,limit:1000))]) }
                else if action == "delete" { try store.deleteChat(id); print("Deleted conversation") }
                else if action == "export" {
                    guard let path = args.first else { throw OSwindError.invalid("Enter an output path") }
                    let url = URL(fileURLWithPath:path); try ConversationContext.markdown(session,turns:store.chatTurns(id,limit:1000)).write(to:url,atomically:true,encoding:.utf8)
                    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path); print("Exported conversation")
                } else if action == "ask" {
                    let settings = AppSettings.load(root:root); var configuration = settings.ai
                    if let value = try validatedOption("--provider") { guard let provider = AIProvider(rawValue:value) else { throw OSwindError.invalid("Unknown AI provider") }; configuration.provider = provider }
                    configuration.model = try validatedOption("--model") ?? configuration.model; configuration.endpoint = try validatedOption("--endpoint") ?? configuration.endpoint
                    let filter = try searchFilter(), question = settings.privacy.sanitize(args.joined(separator:" ")).text
                    guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw OSwindError.invalid("Enter a question") }
                    let history = ConversationContext.questions(try store.chatTurns(id))
                    let answer = try await AnswerEngine(store:store,embedder:embedder).answer(question,configuration:configuration,filter:filter,searchConfiguration:settings.search,previousQuestions:history,interpretQuery:!literalQuery)
                    try Task.checkCancellation()
                    try encoded(store.appendChatTurn(sessionID:id,question:question,answer:answer,filter:filter,policy:settings.privacy))
                } else { throw OSwindError.invalid("Use chat list, new, show, ask, export or delete") }
            }
        case "models":
            let action = args.first ?? "list"; if !args.isEmpty { args.removeFirst() }; let endpoint = option("--endpoint") ?? AppSettings.load(root:root).search.endpoint
            if action == "list" { try encoded(await OllamaClient.shared.models(endpoint:endpoint)) }
            else if action == "status" { print(try await OllamaClient.shared.runtime(endpoint:endpoint)) }
            else if action == "pull" { guard let name = args.first else { throw OSwindError.invalid("Enter a local model name") }; try await OllamaClient.shared.pull(name,endpoint:endpoint) { state in FileHandle.standardError.write(Data((state.status + (state.fraction.map { " \(Int($0*100))%" } ?? "") + "\n").utf8)) }; print("Download complete") }
            else { throw OSwindError.invalid("Use models list, status or pull NAME") }
        case "reindex":
            var settings = AppSettings.load(root:root), configuration = settings.search
            if let provider = try validatedOption("--provider") { guard let selected = EmbeddingProvider(rawValue:provider) else { throw OSwindError.invalid("Use embedding provider apple or ollama") }; configuration.provider = selected } else { configuration.provider = .ollama }
            configuration.model = try validatedOption("--model") ?? configuration.model; configuration.endpoint = try validatedOption("--endpoint") ?? configuration.endpoint
            try await RetrievalEngine(store:store,apple:embedder).rebuild(configuration:configuration) { state in FileHandle.standardError.write(Data("\(state.indexed)/\(state.total) indexed\n".utf8)) }
            if args.contains("--use-model") { settings.search = configuration; try settings.save(root:root) }
            try emit(store.semanticIndexes())
        case "config": try encoded(AppSettings.load(root:root))
        case "get":
            guard args.count==1 else {throw OSwindError.invalid("Use get MEMORY_ID")}
            guard let memory=try store.get(args[0]) else {throw OSwindError.invalid("Memory not found")}
            try encoded(memory)
        case "stats": try encoded(store.stats())
        case "search": let detail:SearchDetail=args.contains("--preview") ? .preview:.full;args.removeAll {$0=="--preview"};let modeValue = try validatedOption("--mode") ?? "hybrid"; guard let mode = SearchMode(rawValue:modeValue) else { throw OSwindError.invalid("Unknown search mode") }; let details = args.contains("--details"); args.removeAll { $0 == "--details" }; let filter = try searchFilter()
            let result = try await RetrievalEngine(store:store,apple:embedder).search(filter,mode:mode,configuration:AppSettings.load(root:root).search,interpretQuery:!literalQuery,detail:detail)
            if details { try encoded(result) } else {
                if let resolution = result.resolution, !resolution.clauses.isEmpty {
                    let f = resolution.filter
                    func stamp(_ date: Date) throws -> String { try ISOTime.string(date) }
                    let scope = "Scope: \(f.app ?? "all apps"), \(try f.start.map {try stamp($0)} ?? "any start") to before \(try f.end.map {try stamp($0)} ?? "any end"), \(resolution.timeZone)"
                    FileHandle.standardError.write(Data((scope+"\n").utf8))
                }
                for warning in result.warnings { FileHandle.standardError.write(Data((warning+"\n").utf8)) }; try encoded(result.hits) }
        case "ask":
            var configuration = AppSettings.load(root:root).ai
            if let value = try validatedOption("--provider") { guard let provider = AIProvider(rawValue:value) else { throw OSwindError.invalid("Unknown AI provider") }; configuration.provider = provider }
            configuration.model = try validatedOption("--model") ?? configuration.model; configuration.endpoint = try validatedOption("--endpoint") ?? configuration.endpoint
            let filter = try searchFilter(), policy = AppSettings.load(root:root).privacy
            let question = policy.sanitize(args.joined(separator:" ")).text
            guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw OSwindError.invalid("Enter a question") }
            let answer = try await AnswerEngine(store:store,embedder:embedder).answer(question,configuration:configuration,filter:filter,searchConfiguration:AppSettings.load(root:root).search,interpretQuery:!literalQuery)
            try encoded(answer)
        case "note": let text = PrivacyPolicy().sanitize(args.joined(separator:" ")).text; guard !text.isEmpty else { throw OSwindError.invalid("Enter note text") }; var memory = Memory(kind:.note,app:"OSwind",title:"CLI note",text:text); memory.embedding = embedder.embed(memory.searchableText); memory.embeddingModel = embedder.modelID; try store.insert(memory)
            do { _ = try await RetrievalEngine(store:store,apple:embedder).index([memory],configuration:AppSettings.load(root:root).search) }
            catch { FileHandle.standardError.write(Data(("Note saved; additional semantic indexing pending. " + error.localizedDescription + "\n").utf8)) }
            print(memory.id)
        case "export-markdown":
            let media = args.contains("--include-media"); args.removeAll {$0 == "--include-media"}
            guard args.count == 1,!args[0].hasPrefix("--") else { throw OSwindError.invalid("Enter a new output folder and optional --include-media") }
            try encoded(MarkdownExport.create(store:store,destination:URL(fileURLWithPath:args[0]),policy:AppSettings.load(root:root).privacy,includeMedia:media))
        case "export": guard let path = args.first else { throw OSwindError.invalid("Enter an output path") }; try store.exportJSON(to:URL(fileURLWithPath:path)); print("Exported text and metadata")
        case "import": guard let path = args.first else { throw OSwindError.invalid("Enter an import path") }; print(try store.importJSON(from:URL(fileURLWithPath:path),embedder:embedder,policy:AppSettings.load(root:root).privacy))
        case "delete": guard let id = args.first else { throw OSwindError.invalid("Enter a memory id") }; try store.delete(id); print("Deleted")
        case "prune": let days = Int(option("--days") ?? "30") ?? 30; let gb = Int64(option("--max-gb") ?? "20") ?? 20; guard days > 0 && gb > 0 else { throw OSwindError.invalid("Retention and budget must be positive") }; print(try store.prune(before:Date().addingTimeInterval(-Double(days)*86400),maxBytes:gb*1_000_000_000))
        case "capture-replay":
            let bundle=try validatedOption("--app-bundle"),duration=try validatedOption("--seconds")
            guard let duration,let seconds=Double(duration),args.isEmpty else {throw OSwindError.invalid("Use capture-replay --seconds 1..120 [--app-bundle ID]")}
            let controller=CaptureController(store:store,embedder:embedder,settings:AppSettings.load(root:root))
            try await controller.captureReplay(seconds:seconds,targetBundleID:bundle)
            try emit(["status":controller.status,"saved":controller.metrics.saved,"errors":controller.metrics.errors])
        case "capture": let bundle = option("--app-bundle"); let controller = CaptureController(store:store,embedder:embedder,settings:AppSettings.load(root:root)); await controller.captureOnce(manual:true,targetBundleID:bundle); print(controller.status)
        case "import-audio":
            var settings=AppSettings.load(root:root)
            let whisperOverride=try validatedOption("--model"), nativeOverride=try validatedOption("--native-model"), computeOverride=try validatedOption("--compute")
            if let model=whisperOverride { settings.whisperModel=model }
            if let engine=try validatedOption("--engine") { guard let value=SpeechEngine(rawValue:engine) else { throw OSwindError.invalid("Use --engine whisper or parakeet") }; settings.speech.engine=value }
            if let directory=nativeOverride { settings.speech.modelDirectory=directory }
            if let compute=computeOverride { guard let value=SpeechCompute(rawValue:compute) else { throw OSwindError.invalid("Use --compute neuralEngine, gpu or cpu") }; settings.speech.compute=value }
            if settings.speech.engine == .whisper && (nativeOverride != nil || computeOverride != nil) { throw OSwindError.invalid("Native model/compute options require the Parakeet engine") }
            if settings.speech.engine == .parakeet && whisperOverride != nil { throw OSwindError.invalid("--model applies to Whisper; use --native-model for Parakeet") }
            let diarize=args.contains("--diarize"),noDiarize=args.contains("--no-diarize")
            guard !(diarize && noDiarize) else { throw OSwindError.invalid("Choose --diarize or --no-diarize") }
            args.removeAll { $0=="--diarize" || $0=="--no-diarize" }
            if let directory=try validatedOption("--speaker-model") { settings.diarization.modelDirectory=directory; settings.diarization.enabled=true }
            if diarize { settings.diarization.enabled=true }; if noDiarize { settings.diarization.enabled=false }
            if settings.diarization.enabled {
                guard SpeakerDiarizer.supported else { throw OSwindError.unavailable("Speaker labels require macOS 15 or later") }
                _ = try settings.diarization.localDirectory()
            }
            let retain=args.contains("--retain-audio"); args.removeAll { $0=="--retain-audio" }; guard args.count==1 else { throw OSwindError.invalid("Use import-audio PATH [--engine whisper|parakeet] [--model PATH] [--native-model DIRECTORY] [--compute neuralEngine|gpu|cpu] [--diarize --speaker-model DIRECTORY] [--retain-audio]") }
            let file=URL(fileURLWithPath:args[0]), clip=try await AudioClipSnapshot.prepare(file); defer { withExtendedLifetime(clip) {} }
            var transcript=try await SpeechRecognizer().transcribe(file:clip.speechFile,settings:settings,timeout:1800)
            transcript.duration=clip.duration
            if settings.diarization.enabled { transcript=try await SpeakerDiarizer().annotate(transcript,file:clip.speechFile,configuration:settings.diarization) }
            var admission=settings; admission.retainAudio=retain
            let memory=try AudioAdmission.save(transcript,file:clip.file,store:store,settings:admission,timestamp:Date(),source:"Imported audio",title:file.deletingPathExtension().lastPathComponent,sessionID:UUID().uuidString,recordedLive:false,embedder:embedder)
            do { _ = try await RetrievalEngine(store:store,apple:embedder).index([memory],configuration:settings.search) } catch { FileHandle.standardError.write(Data("Transcript saved; additional indexing pending.\n".utf8)) }
            try encoded(memory)
        case "name-speaker":
            guard let from=try validatedOption("--from"),let name=try validatedOption("--name"),args.count==1 else { throw OSwindError.invalid("Use name-speaker MEMORY_ID --from SPEAKER_LABEL --name NAME") }
            try encoded(store.renameAudioSpeaker(args[0],from:from,to:name,policy:AppSettings.load(root:root).privacy))
        case "transcribe": let settings = AppSettings.load(root:root); let model = option("--model") ?? settings.whisperModel; guard let path = args.first else { throw OSwindError.invalid("Enter an audio file path") }; print(try await Whisper.transcribe(file:URL(fileURLWithPath:path),binary:settings.whisperBinary,model:model,language:settings.transcriptionLanguage))
        case "serve": let server = try LocalAPIServer(store:store,embedder:embedder); server.onState = { print($0); fflush(stdout) }; try server.start(); print("Token file: \(store.root.appendingPathComponent("api-token").path)"); while true { try await Task.sleep(nanoseconds:1_000_000_000) }
        case "mcp":
            while let line = readLine() { do { guard line.utf8.count <= 1_000_000, let request = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { throw OSwindError.invalid("Invalid JSON-RPC") }; if let response = await Integration.rpc(request,store:store,embedder:embedder) { let data = try JSONSerialization.data(withJSONObject:response,options:.sortedKeys); print(String(data:data,encoding:.utf8)!); fflush(stdout) } } catch { print("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}"); fflush(stdout) } }
        default: throw OSwindError.invalid("Unknown command \(command). Run oswindctl help.")
        }
    }
} catch is CancellationError { FileHandle.standardError.write(Data("Backup cancelled.\n".utf8)); exit(130) }
catch { FileHandle.standardError.write(Data(("OSwind: " + error.localizedDescription + "\n").utf8)); exit(1) }
