import Foundation

public struct LibraryLocationSelection: Sendable {
    public var url: URL
    public var requiresExisting: Bool
    public var origin: String
    public init(url: URL, requiresExisting: Bool, origin: String) { self.url = url; self.requiresExisting = requiresExisting; self.origin = origin }
    public func validate() throws {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw OSwindError.invalid("Invalid library location") }
        if requiresExisting, !FileManager.default.fileExists(atPath:url.appendingPathComponent("memory.sqlite").path) { throw OSwindError.unavailable("The selected library is unavailable. Reconnect its drive or choose another library.") }
        guard !FileManager.default.fileExists(atPath:url.appendingPathComponent("header.json").path) else { throw OSwindError.invalid("Restore the backup package into a new library before opening it") }
    }
}
public enum LibraryLocationPreferences {
    public static let key = "OSwindCurrentLibraryPath"
    public static func selection(environment: [String:String] = ProcessInfo.processInfo.environment, demo: Bool = false, defaults: UserDefaults = .standard) -> LibraryLocationSelection {
        if let path = environment["OSWIND_DATA_DIR"], !path.isEmpty { return LibraryLocationSelection(url:URL(fileURLWithPath:path),requiresExisting:false,origin:"environment") }
        if demo { return LibraryLocationSelection(url:Paths.data.deletingLastPathComponent().appendingPathComponent("OSwind-Demo"),requiresExisting:false,origin:"demo") }
        if let path = defaults.string(forKey:key), !path.isEmpty { return LibraryLocationSelection(url:URL(fileURLWithPath:path),requiresExisting:true,origin:"selected") }
        return LibraryLocationSelection(url:Paths.data,requiresExisting:false,origin:"default")
    }
    public static func save(_ url: URL, defaults: UserDefaults = .standard) throws {
        let selection = LibraryLocationSelection(url:url,requiresExisting:true,origin:"selected"); try selection.validate()
        defaults.set(url.standardizedFileURL.resolvingSymlinksInPath().path,forKey:key)
    }
}
