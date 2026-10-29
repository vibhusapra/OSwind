import Foundation

public struct PrivacyPolicy: Codable, Equatable, Sendable {
    public var excludedApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Passwords", "com.bitwarden.desktop"]
    public var excludedDomains = ["accounts.google.com", "bankofamerica.com", "chase.com", "1password.com"]
    public var excludedTitles = ["private browsing", "incognito", "private window"]
    public var redactSecrets = true
    public var retainImages = true
    public var retentionDays = 30
    public var maxStorageGB = 20
    public var requireBrowserContext = true
    public init() {}
    private static func hostKey(_ value:String)->String {
        value.lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
    }
    private static func domainKey(_ value:String)->String? {
        let value=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        // Common hostname rules need no second URL parse on the capture/search
        // hot path. IDNA, escapes and IP literals use Foundation below.
        if !value.isEmpty,value.utf8.allSatisfy({(97...122).contains($0) || (48...57).contains($0) || [45,46,95].contains($0)}) {
            let key=hostKey(value);return key.isEmpty ? nil:key
        }
        guard !value.isEmpty,let components=URLComponents(string:"https://"+value),components.user==nil,components.password==nil,components.port==nil,
              components.path.isEmpty,components.query==nil,components.fragment==nil,let host=components.url?.host else {return nil}
        let key=hostKey(host);return key.isEmpty ? nil:key
    }
    func excludesApplication(_ app:String)->Bool {excludedApps.contains {app.caseInsensitiveCompare($0) == .orderedSame}}
    public func exclusion(app: String, title: String, url: String?, isBrowser: Bool = false) -> String? {
        if excludesApplication(app) { return "Excluded application" }
        if excludedTitles.contains(where: { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }) { return "Excluded window" }
        let parsed=url.flatMap {URL(string:$0)},host=parsed?.host.map(Self.hostKey)
        let webContext=["http","https"].contains(parsed?.scheme?.lowercased() ?? "") && !(host ?? "").isEmpty
        if isBrowser && requireBrowserContext && !excludedDomains.isEmpty && !webContext { return "Browser URL unavailable; privacy rules require context" }
        if let host,excludedDomains.contains(where:{value in guard let domain=Self.domainKey(value) else {return false};return host==domain || host.hasSuffix("."+domain)}) {return "Excluded website"}
        return nil
    }
    public func sanitize(_ text: String) -> (text: String, redacted: Bool) {
        let ranges=sensitiveRanges(in:text)
        guard !ranges.isEmpty else {return (text,false)}
        let original=text as NSString
        // Every detector sees the original text. An earlier key match must
        // never erase the trigger needed to recognize a later secret value.
        let masks=ranges.map {original.rangeOfComposedCharacterSequences(for:$0)}.sorted {$0.location<$1.location}
        var merged=[NSRange]();merged.reserveCapacity(masks.count)
        for range in masks {
            if let previous=merged.last,range.location<=NSMaxRange(previous) {
                merged[merged.count-1]=NSRange(location:previous.location,length:max(NSMaxRange(previous),NSMaxRange(range))-previous.location)
            } else {merged.append(range)}
        }
        let output=NSMutableString(string:text)
        for range in merged.reversed() {output.replaceCharacters(in:range,with:"[REDACTED]")}
        return (output as String,true)
    }
    /// Production and explicit learned inspection use the same original-source
    /// pattern matches; neither evaluates patterns against already-masked text.
    func sensitiveRanges(in text:String)->[NSRange] {
        guard redactSecrets else {return []}
        let range=NSRange(text.startIndex...,in:text)
        return Self.secretDetectors.flatMap {$0.matches(in:text,range:range).map(\.range)}
    }
    // These fixed program literals must compile. Do not silently drop a
    // detector on a developer error. Instances are immutable and shared;
    // matching sources and replacement buffers remain local to each call.
    private static let secretDetectors=secretPatterns.map {try! NSRegularExpression(pattern:$0)}
    private static let secretPatterns = [
            #"\b(?:sk|ghp|github_pat|sk-ant)-?[A-Za-z0-9_\-]{20,}\b"#,
            #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
            #"(?i)\b(password|passwd|api[_ -]?key|secret|access[_ -]?token)\s*[:=]\s*[^\s,;]{4,}"#,
            #"\b(?:\d[ -]*?){13,19}\b"#,
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?(?:-----END [^\n]*PRIVATE KEY-----|$)"#
        ]
}
public enum CaptureProfile: String, Codable, CaseIterable, Sendable {
    case light, balanced, detailed
    public var interval: TimeInterval { switch self { case .light: return 20; case .balanced: return 5; case .detailed: return 2 } }
    public var maxDimension: Int { switch self { case .light: return 1280; case .balanced: return 1920; case .detailed: return 2560 } }
    public var jpegQuality: Double { switch self { case .light: return 0.45; case .balanced: return 0.65; case .detailed: return 0.8 } }
    public func effectiveInterval(lowPower: Bool, thermalLimited: Bool, idleSeconds: Double) -> Double? {
        if idleSeconds > 120 { return nil }
        return interval * (lowPower ? 3 : 1) * (thermalLimited ? 3 : 1)
    }
}
public struct AppSettings: Codable, Equatable, Sendable {
    public var profile: CaptureProfile = .balanced
    public var privacy = PrivacyPolicy()
    public var piiImports = PIIImportConfiguration()
    public var visualCaptureMode:VisualCaptureMode = .snapshots
    public var allDisplays = false
    public var snapshotRegions=SnapshotRegionSettings()
    public var captureOnLaunch = false
    public var ai = AIConfiguration()
    public var search = SearchConfiguration()
    public var automaticMaintenance = true
    public var apiEnabled = false
    public var routinesEnabled = false
    public var entityAutomaticIndex = false
    public var nativeModelRetention:NativeModelRetention = .twoMinutes
    public var speech = SpeechConfiguration()
    public var diarization = DiarizationConfiguration()
    public var retainAudio = false
    public var audioEnabled = false
    public var systemAudioEnabled = false
    public var whisperBinary = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first(where: { FileManager.default.isExecutableFile(atPath:$0) }) ?? "/opt/homebrew/bin/whisper-cli"
    public var whisperModel = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OSwind/models/ggml-base.en.bin").path
    public var transcriptionLanguage = "en"
    public init() {}
    enum CodingKeys: String, CodingKey { case profile,privacy,piiImports,visualCaptureMode,allDisplays,snapshotRegions,captureOnLaunch,ai,search,automaticMaintenance,apiEnabled,routinesEnabled,entityAutomaticIndex,nativeModelRetention,speech,diarization,retainAudio,audioEnabled,systemAudioEnabled,whisperBinary,whisperModel,transcriptionLanguage }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy:CodingKeys.self)
        profile = try c.decodeIfPresent(CaptureProfile.self,forKey:.profile) ?? profile
        privacy = try c.decodeIfPresent(PrivacyPolicy.self,forKey:.privacy) ?? privacy
        piiImports = try c.decodeIfPresent(PIIImportConfiguration.self,forKey:.piiImports) ?? piiImports
        visualCaptureMode = try c.decodeIfPresent(VisualCaptureMode.self,forKey:.visualCaptureMode) ?? visualCaptureMode
        allDisplays = try c.decodeIfPresent(Bool.self,forKey:.allDisplays) ?? allDisplays
        // A malformed new selector must not fall back to capturing all displays.
        if c.contains(.snapshotRegions) {snapshotRegions=(try? c.decode(SnapshotRegionSettings.self,forKey:.snapshotRegions)) ?? .disabled}
        captureOnLaunch = try c.decodeIfPresent(Bool.self,forKey:.captureOnLaunch) ?? captureOnLaunch
        ai = try c.decodeIfPresent(AIConfiguration.self,forKey:.ai) ?? ai
        search = try c.decodeIfPresent(SearchConfiguration.self,forKey:.search) ?? search
        automaticMaintenance = try c.decodeIfPresent(Bool.self,forKey:.automaticMaintenance) ?? automaticMaintenance
        apiEnabled = try c.decodeIfPresent(Bool.self,forKey:.apiEnabled) ?? apiEnabled
        routinesEnabled = try c.decodeIfPresent(Bool.self,forKey:.routinesEnabled) ?? routinesEnabled
        entityAutomaticIndex = try c.decodeIfPresent(Bool.self,forKey:.entityAutomaticIndex) ?? entityAutomaticIndex
        diarization = try c.decodeIfPresent(DiarizationConfiguration.self,forKey:.diarization) ?? diarization
        nativeModelRetention = try c.decodeIfPresent(NativeModelRetention.self,forKey:.nativeModelRetention) ?? nativeModelRetention
        speech = try c.decodeIfPresent(SpeechConfiguration.self,forKey:.speech) ?? speech
        retainAudio = try c.decodeIfPresent(Bool.self,forKey:.retainAudio) ?? retainAudio
        audioEnabled = try c.decodeIfPresent(Bool.self,forKey:.audioEnabled) ?? audioEnabled
        systemAudioEnabled = try c.decodeIfPresent(Bool.self,forKey:.systemAudioEnabled) ?? systemAudioEnabled
        whisperBinary = try c.decodeIfPresent(String.self,forKey:.whisperBinary) ?? whisperBinary
        whisperModel = try c.decodeIfPresent(String.self,forKey:.whisperModel) ?? whisperModel
        transcriptionLanguage = try c.decodeIfPresent(String.self,forKey:.transcriptionLanguage) ?? transcriptionLanguage
    }
    public static func load(root:URL=Paths.data)->AppSettings {
        do {return try JSONDecoder().decode(Self.self,from:Data(contentsOf:root.appendingPathComponent("settings.json")))}
        catch let error as NSError where error.domain==NSCocoaErrorDomain && error.code==NSFileReadNoSuchFileError {return Self()}
        catch {
            // An unreadable existing policy must not expand a saved crop or
            // start automatic cleanup under replacement defaults.
            var safe=Self();safe.snapshotRegions = .disabled;safe.automaticMaintenance=false;return safe
        }
    }
    public func save(root: URL = Paths.data) throws {try SettingsFileAccess.save(JSONEncoder().encode(self),root:root)}
}
