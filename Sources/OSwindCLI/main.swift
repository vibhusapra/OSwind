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
func emit(_ object: Any) throws { let data = try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]); print(String(data:data,encoding:.utf8)!) }
func encoded<T: Encodable>(_ object: T) throws { try emit(Integration.json(object)) }
func searchFilter() throws -> SearchFilter { var values = [String:Any](); for (flag,name) in [("--app","app"),("--kind","kind"),("--from","start"),("--to","end"),("--tag","tag")] { if let value = option(flag) { values[name] = value } }; values["limit"] = Int(option("--limit") ?? "20") ?? 20; values["favorites"] = args.contains("--favorites"); args.removeAll {$0 == "--favorites" || $0 == "--json"}; values["query"] = args.joined(separator:" "); return try Integration.filter(values) }
do {
    if command == "help" || command == "--help" {
        print("""
        OSwind 0.1.0 · local desktop memory
        Usage: oswindctl [--data DIRECTORY] COMMAND
          doctor                         Inspect local permissions, GPU and models
          search [--mode hybrid|keyword|semantic] [--app APP] [--kind KIND]
                 [--from ISO8601] [--to ISO8601] [--limit N] WORDS
          ask [--provider evidence|apple|ollama|compatible|anthropic] QUESTION
          chat list|new|show ID|delete ID  Manage saved local conversations
          chat ask ID [--provider NAME] QUESTION  Recheck sources for a follow-up
          chat export ID PATH            Export a conversation to Markdown
          note TEXT                      Save a redacted, searchable note
          stats                          Storage and capture counts
          config                         Print settings (no API keys)
          models list|status|pull NAME    Inspect/download local Ollama models
          reindex [--model NAME] [--use-model]  Build/resume local GPU search vectors
          index-search [--model NAME] [--rebuild] [--use-index]  Prepare fast local retrieval
          eval-retrieval [--model NAME]   Evaluate the diverse relevance fixture
          export PATH                    Export text and metadata JSON
          import PATH                    Import OSwind JSON, redact, rebuild vectors
          delete ID                      Delete one memory and its media
          prune [--days N] [--max-gb N]   Apply retention
          capture [--app-bundle ID]      Capture a chosen/current window once
          transcribe FILE --model PATH   Local whisper.cpp transcription
          serve                          Read-only token-auth API at 127.0.0.1:47831
          mcp                            Read-only MCP over stdio
          benchmark [--count N]          Isolated synthetic retrieval benchmark
          benchmark-vectors [--count N] [--dimensions N]  Vector scaling / optional --indexed --quality-queries N
        No cloud model is used unless explicitly configured. BYOK keys are read
        from Keychain; use the app's Models settings to configure them.
        """)
    } else if command == "doctor" {
        let settings = AppSettings.load(root:root); let embedder = LocalEmbedder()
        var result: [String:Any] = ["version":"0.1.0","os":ProcessInfo.processInfo.operatingSystemVersionString,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "unavailable","screenRecording":CGPreflightScreenCaptureAccess(),"screenLocked":SessionState.locked,"accessibility":AXIsProcessTrusted(),"sentenceEmbeddings":embedder.available,"dataDirectory":root.path,"whisperExecutable":FileManager.default.isExecutableFile(atPath:settings.whisperBinary),"whisperModel":FileManager.default.fileExists(atPath:settings.whisperModel),"provider":settings.ai.provider.rawValue]
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { result["appleIntelligence"] = SystemLanguageModel.default.isAvailable }
        #endif
        try emit(result)
    } else if command == "benchmark-vectors" {
        let count = Int(option("--count") ?? "10000") ?? 10000, dimensions = Int(option("--dimensions") ?? "1024") ?? 1024, repetitions = Int(option("--repetitions") ?? "3") ?? 3, output = option("--output")
        let archive = option("--archive").map { URL(fileURLWithPath:$0) }
        let result = try await VectorScalingEvaluation.run(count:count,dimensions:dimensions,repetitions:repetitions,indexed:args.contains("--indexed"),archive:archive,qualityQueries:Int(option("--quality-queries") ?? "0") ?? 0)
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
            times.sort(); let total = Double(queries.count*3)
            modes[mode.rawValue] = ["p50_ms":times[times.count/2],"p95_ms":times[Int(Double(times.count-1)*0.95)],"hit_rate_at_5":recall/total,"mrr_at_5":reciprocal/total,"queries":queries.count,"repetitions":3]
        }
        let result: [String:Any] = ["schema":1,"timestamp":ISO8601DateFormatter().string(from:Date()),"os":ProcessInfo.processInfo.operatingSystemVersionString,"gpu":MTLCreateSystemDefaultDevice()?.name ?? "none","records":count,"embedding_model":embedder.modelID,"embeddings_available":embedder.available,"ingest_seconds":ingest,"records_per_second":Double(count)/ingest,"disk_bytes":store.diskBytes(),"modes":modes,"scope":"Synthetic repeated-topic corpus, not a real-user relevance study or a competitor comparison. All vectors scanned for semantic retrieval."]
        if let output { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic) }; try emit(result)
    } else {
        let store = try MemoryStore(root:root), embedder = LocalEmbedder()
        switch command {
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
                    if let value = option("--provider"), let provider = AIProvider(rawValue:value) { configuration.provider = provider }
                    let filter = try searchFilter(), question = settings.privacy.sanitize(args.joined(separator:" ")).text
                    guard !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw OSwindError.invalid("Enter a question") }
                    let history = ConversationContext.questions(try store.chatTurns(id))
                    let answer = try await AnswerEngine(store:store,embedder:embedder).answer(question,configuration:configuration,filter:filter,searchConfiguration:settings.search,previousQuestions:history)
                    try Task.checkCancellation()
                    try encoded(store.appendChatTurn(sessionID:id,question:question,answer:answer,filter:filter,policy:settings.privacy))
                } else { throw OSwindError.invalid("Use chat list, new, show, ask, export or delete") }
            }
        case "eval-retrieval":
            let fixture = option("--fixture") ?? "benchmarks/fixtures/desktop-retrieval-v1.json", output = option("--output")
            var configuration = SearchConfiguration(); if let model = option("--model") { configuration.provider = .ollama; configuration.model = model }; configuration.endpoint = option("--endpoint") ?? configuration.endpoint
            if args.contains("--indexed") { configuration.indexPolicy = .indexed }
            let result = try await RetrievalEvaluation.run(fixture:URL(fileURLWithPath:fixture),configuration:configuration,repetitions:Int(option("--repetitions") ?? "3") ?? 3)
            if let output { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic) }
            try emit(result)
        case "models":
            let action = args.first ?? "list"; if !args.isEmpty { args.removeFirst() }; let endpoint = option("--endpoint") ?? AppSettings.load(root:root).search.endpoint
            if action == "list" { try encoded(await OllamaClient.shared.models(endpoint:endpoint)) }
            else if action == "status" { print(try await OllamaClient.shared.runtime(endpoint:endpoint)) }
            else if action == "pull" { guard let name = args.first else { throw OSwindError.invalid("Enter a local model name") }; try await OllamaClient.shared.pull(name,endpoint:endpoint) { state in FileHandle.standardError.write(Data((state.status + (state.fraction.map { " \(Int($0*100))%" } ?? "") + "\n").utf8)) }; print("Download complete") }
            else { throw OSwindError.invalid("Use models list, status or pull NAME") }
        case "reindex":
            var settings = AppSettings.load(root:root), configuration = settings.search; configuration.provider = .ollama
            configuration.model = option("--model") ?? configuration.model; configuration.endpoint = option("--endpoint") ?? configuration.endpoint
            try await RetrievalEngine(store:store,apple:embedder).rebuild(configuration:configuration) { state in FileHandle.standardError.write(Data("\(state.indexed)/\(state.total) indexed\n".utf8)) }
            if args.contains("--use-model") { settings.search = configuration; try settings.save(root:root) }
            try emit(store.semanticIndexes())
        case "config": try encoded(AppSettings.load(root:root))
        case "stats": try encoded(store.stats())
        case "search": let mode = SearchMode(rawValue:option("--mode") ?? "hybrid") ?? .hybrid; let details = args.contains("--details"); args.removeAll { $0 == "--details" }; let filter = try searchFilter()
            let result = try await RetrievalEngine(store:store,apple:embedder).search(filter,mode:mode,configuration:AppSettings.load(root:root).search)
            if details { try encoded(result) } else { for warning in result.warnings { FileHandle.standardError.write(Data((warning+"\n").utf8)) }; try encoded(result.hits) }
        case "ask": var configuration = AppSettings.load(root:root).ai; if let p = option("--provider"), let provider = AIProvider(rawValue:p) { configuration.provider = provider }; let answer = try await AnswerEngine(store:store,embedder:embedder).answer(args.joined(separator:" "),configuration:configuration,searchConfiguration:AppSettings.load(root:root).search); try encoded(answer)
        case "note": let text = PrivacyPolicy().sanitize(args.joined(separator:" ")).text; guard !text.isEmpty else { throw OSwindError.invalid("Enter note text") }; var memory = Memory(kind:.note,app:"OSwind",title:"CLI note",text:text); memory.embedding = embedder.embed(memory.searchableText); memory.embeddingModel = embedder.modelID; try store.insert(memory); print(memory.id)
        case "export": guard let path = args.first else { throw OSwindError.invalid("Enter an output path") }; try store.exportJSON(to:URL(fileURLWithPath:path)); print("Exported text and metadata")
        case "import": guard let path = args.first else { throw OSwindError.invalid("Enter an import path") }; print(try store.importJSON(from:URL(fileURLWithPath:path),embedder:embedder,policy:AppSettings.load(root:root).privacy))
        case "delete": guard let id = args.first else { throw OSwindError.invalid("Enter a memory id") }; try store.delete(id); print("Deleted")
        case "prune": let days = Int(option("--days") ?? "30") ?? 30; let gb = Int64(option("--max-gb") ?? "20") ?? 20; guard days > 0 && gb > 0 else { throw OSwindError.invalid("Retention and budget must be positive") }; print(try store.prune(before:Date().addingTimeInterval(-Double(days)*86400),maxBytes:gb*1_000_000_000))
        case "capture": let bundle = option("--app-bundle"); let controller = CaptureController(store:store,embedder:embedder,settings:AppSettings.load(root:root)); await controller.captureOnce(manual:true,targetBundleID:bundle); print(controller.status)
        case "transcribe": let settings = AppSettings.load(root:root); let model = option("--model") ?? settings.whisperModel; guard let path = args.first else { throw OSwindError.invalid("Enter an audio file path") }; print(try await Whisper.transcribe(file:URL(fileURLWithPath:path),binary:settings.whisperBinary,model:model,language:settings.transcriptionLanguage))
        case "serve": let server = try LocalAPIServer(store:store,embedder:embedder); server.onState = { print($0); fflush(stdout) }; try server.start(); print("Token file: \(store.root.appendingPathComponent("api-token").path)"); while true { try await Task.sleep(nanoseconds:1_000_000_000) }
        case "mcp":
            while let line = readLine() { do { guard line.utf8.count <= 1_000_000, let request = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { throw OSwindError.invalid("Invalid JSON-RPC") }; if let response = await Integration.rpc(request,store:store,embedder:embedder) { let data = try JSONSerialization.data(withJSONObject:response,options:.sortedKeys); print(String(data:data,encoding:.utf8)!); fflush(stdout) } } catch { print("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}"); fflush(stdout) } }
        default: throw OSwindError.invalid("Unknown command \(command). Run oswindctl help.")
        }
    }
} catch { FileHandle.standardError.write(Data(("OSwind: " + error.localizedDescription + "\n").utf8)); exit(1) }
