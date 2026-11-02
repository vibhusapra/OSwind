import Foundation
import Darwin

// An internal encrypted-object transport, not automatic library synchronization.
// Every root is explicitly created/opened with a trusted group/epoch/key. Only
// opaque object names are read; no directory discovery or user-folder scanning.
final class SyncObjectFolder:@unchecked Sendable {
    let root:URL
    private let lock=NSRecursiveLock()
    private var tree:BackupFileTree?
    private let operations:SyncCipherContext
    private let chunks:SyncCipherContext
    private let checkpoints:SyncCipherContext
    private let collectionControls:SyncCipherContext
    private let supersessions:SyncCipherContext
    // Deliberately incompatible with the prior transport: v1 peers do not
    // understand creation eras, group erasure or causal supersession. Never
    // install a v1 marker alongside this one or silently adopt a legacy space.
    private static let markerName="space-v2"
    private static let markerDescriptor=Data("OSwind.sync.space-marker.v2".utf8)
    private static let markerBody=Data("OSwind encrypted object space v2; creation-era-v1; collection-control-v1; supersession-v1".utf8)
    private init(root:URL,secret:SyncGroupSecret,group:String,epoch:String,create:Bool)throws {
        try Task.checkCancellation()
        guard root.isFileURL,!root.path.utf8.contains(0) else {throw OSwindError.invalid("Sync object space must be a local directory")}
        self.root=root
        operations=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.operation)
        chunks=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.contentChunk)
        checkpoints=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.checkpoint)
        collectionControls=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.collectionControl)
        supersessions=try SyncCipherContext(secret:secret,group:group,epoch:epoch,purpose:.supersession)
        if create {
            try BackupWorkspace.requireNewDestination(root)
            guard mkdir(root.path,0o700)==0 else {throw OSwindError.unavailable("Cannot create private sync object space")}
        }
        let opened=try BackupFileTree(root:root,writable:true)
        tree=opened
        if create {
            let marker=try checkpoints.seal(Self.markerBody,descriptor:Self.markerDescriptor)
            try opened.write(marker.bytes,as:Self.markerName)
            try opened.withRootDirectory {guard fsync($0)==0 else {throw OSwindError.unavailable("Cannot flush sync object space")}}
        }
        let marker=try opened.read(Self.markerName,limit:SyncCipherContext.maximumEnvelopeBytes)
        let address=try checkpoints.token(for:Self.markerDescriptor)
        guard try checkpoints.open(marker,expectedToken:address,descriptor:Self.markerDescriptor)==Self.markerBody else {throw OSwindError.invalid("Sync object space marker differs")}
        try opened.requireRootIdentity(at:root)
    }
    static func create(at root:URL,secret:SyncGroupSecret,group:String,epoch:String)throws->SyncObjectFolder {try .init(root:root,secret:secret,group:group,epoch:epoch,create:true)}
    static func open(at root:URL,secret:SyncGroupSecret,group:String,epoch:String)throws->SyncObjectFolder {try .init(root:root,secret:secret,group:group,epoch:epoch,create:false)}
    var isClosed:Bool {lock.lock();defer {lock.unlock()};return tree==nil}
    /// The caller's owning journal must match this immutable cipher namespace
    /// before retaining any private canonical bytes, not only at declaration
    /// decode time. Marker authentication alone proves this space's own scope.
    func requireNamespace(group:String,epoch:String)throws {
        guard operations.group==group,operations.epoch==epoch else {throw OSwindError.invalid("Publication inbox belongs to another trusted group or epoch")}
        try withTree {_ in ()}
    }
    func close() {lock.lock();defer {lock.unlock()};tree=nil}
    private func withTree<T>(_ body:(BackupFileTree)throws->T)throws->T {
        lock.lock();defer {lock.unlock()}
        guard let tree else {throw OSwindError.unavailable("Sync object space is closed")}
        try tree.requireRootIdentity(at:root)
        let value=try body(tree)
        try tree.requireRootIdentity(at:root)
        return value
    }
    private static func path(_ token:String)throws->String {try SyncProtocolLimits.digest(token);return "objects/\(token.prefix(2))/\(token)"}
    private func read(_ context:SyncCipherContext,_ descriptor:Data)throws->Data? {
        let token=try context.token(for:descriptor)
        return try withTree {tree in
            let bytes:Data
            do {bytes=try tree.read(Self.path(token),limit:SyncCipherContext.maximumEnvelopeBytes)}
            catch BackupFileError.missing {return nil}
            return try context.open(bytes,expectedToken:token,descriptor:descriptor)
        }
    }
    private func publish(_ context:SyncCipherContext,_ descriptor:Data,_ plaintext:Data)throws {
        let object=try context.seal(plaintext,descriptor:descriptor)
        try withTree {rootTree in
            if let existing=try read(context,descriptor) {
                guard existing==plaintext else {throw OSwindError.invalid("Sync immutable object identity was reused")};return
            }
            let shard=try rootTree.privateDirectory("objects/\(object.token.prefix(2))")
            let temporary=".stage-"+UUID().uuidString.lowercased()
            try shard.withNewFile(temporary) {file in
                try object.bytes.withUnsafeBytes {bytes in
                    var offset=0
                    while offset<bytes.count {
                        try Task.checkCancellation()
                        let count=Darwin.write(file,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                        if count<0,errno==EINTR {continue}
                        guard count>0 else {throw OSwindError.unavailable("Cannot write staged sync object")};offset+=count
                    }
                }
            }
            defer {try? shard.remove(temporary)}
            try Task.checkCancellation()
            let linked=shard.withRootDirectory {directory in linkat(directory,temporary,directory,object.token,0)}
            if linked != 0 {
                let code=errno
                guard code==EEXIST,let existing=try read(context,descriptor),existing==plaintext else {throw OSwindError.invalid("Cannot atomically publish immutable sync object")}
            }
            // The final name links only a completed, fsynced file. No existing
            // final member is overwritten and a crash leaves at most an opaque
            // encrypted staging member, never a partly written final packet.
            try shard.withRootDirectory {guard fsync($0)==0 else {throw OSwindError.unavailable("Cannot flush published sync object")}}
        }
    }
    private static func operationDescriptor(replica:String,sequence:Int64)throws->Data {
        _=try SyncDot(replica:replica,counter:sequence)
        return Data("OSwind.sync.operation.v1\0\(replica)\0\(sequence)".utf8)
    }
    private static func chunkDescriptor(_ reference:SyncContentReference,_ index:Int)throws->Data {
        guard index>=0,index<chunkCount(reference) else {throw OSwindError.invalid("Invalid sync content chunk index")}
        return Data("OSwind.sync.content.v1\0\(reference.sha256)\0\(reference.bytes)\0\(index)".utf8)
    }
    private static func chunkCount(_ reference:SyncContentReference)->Int {max(1,Int((reference.bytes+Int64(SyncCipherContext.maximumPlaintextBytes)-1)/Int64(SyncCipherContext.maximumPlaintextBytes)))}
    func publishContent(_ bytes:Data,reference:SyncContentReference)throws {
        guard reference.matches(bytes) else {throw OSwindError.invalid("Sync content differs from its reference")}
        for index in 0..<Self.chunkCount(reference) {
            try Task.checkCancellation()
            let start=index*SyncCipherContext.maximumPlaintextBytes,end=min(bytes.count,start+SyncCipherContext.maximumPlaintextBytes)
            try publish(chunks,Self.chunkDescriptor(reference,index),Data(bytes[start..<end]))
        }
    }
    func content(_ reference:SyncContentReference)throws->Data? {
        var result=Data()
        for index in 0..<Self.chunkCount(reference) {
            try Task.checkCancellation()
            guard let value=try read(chunks,Self.chunkDescriptor(reference,index)) else {return nil}
            let expected=min(Int64(SyncCipherContext.maximumPlaintextBytes),reference.bytes-Int64(index*SyncCipherContext.maximumPlaintextBytes))
            guard value.count==expected else {throw OSwindError.invalid("Sync content chunk length differs")}
            result.append(value)
        }
        guard reference.matches(result) else {throw OSwindError.invalid("Sync assembled content checksum differs")};return result
    }
    func publishRevision(_ revision:SyncRevision)throws {
        if let reference=revision.content {guard try content(reference) != nil else {throw OSwindError.unavailable("Publish verified sync content before its operation")}}
        if let declaration=revision.publication {guard try content(declaration) != nil else {throw OSwindError.unavailable("Publish verified answer declaration before its operation")}}
        try publish(operations,Self.operationDescriptor(replica:revision.dot.replica,sequence:revision.dot.counter),revision.encoded())
    }
    func revision(replica:String,sequence:Int64)throws->SyncRevision? {
        guard let bytes=try read(operations,Self.operationDescriptor(replica:replica,sequence:sequence)) else {return nil}
        let revision=try SyncRevision.decode(bytes)
        guard revision.dot.replica==replica,revision.dot.counter==sequence else {throw OSwindError.invalid("Sync operation identity differs from its address")};return revision
    }
    func publishCollectionControl(_ control:SyncCollectionControl)throws {
        try requireNamespace(group:control.group,epoch:control.epoch)
        try publish(collectionControls,SyncCollectionControl.descriptor(creator:control.creator,counter:control.counter),control.encoded())
    }
    func collectionControl(creator:String,counter:Int64)throws->SyncCollectionControl? {
        guard let bytes=try read(collectionControls,SyncCollectionControl.descriptor(creator:creator,counter:counter)) else {return nil}
        let control=try SyncCollectionControl.decode(bytes)
        guard control.creator==creator,control.counter==counter else {throw OSwindError.invalid("Collection control differs from its opaque address")}
        try requireNamespace(group:control.group,epoch:control.epoch);return control
    }
    /// Header-only publication is allowed only after the exact erasing group
    /// control is present and authenticated in this immutable object space.
    func publishErasedRevision(_ revision:SyncRevision,control:SyncCollectionControl)throws {
        guard control.erases(revision),try collectionControl(creator:control.creator,counter:control.counter)==control else {throw OSwindError.invalid("Publish a verified erasing control before its body-free old revision")}
        try publish(operations,Self.operationDescriptor(replica:revision.dot.replica,sequence:revision.dot.counter),revision.encoded())
    }
    func publishDeletedRevision(_ revision:SyncRevision,deletion:SyncRevision)throws {
        guard revision.mutation == .put,deletion.mutation == .delete,deletion.key==revision.key,try self.revision(replica:deletion.dot.replica,sequence:deletion.dot.counter)==deletion else {throw OSwindError.invalid("Publish the exact deletion barrier before an old body-free revision")}
        try publish(operations,Self.operationDescriptor(replica:revision.dot.replica,sequence:revision.dot.counter),revision.encoded())
    }
    func publishSupersededRevision(_ revision:SyncRevision,successor:SyncRevision)throws {
        let proof=try SyncSupersessionProof(obsolete:revision,successor:successor)
        if let existing=try read(supersessions,SyncSupersessionProof.descriptor(revision.dot)) {
            guard try SyncSupersessionProof.decode(existing)==proof else {throw OSwindError.invalid("An immutable supersession proof changed")}
        } else {
            guard try self.revision(replica:successor.dot.replica,sequence:successor.dot.counter)==successor else {throw OSwindError.invalid("Publish the authenticated successor before its obsolete header")}
        }
        try publish(supersessions,SyncSupersessionProof.descriptor(revision.dot),proof.encoded())
        try publish(operations,Self.operationDescriptor(replica:revision.dot.replica,sequence:revision.dot.counter),revision.encoded())
    }
    func supersedingRevision(for revision:SyncRevision)throws->SyncRevision? {
        guard let bytes=try read(supersessions,SyncSupersessionProof.descriptor(revision.dot)) else {return nil}
        let proof=try SyncSupersessionProof.decode(bytes)
        let successor=try self.revision(replica:proof.successor.replica,sequence:proof.successor.counter) ?? proof.successorRevision
        guard try proof.matches(obsolete:revision,successor:successor) else {throw OSwindError.invalid("Supersession changed an operation identity")};return successor
    }
}
