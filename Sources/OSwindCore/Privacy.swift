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
    public func exclusion(app: String, title: String, url: String?, isBrowser: Bool = false) -> String? {
        if excludedApps.contains(where: { app.caseInsensitiveCompare($0) == .orderedSame }) { return "Excluded application" }
        if excludedTitles.contains(where: { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }) { return "Excluded window" }
        if isBrowser && requireBrowserContext && !excludedDomains.isEmpty && url == nil { return "Browser URL unavailable; privacy rules require context" }
        if let host = url.flatMap({ URL(string: $0)?.host?.lowercased() }), excludedDomains.contains(where: { let domain = $0.lowercased().trimmingCharacters(in: .whitespaces); return !domain.isEmpty && (host == domain || host.hasSuffix("." + domain)) }) { return "Excluded website" }
        return nil
    }
    public func sanitize(_ text: String) -> (text: String, redacted: Bool) {
        guard redactSecrets else { return (text, false) }
        var result = text
        let patterns = [
            #"\b(?:sk|ghp|github_pat|sk-ant)-?[A-Za-z0-9_\-]{20,}\b"#,
            #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#,
            #"(?i)\b(password|passwd|api[_ -]?key|secret|access[_ -]?token)\s*[:=]\s*[^\s,;]{4,}"#,
            #"\b(?:\d[ -]*?){13,19}\b"#,
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----[\s\S]*?(?:-----END [^\n]*PRIVATE KEY-----|$)"#
        ]
        for pattern in patterns { if let re = try? NSRegularExpression(pattern: pattern) { result = re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[REDACTED]") } }
        return (result, result != text)
    }
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
    public var allDisplays = false
    public var captureOnLaunch = false
    public var ai = AIConfiguration()
    public var search = SearchConfiguration()
    public var automaticMaintenance = true
    public var apiEnabled = false
    public var speech = SpeechConfiguration()
    public var retainAudio = false
    public var audioEnabled = false
    public var systemAudioEnabled = false
    public var whisperBinary = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].first(where: { FileManager.default.isExecutableFile(atPath:$0) }) ?? "/opt/homebrew/bin/whisper-cli"
    public var whisperModel = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/OSwind/models/ggml-base.en.bin").path
    public var transcriptionLanguage = "en"
    public init() {}
    enum CodingKeys: String, CodingKey { case profile,privacy,allDisplays,captureOnLaunch,ai,search,automaticMaintenance,apiEnabled,speech,retainAudio,audioEnabled,systemAudioEnabled,whisperBinary,whisperModel,transcriptionLanguage }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy:CodingKeys.self)
        profile = try c.decodeIfPresent(CaptureProfile.self,forKey:.profile) ?? profile
        privacy = try c.decodeIfPresent(PrivacyPolicy.self,forKey:.privacy) ?? privacy
        allDisplays = try c.decodeIfPresent(Bool.self,forKey:.allDisplays) ?? allDisplays
        captureOnLaunch = try c.decodeIfPresent(Bool.self,forKey:.captureOnLaunch) ?? captureOnLaunch
        ai = try c.decodeIfPresent(AIConfiguration.self,forKey:.ai) ?? ai
        search = try c.decodeIfPresent(SearchConfiguration.self,forKey:.search) ?? search
        automaticMaintenance = try c.decodeIfPresent(Bool.self,forKey:.automaticMaintenance) ?? automaticMaintenance
        apiEnabled = try c.decodeIfPresent(Bool.self,forKey:.apiEnabled) ?? apiEnabled
        speech = try c.decodeIfPresent(SpeechConfiguration.self,forKey:.speech) ?? speech
        retainAudio = try c.decodeIfPresent(Bool.self,forKey:.retainAudio) ?? retainAudio
        audioEnabled = try c.decodeIfPresent(Bool.self,forKey:.audioEnabled) ?? audioEnabled
        systemAudioEnabled = try c.decodeIfPresent(Bool.self,forKey:.systemAudioEnabled) ?? systemAudioEnabled
        whisperBinary = try c.decodeIfPresent(String.self,forKey:.whisperBinary) ?? whisperBinary
        whisperModel = try c.decodeIfPresent(String.self,forKey:.whisperModel) ?? whisperModel
        transcriptionLanguage = try c.decodeIfPresent(String.self,forKey:.transcriptionLanguage) ?? transcriptionLanguage
    }
    public static func load(root: URL = Paths.data) -> AppSettings { guard let data = try? Data(contentsOf: root.appendingPathComponent("settings.json")), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }; return value }
    public func save(root: URL = Paths.data) throws { try Paths.ensure(root); let data = try JSONEncoder().encode(self); try data.write(to: root.appendingPathComponent("settings.json"), options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: root.appendingPathComponent("settings.json").path) }
}
