import Foundation
import CryptoKit
import Darwin

enum BackupFileError: LocalizedError {
    case invalid(String), missing(String), changed(String), io(String)
    var errorDescription: String? { switch self { case .invalid(let text),.missing(let text),.changed(let text),.io(let text): return text } }
}
struct BackupFileStamp: Equatable, Sendable {
    var device: Int32
    var inode: UInt64
    var bytes: Int64
    var modifiedSeconds: Int64
    var modifiedNanos: Int64
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; bytes = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
    }
}
struct BackupFileDigest: Codable, Equatable, Sendable { var bytes: Int64; var sha256: String }
enum BackupPinMethod: String, Codable { case clone, copy }

/// All descendants are opened relative to retained directory descriptors.
/// Caller-created workspaces are private; an archive is always read-only here.
final class BackupFileTree {
    let root: URL
    private let descriptor: Int32
    private let writable: Bool
    init(root: URL, writable: Bool = false) throws {
        guard root.isFileURL, !root.path.utf8.contains(0) else { throw BackupFileError.invalid("Invalid backup directory") }
        var metadata = stat()
        guard lstat(root.path,&metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { throw BackupFileError.invalid("Backup root must be a real directory") }
        if writable { guard metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { throw BackupFileError.invalid("Backup workspace must be private to the current user") } }
        guard let path = realpath(root.path,nil) else { throw Self.failure("Cannot resolve backup directory") }
        defer { free(path) }
        let opened = open(path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else { throw Self.failure("Cannot open backup directory") }
        var actual = stat()
        guard fstat(opened,&actual) == 0, actual.st_dev == metadata.st_dev, actual.st_ino == metadata.st_ino, actual.st_mode & S_IFMT == S_IFDIR else {
            close(opened); throw BackupFileError.changed("Backup root changed while being opened")
        }
        if writable, actual.st_uid != getuid() || actual.st_mode & 0o077 != 0 {
            close(opened); throw BackupFileError.invalid("Backup workspace is no longer private")
        }
        descriptor = opened; self.root = root; self.writable = writable
    }
    init(takingDirectory file: Int32, root: URL, writable: Bool) throws {
        var actual = stat()
        guard fstat(file,&actual) == 0, actual.st_mode & S_IFMT == S_IFDIR,
              !writable || (actual.st_uid == getuid() && actual.st_mode & 0o077 == 0) else {
            close(file); throw BackupFileError.invalid("Invalid owned backup workspace descriptor")
        }
        descriptor = file; self.root = root; self.writable = writable
    }
    func withRootDirectory<T>(_ body: (Int32) throws -> T) rethrows -> T { try body(descriptor) }
    /// Trusted live-library aliases may be followed, but must still resolve to
    /// the directory retained when this operation began.
    func requireRootIdentity(at location: URL) throws {
        var actual = stat(), current = stat()
        guard location.isFileURL,!location.path.utf8.contains(0),fstat(descriptor,&actual)==0,
              fstatat(AT_FDCWD,location.path,&current,0)==0,current.st_mode & S_IFMT==S_IFDIR,
              current.st_dev==actual.st_dev,current.st_ino==actual.st_ino else { throw BackupFileError.changed("The source library moved or changed during backup") }
    }
    func isAncestor(of other: BackupFileTree) throws -> Bool {
        var own = stat(); guard fstat(descriptor,&own) == 0 else { throw Self.failure("Cannot inspect backup source directory") }
        var current = other.withRootDirectory { openat($0,".",O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard current >= 0 else { throw Self.failure("Cannot inspect backup destination directory") }
        defer { close(current) }
        for _ in 0..<1024 {
            var child = stat(); guard fstat(current,&child) == 0 else { throw Self.failure("Cannot inspect backup directory ancestry") }
            if own.st_dev == child.st_dev && own.st_ino == child.st_ino { return true }
            let parent = openat(current,"..",O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard parent >= 0 else { throw Self.failure("Cannot inspect backup parent directory") }
            var metadata = stat(); guard fstat(parent,&metadata) == 0 else { close(parent); throw Self.failure("Cannot inspect backup parent") }
            if metadata.st_dev == child.st_dev && metadata.st_ino == child.st_ino { close(parent); return false }
            close(current); current = parent
        }
        throw BackupFileError.invalid("Backup directory ancestry is too deep")
    }
    func remove(_ relative: String) throws {
        guard writable else { throw BackupFileError.invalid("Archive directories are read-only") }
        let parts = try Self.components(relative), parent = try directory(parts.dropLast()); defer { close(parent) }
        guard unlinkat(parent,parts.last!,0) == 0 else { throw Self.failure("Cannot remove backup scratch member") }
    }
    func removeAllChildren() throws {
        guard writable else { throw BackupFileError.invalid("Archive directories are read-only") }
        try Self.removeChildren(descriptor,depth:0)
    }
    private static func removeChildren(_ directory: Int32, depth: Int) throws {
        guard depth < 64 else { throw BackupFileError.invalid("Backup cleanup directory depth exceeded") }
        let duplicate = openat(directory,".",O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard duplicate >= 0 else { throw failure("Cannot open backup cleanup directory") }
        guard let entries = fdopendir(duplicate) else { close(duplicate); throw failure("Cannot enumerate backup cleanup directory") }
        defer { closedir(entries) }
        while true {
            errno = 0
            guard let entry = readdir(entries) else { if errno != 0 { throw failure("Backup cleanup enumeration failed") }; break }
            let name = withUnsafePointer(to:&entry.pointee.d_name) { $0.withMemoryRebound(to:CChar.self,capacity:1024) { String(cString:$0) } }
            if name == "." || name == ".." { continue }
            var metadata = stat()
            guard fstatat(directory,name,&metadata,AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("Cannot inspect backup cleanup member") }
            if metadata.st_mode & S_IFMT == S_IFDIR {
                let child = openat(directory,name,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard child >= 0 else { throw failure("Cannot open backup cleanup member") }
                var opened = stat()
                guard fstat(child,&opened) == 0, opened.st_dev == metadata.st_dev, opened.st_ino == metadata.st_ino else { close(child); throw BackupFileError.changed("Backup cleanup member changed before opening") }
                do { try removeChildren(child,depth:depth+1); close(child) } catch { close(child); throw error }
                var current = stat()
                guard fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW) == 0, current.st_dev == metadata.st_dev, current.st_ino == metadata.st_ino else { throw BackupFileError.changed("Backup cleanup member changed") }
                guard unlinkat(directory,name,AT_REMOVEDIR) == 0 else { throw failure("Cannot remove backup cleanup directory") }
            } else { guard unlinkat(directory,name,0) == 0 else { throw failure("Cannot remove backup cleanup member") } }
        }
    }
    deinit { close(descriptor) }
    private static func failure(_ context: String, code: Int32 = errno) -> BackupFileError {
        if code == ENOENT { return .missing(context+": missing file") }
        return .io(context+": "+String(cString:strerror(code)))
    }
    static func components(_ relative: String) throws -> [String] {
        let parts = relative.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        guard !relative.isEmpty, relative.utf8.count <= 16384, !relative.hasPrefix("/"), !relative.utf8.contains(0), parts.count <= 64,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 1024 }) else { throw BackupFileError.invalid("Invalid relative backup member path") }
        return parts
    }
    private func directory(_ parts: ArraySlice<String>, create: Bool = false) throws -> Int32 {
        var current = openat(descriptor,".",O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw Self.failure("Cannot retain backup directory") }
        do {
            for part in parts {
                try Task.checkCancellation()
                if create {
                    guard writable else { throw BackupFileError.invalid("Archive directories are read-only") }
                    if mkdirat(current,part,0o700) != 0 && errno != EEXIST { throw Self.failure("Cannot create backup directory") }
                }
                let next = openat(current,part,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw Self.failure("Cannot traverse backup directory") }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    func withFile<T>(_ relative: String, _ body: (Int32,BackupFileStamp) throws -> T) throws -> T {
        let parts = try Self.components(relative), parent = try directory(parts.dropLast())
        defer { close(parent) }
        let file = openat(parent,parts.last!,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw Self.failure("Cannot read backup member") }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file,&metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size >= 0 else { throw BackupFileError.invalid("Backup members must be regular files") }
        return try body(file,BackupFileStamp(metadata))
    }
    private static func stamp(_ file: Int32) throws -> BackupFileStamp {
        var value = stat(); guard fstat(file,&value) == 0 else { throw failure("Cannot inspect backup member") }; return BackupFileStamp(value)
    }
    private func createFile<T>(_ relative: String, _ body: (Int32) throws -> T) throws -> T {
        guard writable else { throw BackupFileError.invalid("Archive directories are read-only") }
        let parts = try Self.components(relative), parent = try directory(parts.dropLast(),create:true), name = parts.last!
        defer { close(parent) }
        let file = openat(parent,name,O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,0o600)
        guard file >= 0 else { throw Self.failure("Backup member already exists or cannot be created") }
        var complete = false
        defer { close(file); if !complete { unlinkat(parent,name,0) } }
        let value = try body(file)
        guard fsync(file) == 0 else { throw Self.failure("Cannot flush backup member") }
        complete = true; return value
    }
    private static func write(_ file: Int32, _ data: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let written = Darwin.write(file,data.baseAddress!.advanced(by:offset),data.count-offset)
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw failure("Cannot write backup member") }; offset += written
        }
    }
    /// Reads at most one MiB at a time. Atime and link-count changes are harmless;
    /// content size/mtime or file identity changes invalidate the read.
    private static func stream(_ file: Int32, before: BackupFileStamp, output: Int32? = nil,
                               progress: (Int64) throws -> Void) throws -> BackupFileDigest {
        var buffer = [UInt8](repeating:0,count:Int(min(1024*1024,max(1,before.bytes)))), hash = SHA256(), total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(file,&buffer,buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw failure("Cannot read backup member") }
            if count == 0 { break }
            guard total <= Int64.max-Int64(count), total+Int64(count) <= before.bytes else { throw BackupFileError.changed("Backup member grew while being read") }
            try buffer.withUnsafeBytes { bytes in
                let span = UnsafeRawBufferPointer(start:bytes.baseAddress,count:count)
                hash.update(bufferPointer:span)
                if let output { try write(output,span) }
            }
            total += Int64(count); try progress(total)
        }
        guard total == before.bytes, try stamp(file) == before else { throw BackupFileError.changed("Backup member changed while being read") }
        return BackupFileDigest(bytes:total,sha256:hash.finalize().map { String(format:"%02x",$0) }.joined())
    }
    func digest(_ relative: String, progress: (Int64) throws -> Void = { _ in }) throws -> BackupFileDigest {
        try withFile(relative) { file, metadata in try Self.stream(file,before:metadata,progress:progress) }
    }
    @discardableResult func copy(_ relative: String, to target: BackupFileTree, as member: String,
                                progress: (Int64) throws -> Void = { _ in }) throws -> BackupFileDigest {
        try withFile(relative) { file, metadata in
            try target.createFile(member) { output in try Self.stream(file,before:metadata,output:output,progress:progress) }
        }
    }
    func read(_ relative: String, limit: Int) throws -> Data {
        guard limit >= 0 else { throw BackupFileError.invalid("Invalid backup read bound") }
        return try withFile(relative) { file, metadata in
            guard metadata.bytes <= Int64(limit) else { throw BackupFileError.invalid("Backup member exceeds its read bound") }
            var result = Data(), buffer = [UInt8](repeating:0,count:max(1,min(65536,limit)))
            while true {
                try Task.checkCancellation(); let count = Darwin.read(file,&buffer,buffer.count)
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw Self.failure("Cannot read backup metadata") }; if count == 0 { break }
                guard count <= limit-result.count else { throw BackupFileError.changed("Backup metadata grew while being read") }
                result.append(contentsOf:buffer.prefix(count))
            }
            guard result.count == metadata.bytes, try Self.stamp(file) == metadata else { throw BackupFileError.changed("Backup metadata changed while being read") }
            return result
        }
    }
    func write(_ data: Data, as member: String) throws {
        try createFile(member) { output in try data.withUnsafeBytes { try Self.write(output,$0) } }
    }
    /// The borrowed descriptor is valid only for this synchronous callback.
    func withNewFile<T>(_ member: String, _ body: (Int32) throws -> T) throws -> T {
        try createFile(member,body)
    }
    func forEachEntry(in relative: String? = nil, ignoreInvalidNames: Bool = false, _ body: (String) throws -> Void) throws {
        let parts = try relative.map(Self.components) ?? []
        let file = try directory(parts[...])
        guard let entries = fdopendir(file) else { close(file); throw Self.failure("Cannot enumerate backup directory") }
        defer { closedir(entries) }
        while true {
            try Task.checkCancellation(); errno = 0
            guard let entry = readdir(entries) else { if errno != 0 { throw Self.failure("Cannot enumerate backup directory") }; break }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of:&entry.pointee.d_name) { bytes -> String? in
                guard length > 0, length <= bytes.count else { return nil }
                return String(bytes:bytes.prefix(length),encoding:.utf8)
            }
            guard let name else { if ignoreInvalidNames { continue }; throw BackupFileError.invalid("Backup member name is not valid UTF-8") }
            if name == "." || name == ".." { continue }
            try body(name)
        }
    }
    /// Prefer a descriptor-based APFS COW clone. The fallback also reads the
    /// verified descriptor, so pathname replacement cannot redirect the copy.
    @discardableResult func pin(_ relative: String, to target: BackupFileTree, as member: String,
                               preferClone: Bool = true, progress: (Int64) throws -> Void = { _ in }) throws -> BackupPinMethod {
        guard target.writable else { throw BackupFileError.invalid("Pin destination is read-only") }
        return try withFile(relative) { file, metadata in
            if preferClone {
                let parts = try Self.components(member), parent = try target.directory(parts.dropLast(),create:true), name = parts.last!
                defer { close(parent) }
                if fclonefileat(file,parent,name,UInt32(CLONE_NOOWNERCOPY)) == 0 {
                    var complete = false
                    defer { if !complete { unlinkat(parent,name,0) } }
                    let output = openat(parent,name,O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                    guard output >= 0 else { throw Self.failure("Cannot inspect cloned backup member") }; defer { close(output) }
                    let copied = try Self.stamp(output)
                    guard copied.bytes == metadata.bytes, try Self.stamp(file) == metadata else { throw BackupFileError.changed("Media changed while creating a snapshot pin") }
                    guard fchmod(output,0o600) == 0, fsync(output) == 0 else { throw Self.failure("Cannot secure cloned backup member") }
                    try progress(metadata.bytes); complete = true; return .clone
                }
                let code = errno
                guard [ENOTSUP,EXDEV,EINVAL,ENOSYS].contains(code) else { throw Self.failure("Cannot clone backup member",code:code) }
            }
            _ = try target.createFile(member) { output in try Self.stream(file,before:metadata,output:output,progress:progress) }
            return .copy
        }
    }
}
