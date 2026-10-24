import Foundation
import Darwin

struct VaultInitializationPermit:Sendable {let package:URL;let nonce:String}
struct VaultAccessContext:Sendable {
    var paths:VaultPaths
    var info:LibraryVaultInfo
    var session:VaultSession
    var mount:URL {paths.mount(session)}
    var library:URL {paths.library}
}
func vaultResolvedURL(_ url:URL) throws -> URL {
    var current=url.standardizedFileURL,missing=[String]()
    for _ in 0..<256 {
        if let path=realpath(current.path,nil) {defer {free(path)};var result=URL(fileURLWithPath:String(cString:path));for part in missing.reversed() {result.appendPathComponent(part)};return result}
        guard errno==ENOENT else {throw OSwindError.unavailable("Cannot resolve the encrypted-library location")}
        let parent=current.deletingLastPathComponent();guard parent != current else {break};missing.append(current.lastPathComponent);current=parent
    }
    throw OSwindError.unavailable("Cannot resolve the encrypted-library location")
}
enum SQLiteTemporaryPolicy:String {case file="FILE",memory="MEMORY"}
/// This guards before directory creation / SQLite open. A managed handle must
/// never fall back to a fresh plaintext database when its image is unavailable.
enum VaultAccess {
    @TaskLocal static var initialization:VaultInitializationPermit?
    static func package(containing url:URL) throws -> VaultPaths? {
        guard url.isFileURL,!url.path.utf8.contains(0) else {throw OSwindError.invalid("Use a local library path")}
        func ancestors(_ start:URL) -> [URL] {
            var result=[URL](),current=start
            for _ in 0..<256 {result.append(current);let parent=current.deletingLastPathComponent();if parent==current {break};current=parent};return result
        }
        let original=ancestors(url.standardizedFileURL)
        // Bind the public handle to its enclosing package before following a
        // marker through a symlink. A redirected handle must not choose a
        // different vault's manifest just because its target has a valid marker.
        for current in original {
            var metadata=stat();if lstat(current.appendingPathComponent(VaultPaths.manifestName).path,&metadata)==0 {return try VaultPaths(current)}
            if current.pathExtension.lowercased()=="oswindvault" {throw OSwindError.unavailable("This encrypted-library package has no readable manifest. Its files were preserved; no plaintext library was created.")}
        }
        let canonical=ancestors(try vaultResolvedURL(url))
        for current in canonical {var metadata=stat();if lstat(current.appendingPathComponent(VaultPaths.manifestName).path,&metadata)==0 {return try VaultPaths(current)}}
        for current in original+canonical {
            var metadata=stat();guard lstat(current.appendingPathComponent(VaultPaths.markerName).path,&metadata)==0 else {continue}
            let tree=try BackupFileTree(root:vaultResolvedURL(current)),value=try JSONDecoder().decode(VaultLibraryMarker.self,from:tree.read(VaultPaths.markerName,limit:65536))
            guard value.format=="OSwind managed encrypted library",value.version==1,UUID(uuidString:value.vaultID) != nil,value.packagePath.hasPrefix("/") else {throw OSwindError.invalid("The managed-library marker is invalid")}
            let paths=try VaultPaths(URL(fileURLWithPath:value.packagePath,isDirectory:true));guard try paths.info().id==value.vaultID else {throw OSwindError.invalid("The managed-library manifest does not match")};return paths
        }
        return nil
    }
    static func context(at url:URL) throws -> VaultAccessContext? {
        guard let paths=try package(containing:url) else {return nil}
        let info=try paths.info()
        guard let session=try paths.session(info:info) else {throw OSwindError.unavailable("Unlock this encrypted library before opening it")}
        let permit=initialization.map {$0.package==paths.package && $0.nonce==session.nonce} ?? false
        guard session.phase == .unlocked || (permit && session.phase == .opening) else {throw OSwindError.unavailable("The encrypted library is locked or finishing another operation")}
        try validateVolume(paths:paths,info:info,session:session)
        let mount=paths.mount(session),requested=url.standardizedFileURL
        let isPublic=requested.path==paths.library.path || requested.path.hasPrefix(paths.library.path+"/")
        if isPublic {
            var link=stat();guard lstat(paths.library.path,&link)==0,link.st_mode & S_IFMT==S_IFLNK else {throw OSwindError.unavailable("The encrypted-library handle is closed")}
            let target=try FileManager.default.destinationOfSymbolicLink(atPath:paths.library.path)
            guard target==mount.appendingPathComponent("Library").path else {throw OSwindError.invalid("The encrypted-library handle points somewhere else")}
        }
        let resolved=try vaultResolvedURL(requested)
        guard resolved.path==mount.path || resolved.path.hasPrefix(mount.path+"/") else {throw OSwindError.invalid("This path is outside the verified encrypted volume")}
        return .init(paths:paths,info:info,session:session)
    }
    static func validateVolume(paths:VaultPaths,info:LibraryVaultInfo,session:VaultSession) throws {
        try session.validate(info:info)
        let root=paths.mount(session),stamp=try BackupFileTree(root:root).identity(),image=try BackupFileTree(root:paths.image).identity()
        guard stamp.device==session.rootDevice,stamp.inode==session.rootInode,image.device==session.imageDevice,image.inode==session.imageInode else {throw OSwindError.unavailable("The encrypted volume is no longer available at its verified location")}
        var filesystem=statfs();guard statfs(root.path,&filesystem)==0 else {throw OSwindError.unavailable("Cannot inspect the encrypted volume")}
        var name=filesystem.f_mntonname
        let capacity=MemoryLayout.size(ofValue:name)
        let point=withUnsafePointer(to:&name) {pointer in pointer.withMemoryRebound(to:CChar.self,capacity:capacity) {String(cString:$0)}}
        guard URL(fileURLWithPath:point).standardizedFileURL==root.standardizedFileURL else {throw OSwindError.unavailable("The vault directory is not the verified mounted volume")}
        let values=try root.resourceValues(forKeys:[.volumeUUIDStringKey]);guard values.volumeUUIDString?.caseInsensitiveCompare(info.volumeUUID) == .orderedSame else {throw OSwindError.invalid("The mounted volume identity does not match this vault")}
    }
    static func temporaryPolicy(at url:URL) throws -> SQLiteTemporaryPolicy {let context=try context(at:url);return context != nil || initialization != nil ? .memory:.file}
    static func workspace(source:URL,label:String,parent:URL?=nil,allowExternalParent:Bool=false) throws -> BackupWorkspace {
        let sourceContext=try context(at:source)
        if let parent {
            let parentContext=try context(at:parent)
            if let sourceContext,!allowExternalParent {guard parentContext?.info.id==sourceContext.info.id,parentContext?.session.nonce==sourceContext.session.nonce else {throw OSwindError.invalid("Private temporary work must stay inside this encrypted library")}}
            _ = try BackupWorkspace.cleanupAbandoned(in:parent,labels:[label]);return try BackupWorkspace(in:parent,label:label)
        }
        if let sourceContext {
            let store=try MemoryStore(root:sourceContext.library);return try store.libraryWorkspace(label)
        }
        _ = try BackupWorkspace.cleanupAbandoned(labels:[label]);return try BackupWorkspace(label:label)
    }
}
