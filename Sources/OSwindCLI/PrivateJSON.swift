import Foundation
import Darwin

/// Create the requested diagnostic file with private permissions before writing.
/// O_EXCL/O_NOFOLLOW preserve an existing file even if it appears during inference.
func writeNewPrivateJSON(_ value:Any,to path:String) throws {
    let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
    let descriptor=Darwin.open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
    guard descriptor>=0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:[NSLocalizedDescriptionKey:"Cannot create new private timeline output"])}
    let handle=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true);defer {try? handle.close()}
    try handle.write(contentsOf:data);try handle.synchronize()
}
