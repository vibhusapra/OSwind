import Foundation
import Metal
import MetalPerformanceShaders

/// Exhaustive float32 scoring on unified-memory Macs. Calls are serialized by
/// ANNCache, including shared-buffer writes and completion of GPU commands.
final class MetalFlatIndex: VectorSearchBackend {
    static let format = "metal-mps-f32-cos-parent-v2"
    var indexFormat: String { Self.format }
    var strategy: String { "metal-exact-rerank" }
    let dimensions: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rowBytes: Int
    private let budget: Int
    private var matrixBuffer: MTLBuffer?
    private var queryBuffer: MTLBuffer
    private var scoreBuffer: MTLBuffer?
    private var capacity = 0
    private var keys = [UInt64]()
    private var parents = [UInt64]()
    private var slots = [UInt64:Int]()
    private var free = [Int]()
    var count: Int { slots.count }
    private static func budget(_ device: MTLDevice) -> Int {
        Int(min(UInt64(device.maxBufferLength),device.recommendedMaxWorkingSetSize/4,ProcessInfo.processInfo.physicalMemory/4,8*1024*1024*1024))
    }
    static func canFit(dimensions: Int, count: Int) -> Bool {
        guard (1...8192).contains(dimensions), count > 0, let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else { return false }
        let row = MPSMatrixDescriptor.rowBytes(forColumns:dimensions,dataType:.float32)
        return count <= budget(device)/(row+24)
    }
    init(dimensions: Int, byteBudget: Int? = nil) throws {
        guard (1...8192).contains(dimensions), let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory, let queue = device.makeCommandQueue(), let query = device.makeBuffer(length:dimensions*4,options:.storageModeShared) else { throw OSwindError.unavailable("Unified-memory Metal search is unavailable") }
        self.dimensions = dimensions; self.device = device; self.queue = queue; queryBuffer = query
        rowBytes = MPSMatrixDescriptor.rowBytes(forColumns:dimensions,dataType:.float32)
        budget = min(Self.budget(device),byteBudget ?? Int.max)
    }
    func reserve(_ count: Int) throws {
        guard count >= 0, count <= budget/(rowBytes+24) else { throw OSwindError.unavailable("Metal search memory budget exceeded; exact search remains available") }
        guard count > capacity else { return }
        let wanted = min(budget/(rowBytes+24),max(count,max(16,capacity+capacity/16)))
        // Bound the transient old+new allocation during a growing archive too.
        guard wanted <= (budget - capacity*(rowBytes+4))/(rowBytes+4), let buffer = device.makeBuffer(length:wanted*rowBytes,options:.storageModeShared), let scores = device.makeBuffer(length:wanted*4,options:.storageModeShared) else { throw OSwindError.unavailable("Cannot grow Metal search within its memory budget") }
        memset(buffer.contents(),0,wanted*rowBytes)
        if let previous = matrixBuffer, !keys.isEmpty { buffer.contents().copyMemory(from:previous.contents(),byteCount:keys.count*rowBytes) }
        matrixBuffer = buffer; scoreBuffer = scores; capacity = wanted
    }
    func remove(_ key: UInt64) throws {
        guard let slot = slots.removeValue(forKey:key) else { return }
        keys[slot] = 0; parents[slot] = 0; free.append(slot)
        if let buffer = matrixBuffer { memset(buffer.contents().advanced(by:slot*rowBytes),0,rowBytes) }
    }
    func add(_ key: UInt64, vector: [Float], parentKey: UInt64 = 0) throws {
        guard key > 0, key <= UInt64(Int64.max), vector.count == dimensions, CosineScorer(vector) != nil, parentKey <= UInt64(Int64.max) else { throw OSwindError.invalid("Invalid Metal index vector") }
        let slot: Int
        if let existing = slots[key] { slot = existing }
        else if let available = free.popLast() { slot = available; keys[slot] = key; slots[key] = slot }
        else { try reserve(keys.count+1); slot = keys.count; keys.append(key); parents.append(0); slots[key] = slot }
        parents[slot] = parentKey == 0 ? key : parentKey
        let normalized = LocalEmbedder.normalized(vector)
        normalized.withUnsafeBytes { matrixBuffer!.contents().advanced(by:slot*rowBytes).copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
    }
    func addBatch(_ records: [IndexedVector], threads: Int = 4) throws {
        for (i,record) in records.enumerated() {
            if i%64 == 0 { try Task.checkCancellation() }
            if let vector = record.vector { try add(record.key,vector:vector,parentKey:record.parentKey) }
        }
    }
    private struct Candidate { var key: UInt64; var parent: UInt64; var score: Float }
    private struct TopK {
        let capacity: Int
        init(capacity: Int) { self.capacity = capacity }
        var heap = [Candidate]()
        var positions = [UInt64:Int]()
        static func better(_ a: Candidate,_ b: Candidate) -> Bool { a.score != b.score ? a.score > b.score : a.key > b.key }
        mutating func swap(_ a: Int,_ b: Int) { heap.swapAt(a,b); positions[heap[a].parent] = a; positions[heap[b].parent] = b }
        mutating func sink(_ first: Int) {
            var parent = first
            while parent*2+1 < heap.count {
                let left = parent*2+1, right = left+1
                let child = right < heap.count && Self.better(heap[left],heap[right]) ? right : left
                guard Self.better(heap[parent],heap[child]) else { break }; swap(parent,child); parent = child
            }
        }
        mutating func offer(_ value: Candidate) {
            if let index = positions[value.parent] { guard Self.better(value,heap[index]) else { return }; heap[index] = value; sink(index); return }
            if heap.count < capacity {
                heap.append(value); var child = heap.count-1; positions[value.parent] = child
                while child > 0 { let parent = (child-1)/2; if !Self.better(heap[parent],heap[child]) { break }; swap(parent,child); child = parent }; return
            }
            guard Self.better(value,heap[0]) else { return }; positions.removeValue(forKey:heap[0].parent); heap[0] = value; positions[value.parent] = 0; sink(0)
        }
    }
    func search(_ vector: [Float], count: Int) throws -> [UInt64] { try search(vector,count:count,include:{ _ in true }) }
    func search(_ vector: [Float], count: Int, include: @escaping (UInt64) -> Bool) throws -> [UInt64] {
        guard vector.count == dimensions, CosineScorer(vector) != nil else { throw OSwindError.invalid("Invalid Metal index query") }
        guard !slots.isEmpty, let buffer = matrixBuffer, let scores = scoreBuffer else { return [] }
        try Task.checkCancellation()
        LocalEmbedder.normalized(vector).withUnsafeBytes { queryBuffer.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
        let matrix = MPSMatrix(buffer:buffer,descriptor:MPSMatrixDescriptor(rows:keys.count,columns:dimensions,rowBytes:rowBytes,dataType:.float32))
        let query = MPSVector(buffer:queryBuffer,descriptor:MPSVectorDescriptor(length:dimensions,dataType:.float32))
        let result = MPSVector(buffer:scores,descriptor:MPSVectorDescriptor(length:keys.count,dataType:.float32))
        guard let command = queue.makeCommandBuffer() else { throw OSwindError.unavailable("Metal command allocation failed") }
        MPSMatrixVectorMultiplication(device:device,rows:keys.count,columns:dimensions).encode(commandBuffer:command,inputMatrix:matrix,inputVector:query,resultVector:result)
        command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw OSwindError.unavailable("Metal search failed: "+(command.error?.localizedDescription ?? "incomplete GPU command")) }
        let values = scores.contents().assumingMemoryBound(to:Float.self)
        var top = TopK(capacity:min(2000,max(1,count)))
        for row in keys.indices {
            if row%4096 == 0 { try Task.checkCancellation() }
            let key = keys[row]
            if key != 0, values[row].isFinite, include(key) { top.offer(Candidate(key:key,parent:parents[row],score:values[row])) }
        }
        return top.heap.sorted(by:TopK.better).map(\.key)
    }
    private struct Header: Codable { var format: String; var dimensions: Int; var rowBytes: Int; var rows: Int; var count: Int }
    private func writeBytes(_ pointer: UnsafeRawPointer, count: Int, to file: FileHandle) throws {
        for offset in stride(from:0,to:count,by:4*1024*1024) {
            try Task.checkCancellation(); let size = min(4*1024*1024,count-offset)
            try file.write(contentsOf:Data(bytesNoCopy:UnsafeMutableRawPointer(mutating:pointer.advanced(by:offset)),count:size,deallocator:.none))
        }
    }
    func save(_ url: URL) throws {
        let header = try JSONEncoder().encode(Header(format:Self.format,dimensions:dimensions,rowBytes:rowBytes,rows:keys.count,count:slots.count))
        guard FileManager.default.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw OSwindError.unavailable("Cannot create Metal index cache") }
        let file = try FileHandle(forWritingTo:url); defer { try? file.close() }
        var length = UInt32(header.count).littleEndian
        try withUnsafeBytes(of:&length) { try file.write(contentsOf:Data($0)) }; try file.write(contentsOf:header)
        try keys.withUnsafeBytes { if let bytes = $0.baseAddress { try writeBytes(bytes,count:$0.count,to:file) } }
        try parents.withUnsafeBytes { if let bytes = $0.baseAddress { try writeBytes(bytes,count:$0.count,to:file) } }
        if let buffer = matrixBuffer { try writeBytes(buffer.contents(),count:keys.count*rowBytes,to:file) }
    }
    private func readExactly(_ count: Int, from file: FileHandle) throws -> Data {
        guard let data = try file.read(upToCount:count), data.count == count else { throw OSwindError.invalid("Truncated Metal index") }; return data
    }
    func load(_ url: URL) throws {
        try Task.checkCancellation()
        let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
        let prefix = try readExactly(4,from:file), length = prefix.withUnsafeBytes { UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self)) }
        guard length > 0, length <= 4096 else { throw OSwindError.invalid("Invalid Metal index header") }
        let header = try JSONDecoder().decode(Header.self,from:readExactly(Int(length),from:file))
        guard header.format == Self.format, header.dimensions == dimensions, header.rowBytes == rowBytes, header.rows >= 0, header.rows <= budget/(rowBytes+24), header.count >= 0, header.count <= header.rows else { throw OSwindError.invalid("Metal cache layout or memory budget mismatch") }
        let expected = 4+Int(length)+header.rows*(rowBytes+16)
        guard try file.seekToEnd() == UInt64(expected) else { throw OSwindError.invalid("Metal cache length mismatch") }; try file.seek(toOffset:UInt64(4+Int(length)))
        // Parse into a new instance; callers discard the backend if loading fails.
        keys.removeAll(); parents.removeAll(); slots.removeAll(); free.removeAll(); matrixBuffer = nil; scoreBuffer = nil; capacity = 0
        try reserve(header.rows)
        for first in stride(from:0,to:header.rows,by:4096) {
            try Task.checkCancellation(); let size = min(4096,header.rows-first)
            let bytes = try readExactly(size*8,from:file)
            try bytes.withUnsafeBytes { data in
                for i in 0..<size {
                    let key = UInt64(littleEndian:data.loadUnaligned(fromByteOffset:i*8,as:UInt64.self)), slot = first+i
                    keys.append(key)
                    if key == 0 { free.append(slot) }
                    else { guard key <= UInt64(Int64.max), slots.updateValue(slot,forKey:key) == nil else { throw OSwindError.invalid("Invalid or repeated Metal cache key") } }
                }
            }
        }
        guard slots.count == header.count else { throw OSwindError.invalid("Metal cache count mismatch") }
        for first in stride(from:0,to:header.rows,by:4096) {
            try Task.checkCancellation(); let size = min(4096,header.rows-first), bytes = try readExactly(size*8,from:file)
            try bytes.withUnsafeBytes { data in
                for i in 0..<size {
                    let parent = UInt64(littleEndian:data.loadUnaligned(fromByteOffset:i*8,as:UInt64.self))
                    guard parent <= UInt64(Int64.max), (keys[first+i] == 0) == (parent == 0) else { throw OSwindError.invalid("Invalid Metal cache parent") }; parents.append(parent)
                }
            }
        }
        if let buffer = matrixBuffer {
            let size = header.rows*rowBytes
            for offset in stride(from:0,to:size,by:4*1024*1024) {
                try Task.checkCancellation()
                try autoreleasepool {
                    let bytes = try readExactly(min(4*1024*1024,size-offset),from:file)
                    bytes.withUnsafeBytes { buffer.contents().advanced(by:offset).copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
                }
            }
            for row in keys.indices where keys[row] != 0 {
                if row%4096 == 0 { try Task.checkCancellation() }
                let vector = buffer.contents().advanced(by:row*rowBytes).assumingMemoryBound(to:Float.self)
                guard (0..<dimensions).allSatisfy({vector[$0].isFinite}) else { throw OSwindError.invalid("Nonfinite Metal cache vector") }
            }
        }
    }
}
