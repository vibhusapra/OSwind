import Foundation
import Darwin

/// A selected local input is read from one retained descriptor. Refuse special
/// files before reading; enforce the byte bound before allocation and per chunk.
/// Cancellation is cooperative between regular-file reads, not a wall-clock
/// guarantee for an unresponsive filesystem. No file content enters diagnostics.
enum LibraryImportFile {
    static let jsonMaximumBytes=100_000_000
    static func read(_ url:URL,maximumBytes:Int,progress:((Int)throws->Void)?=nil) throws -> Data {
        try Task.checkCancellation()
        guard maximumBytes>=0,url.isFileURL,url.host.map({$0.isEmpty || $0.lowercased()=="localhost"}) ?? true,!url.path.utf8.contains(0) else {throw OSwindError.invalid("Choose a local regular import file")}
        let parent=url.deletingLastPathComponent(),name=url.lastPathComponent
        guard !name.isEmpty,name != ".",name != ".." else {throw OSwindError.invalid("Choose a local regular import file")}
        do {
        let tree=try BackupFileTree(root:parent.standardizedFileURL.resolvingSymlinksInPath())
        try tree.requireRootIdentity(at:parent)
        return try tree.withFile(name) {file,initial in
            guard initial.bytes<=maximumBytes else {throw OSwindError.invalid("Import file exceeds its \(maximumBytes)-byte limit")}
            var result=Data(),buffer=[UInt8](repeating:0,count:65536)
            while true {
                try Task.checkCancellation();let count=Darwin.read(file,&buffer,buffer.count)
                if count<0,errno==EINTR {continue}
                guard count>=0,count<=maximumBytes-result.count else {throw OSwindError.invalid("Import file changed or exceeded its byte limit while reading")}
                if count==0 {break}
                result.append(contentsOf:buffer.prefix(count));try progress?(result.count)
            }
            try Task.checkCancellation();try tree.requireRootIdentity(at:parent)
            var final=stat(),named=stat()
            let matches=tree.withRootDirectory {directory in
                fstat(file,&final)==0 && fstatat(directory,name,&named,AT_SYMLINK_NOFOLLOW)==0 && named.st_mode & S_IFMT==S_IFREG &&
                    BackupFileStamp(final)==initial && BackupFileStamp(named)==initial && result.count==initial.bytes
            }
            guard matches else {throw OSwindError.unavailable("Import file changed while reading. Select the current file and retry.")}
            return result
        }
        } catch let error as BackupFileError {
            switch error {
            case .changed:throw OSwindError.unavailable("Import file or containing folder changed while reading. Select the current file and retry.")
            case .invalid:throw OSwindError.invalid("Choose a local regular import file. Symbolic links, directories and pipes are not supported.")
            case .missing,.io:throw OSwindError.unavailable("Cannot read the selected import file. Check its location and read access.")
            }
        }
    }
}
