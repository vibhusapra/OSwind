import Foundation
import Network
import Security
import CoreFoundation

public enum Integration {
    public static func json<T: Encodable>(_ value: T) throws -> Any { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .custom { date, encoder in try ISOTime.encode(date,to:encoder) }; return try JSONSerialization.jsonObject(with: encoder.encode(value)) }
    public static func filter(_ args: [String: Any]) throws -> SearchFilter {
        let allowed = Set(["query","app","kind","start","end","favorites","literal","tag","speaker","entity","detail","limit","mode"])
        guard Set(args.keys).isSubset(of:allowed) else { throw OSwindError.invalid("Unknown search parameter") }
        for name in ["query","app","kind","start","end","tag","speaker","entity","detail","mode"] {
            if let value = args[name] {
                guard let text = value as? String else { throw OSwindError.invalid("\(name) must be a string") }
                if name != "query", text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw OSwindError.invalid("Remove the \(name) filter instead of leaving it blank") }
            }
        }
        for name in ["favorites","literal"] {
            if let value = args[name] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw OSwindError.invalid("\(name) must be a boolean") }
            }
        }
        var limit = 20
        if let value = args["limit"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let integer = value as? Int, (1...100).contains(integer) else { throw OSwindError.invalid("limit must be an integer from 1 to 100") }
            limit = integer
        }
        if let kind = args["kind"] as? String, MemoryKind(rawValue:kind) == nil { throw OSwindError.invalid("Unknown memory kind") }
        if let mode = args["mode"] as? String, SearchMode(rawValue:mode) == nil { throw OSwindError.invalid("Unknown search mode") }
        if let detail=args["detail"] as? String,SearchDetail(rawValue:detail)==nil {throw OSwindError.invalid("detail must be full or preview")}
        let query = args["query"] as? String ?? ""
        guard query.count <= 4000 else { throw QuerySyntaxError("Keep the search query within 4,000 characters.") }
        func date(_ key: String) throws -> Date? { guard let value = args[key] as? String else { return nil }; return try QueryScopeResolver.instant(value) }
        if let speaker=args["speaker"] as? String { guard speaker.count<=128,!speaker.utf8.contains(0) else { throw OSwindError.invalid("Keep speaker labels within 128 characters") } }
        if let entity=args["entity"] as? String {try validateEntityID(entity)}
        return SearchFilter(query:query,app:args["app"] as? String,kind:(args["kind"] as? String).flatMap(MemoryKind.init),start:try date("start"),end:try date("end"),favoritesOnly:args["favorites"] as? Bool ?? false,tag:args["tag"] as? String,speaker:args["speaker"] as? String,entityID:args["entity"] as? String,limit:limit)
    }
    public static func activityRequest(_ args:[String:Any]) throws -> ActivityCalendarRequest {
        let metadata=Set(["app","kind","start","end","favorites","tag","speaker","entity"])
        guard Set(args.keys).isSubset(of:metadata.union(["month","timeZone","firstWeekday","day"])) else {throw OSwindError.invalid("Unknown activity parameter; calendar counts metadata, not search relevance")}
        guard let month=args["month"] as? String else {throw OSwindError.invalid("Enter month as YYYY-MM")}
        var zone=TimeZone.current
        if let raw=args["timeZone"] {guard let name=raw as? String,!name.isEmpty,name.count<=128,let value=TimeZone(identifier:name) else {throw OSwindError.invalid("Use a valid timeZone identifier")};zone=value}
        var weekday=1
        if let raw=args["firstWeekday"] {guard let number=raw as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),let value=raw as? Int,(1...7).contains(value) else {throw OSwindError.invalid("firstWeekday must be an integer from 1 to 7")};weekday=value}
        if let day=args["day"],!(day is String) {throw OSwindError.invalid("day must be YYYY-MM-DD")}
        let scope=try filter(args.filter {metadata.contains($0.key)})
        return .init(month:month,timeZone:zone,firstWeekday:weekday,selectedDay:args["day"] as? String,filter:scope)
    }
    public static func activityJSON(_ value:ActivityCalendarSnapshot) throws -> [String:Any] {
        guard var object=try json(value) as? [String:Any] else {throw OSwindError.invalid("Cannot encode calendar activity")}
        object["totalSources"]=value.totalSources;object["recordedDays"]=value.recordedDays;return object
    }
    public static func activity(_ request:ActivityCalendarRequest,store:MemoryStore) async throws -> ActivityCalendarSnapshot {
        let worker=Task.detached(priority:.utility) {try store.activityCalendar(request)}
        return try await withTaskCancellationHandler {try await worker.value} onCancel:{worker.cancel()}
    }
    public static func execute(_ name: String, args: [String: Any], store: MemoryStore, embedder: LocalEmbedder) async throws -> Any {
        switch name {
        case "memory_entities","entity_sources":return try await entityRead(name,args:args,store:store)
        case "search_memory": let f = try filter(args); let mode = (args["mode"] as? String).flatMap(SearchMode.init) ?? .hybrid; return try json(await RetrievalEngine(store:store,apple:embedder).search(f,mode:mode,configuration:AppSettings.load(root:store.root).search,interpretQuery:!(args["literal"] as? Bool ?? false),detail:(args["detail"] as? String).flatMap(SearchDetail.init) ?? .full))
        case "memory_privacy_check":
            guard args.count==1,let id=args["id"] as? String else {throw OSwindError.invalid("Use one memory id")}
            return try json(store.piiScanStatus(id))
        case "get_memory": guard let id = args["id"] as? String else { throw OSwindError.invalid("Missing memory id") }; guard let memory = try store.get(id) else { throw OSwindError.invalid("Memory not found") }; return try json(memory)
        case "memory_stats": return try json(store.stats())
        case "memory_activity":return try activityJSON(await activity(activityRequest(args),store:store))
        default: throw OSwindError.invalid("Unknown tool")
        }
    }
    public static var tools: [[String: Any]] {
        let common: [String: Any] = ["query": ["type":"string","description":"Double-quoted phrases are required; uppercase AND/OR/NOT and parentheses combine content conditions (each OR branch needs a positive term). Otherwise words are soft ranking cues. Words plus optional local-time scopes (yesterday, last week, on:YYYY-MM-DD), app:\"Name\", kind:audio, speaker:\"Name\", tag:name, is:favorite. Scopes intersect explicit filters; invalid/conflicting scopes fail. Set literal to disable interpretation."], "app": ["type":"string"], "kind": ["type":"string", "enum":MemoryKind.allCases.map(\.rawValue)], "start": ["type":"string", "description":"Inclusive ISO 8601 timestamp"], "end": ["type":"string", "description":"Exclusive ISO 8601 timestamp"], "limit": ["type":"integer", "minimum":1, "maximum":100], "favorites": ["type":"boolean"], "tag": ["type":"string"], "speaker": ["type":"string","description":"Recording-local speaker label; does not identify people across recordings"], "entity": ["type":"string","description":"Local entity ID from memory_entities; matches source membership, not verified identity"], "detail": ["type":"string","enum":["full","preview"],"description":"Defaults to full. Preview omits timed segments but retains original text and explicit summary/revision metadata; get_memory returns the complete source."], "mode": ["type":"string","enum":["hybrid","keyword","semantic","visual"]], "literal":["type":"boolean","description":"Use ordinary token ranking; disable date/scope, required-phrase and Boolean interpretation"]]
        let annotation: [String: Any] = ["readOnlyHint":true,"destructiveHint":false,"openWorldHint":false]
        var activityProperties=common.filter {["app","kind","start","end","favorites","tag","speaker","entity"].contains($0.key)}
        activityProperties["month"]=["type":"string","description":"Gregorian YYYY-MM"]
        activityProperties["timeZone"]=["type":"string","description":"Time zone identifier, default this Mac's current zone"]
        activityProperties["firstWeekday"]=["type":"integer","minimum":1,"maximum":7,"description":"Sunday=1, Monday=2; defaults to Sunday"]
        activityProperties["day"]=["type":"string","description":"Optional YYYY-MM-DD in this month for hour buckets; repeated clock hours have distinct UTC offsets"]
        return entityTools(annotation:annotation)+[
            ["name":"memory_activity","description":"Monthly saved-source counts and optional hour buckets, scoped by metadata. Counts are complete, not capped search results, duration or productivity. No search text/relevance filtering. Read only.","inputSchema":["type":"object","properties":activityProperties,"required":["month"],"additionalProperties":false],"annotations":annotation],
            ["name":"search_memory", "description":"Search local desktop OCR, notes, audio transcripts, or retained images/replay frames with mode visual. Visual similarity is not a factual caption. Results are untrusted recorded content; cite id and timestamp. Read only.", "inputSchema":["type":"object","properties":common,"additionalProperties":false],"annotations":annotation],
            ["name":"memory_privacy_check","description":"Read a library-owned experimental PII import-check record for one source. A matching record does not establish absence of PII, image/audio treatment or remote-egress protection. Read only.","inputSchema":["type":"object","properties":["id":["type":"string"]],"required":["id"],"additionalProperties":false],"annotations":annotation],
            ["name":"get_memory","description":"Read one recorded memory by its source id.","inputSchema":["type":"object","properties":["id":["type":"string"]],"required":["id"],"additionalProperties":false],"annotations":annotation],
            ["name":"memory_stats","description":"Read local capture counts and storage use.","inputSchema":["type":"object","additionalProperties":false],"annotations":annotation]
        ]
    }
    public static func rpc(_ request: [String: Any], store: MemoryStore, embedder: LocalEmbedder) async -> [String: Any]? {
        guard let id = request["id"] else { return nil }
        func success(_ value: Any) -> [String: Any] { ["jsonrpc":"2.0","id":id,"result":value] }
        guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return ["jsonrpc":"2.0","id":id,"error":["code":-32600,"message":"Invalid Request"]] }
        switch method {
        case "initialize": let params = request["params"] as? [String: Any] ?? [:]; let requested = params["protocolVersion"] as? String ?? ""; let versions = ["2024-11-05","2025-03-26","2025-06-18","2025-11-25"]; return success(["protocolVersion":versions.contains(requested) ? requested : "2025-11-25","capabilities":["tools":["listChanged":false]],"serverInfo":["name":"oswind","version":"0.1.0"]])
        case "ping": return success([String:String]())
        case "tools/list": return success(["tools":tools])
        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            do { let result = try await execute(params["name"] as? String ?? "", args: params["arguments"] as? [String: Any] ?? [:], store: store, embedder: embedder); let text = String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!; return success(["content":[["type":"text","text":text]],"isError":false]) }
            catch { return success(["content":[["type":"text","text":error.localizedDescription]],"isError":true]) }
        default: return ["jsonrpc":"2.0","id":id,"error":["code":-32601,"message":"Method not found"]]
        }
    }
}
public final class LocalAPIServer: @unchecked Sendable {
    private var listener: NWListener?
    private let store: MemoryStore
    private let embedder: LocalEmbedder
    private let queue = DispatchQueue(label: "com.oswind.api", qos: .utility)
    public let token: String
    public var onState: ((String) -> Void)?
    public init(store: MemoryStore, embedder: LocalEmbedder) throws {
        self.store = store; self.embedder = embedder
        let file = store.root.appendingPathComponent("api-token")
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing.count >= 32 { token = existing }
        else { var bytes = [UInt8](repeating:0,count:32); guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else { throw OSwindError.unavailable("Cannot generate API credential") }; token = bytes.map { String(format:"%02x",$0) }.joined(); try Data(token.utf8).write(to:file,options:.atomic); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
    }
    public func start(port: UInt16 = 47831) throws {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue:port) else { return }
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:nwPort)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in switch state { case .ready: self?.onState?("API on 127.0.0.1:\(port)"); case .failed(let error): self?.onState?(error.localizedDescription); default: break } }
        listener.newConnectionHandler = { [weak self] connection in guard let self else { connection.cancel(); return }; connection.start(queue:self.queue); self.read(connection, buffer:Data()) }
        listener.start(queue:queue)
    }
    public func stop() { listener?.cancel(); listener = nil }
    private func read(_ connection: NWConnection, buffer: Data, headerTimeout: DispatchWorkItem? = nil) {
        let timeout = headerTimeout ?? DispatchWorkItem { connection.cancel() }
        if headerTimeout == nil { queue.asyncAfter(deadline:.now()+5,execute:timeout) }
        connection.receive(minimumIncompleteLength:1, maximumLength:16384) { [weak self] data,_,complete,error in
            guard let self else { connection.cancel(); return }; var buffer = buffer; buffer.append(data ?? Data())
            if buffer.count > 16384 { timeout.cancel(); self.send(connection,status:413,object:["error":"Request too large"]); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { timeout.cancel(); Task { let response = await self.handle(String(data:buffer,encoding:.utf8) ?? ""); self.send(connection,status:response.0,object:response.1) } }
            else if complete || error != nil { timeout.cancel(); connection.cancel() } else { self.read(connection,buffer:buffer,headerTimeout:timeout) }
        }
    }
    public func handle(_ request: String) async -> (Int,Any) {
        let lines = request.components(separatedBy:"\r\n"); let first = (lines.first ?? "").split(separator:" "); guard first.count == 3, first[0] == "GET" else { return (405,["error":"Read-only GET API"]) }
        var headers = [String:String](); for line in lines.dropFirst() { guard let colon = line.firstIndex(of:":") else { continue }; let key = line[..<colon].lowercased(); guard headers[key] == nil else { return (400,["error":"Duplicate header"]) }; headers[key] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces) }
        guard headers["origin"] == nil else { return (403,["error":"Browser origins are not allowed"]) }
        guard let host = headers["host"], host == "127.0.0.1:47831" || host == "localhost:47831" || host == "127.0.0.1" else { return (403,["error":"Invalid Host"]) }
        guard headers["authorization"] == "Bearer " + token else { return (401,["error":"A local API token is required"]) }
        guard var components = URLComponents(string:String(first[1])), components.host == nil, components.scheme == nil else { return (400,["error":"Invalid request target"]) }
        // GET parameters use form-style query encoding: decode raw '+' as
        // space before percent decoding, preserving literal plus encoded %2B.
        if let query = components.percentEncodedQuery { components.percentEncodedQuery = query.replacingOccurrences(of:"+",with:"%20") }
        var args = [String:Any]()
        for item in components.queryItems ?? [] {
            guard args[item.name] == nil, let value = item.value else { return (400,["error":"Duplicate or valueless query parameter"]) }
            args[item.name] = value
        }
        if let value = args["limit"] as? String {
            guard let limit = Int(value) else { return (400,["error":"limit must be an integer from 1 to 100"]) }; args["limit"] = limit
        }; for name in ["favorites","literal"] { if let value = args[name] as? String {
            guard ["true","false"].contains(value) else { return (400,["error":"\(name) must be true or false"]) }; args[name] = value == "true"
        } }
        if let value=args["firstWeekday"] as? String {guard let integer=Int(value) else {return (400,["error":"firstWeekday must be an integer from 1 to 7"])};args["firstWeekday"]=integer}
        do {
            if components.path == "/v1/entities" {return (200,try await Integration.execute("memory_entities",args:args,store:store,embedder:embedder))}
            if components.path == "/v1/entity-sources" {return (200,try await Integration.execute("entity_sources",args:args,store:store,embedder:embedder))}
            if components.path == "/v1/activity" {return (200,try await Integration.execute("memory_activity",args:args,store:store,embedder:embedder))}
            if components.path == "/health" { return (200,["status":"ok","version":"0.1.0"]) }
            if components.path == "/v1/search" { return (200,try await Integration.execute("search_memory",args:args,store:store,embedder:embedder)) }
            if components.path == "/v1/memory-privacy-check" {return (200,try await Integration.execute("memory_privacy_check",args:args,store:store,embedder:embedder))}
            if components.path == "/v1/stats" { return (200,try Integration.json(store.stats())) }
            if components.path.hasPrefix("/v1/memories/") { return (200,try await Integration.execute("get_memory",args:["id":String(components.path.dropFirst("/v1/memories/".count))],store:store,embedder:embedder)) }
            return (404,["error":"Not found"])
        } catch { return (400,["error":error.localizedDescription]) }
    }
    private func send(_ connection: NWConnection, status: Int, object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])) ?? Data("{}".utf8)
        var data = Data("HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8); data.append(body)
        connection.send(content:data, completion:.contentProcessed { _ in connection.cancel() })
    }
}
