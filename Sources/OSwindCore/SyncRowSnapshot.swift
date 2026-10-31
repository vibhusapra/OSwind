import Foundation
import CSQLite
import CryptoKit

/// A local mutation intent, never an approved peer payload. Preserve SQLite
/// storage classes and raw UTF-8/IEEE bits; adapters must validate/sanitize it.
enum SyncRowCell:Equatable,Sendable {
    case null,integer(Int64),real(UInt64),text(Data),blob(Data)
}
struct SyncRowSnapshot:Equatable,Sendable {
    static let maximumBytes=136*1024*1024
    let cells:[SyncRowCell]
    init(_ cells:[SyncRowCell])throws {
        guard (1...32).contains(cells.count) else {throw OSwindError.invalid("Invalid sync row width")}
        self.cells=cells
    }
    func encoded()throws->Data {
        var result=Data([0x4f,0x57,0x53,0x52,1,UInt8(cells.count)])
        func number(_ value:UInt64) {var value=value.littleEndian;withUnsafeBytes(of:&value) {result.append(contentsOf:$0)}}
        for cell in cells {
            switch cell {
            case .null:result.append(0)
            case .integer(let value):result.append(1);number(UInt64(bitPattern:value))
            case .real(let bits):guard Double(bitPattern:bits).isFinite else {throw OSwindError.invalid("Nonfinite sync row value")};result.append(2);number(bits)
            case .text(let bytes),.blob(let bytes):
                guard bytes.count<=Self.maximumBytes,result.count<=Self.maximumBytes-9-bytes.count else {throw OSwindError.invalid("Sync row exceeds its bound")}
                if case .text=cell {result.append(3)}else{result.append(4)}
                number(UInt64(bytes.count));result.append(bytes)
            }
            guard result.count<=Self.maximumBytes else {throw OSwindError.invalid("Sync row exceeds its bound")}
        }
        return result
    }
    static func decode(_ data:Data)throws->Self {
        guard data.count>=7,data.count<=maximumBytes,Array(data.prefix(5))==[0x4f,0x57,0x53,0x52,1],(1...32).contains(Int(data[data.startIndex+5])) else {throw OSwindError.invalid("Invalid sync row frame")}
        var offset=6,cells=[SyncRowCell]()
        func number()throws->UInt64 {
            guard offset<=data.count-8 else {throw OSwindError.invalid("Truncated sync row")}
            var value:UInt64=0;for i in 0..<8 {value |= UInt64(data[data.startIndex+offset+i]) << (i*8)};offset+=8;return value
        }
        for _ in 0..<data[data.startIndex+5] {
            guard offset<data.count else {throw OSwindError.invalid("Truncated sync row")}
            let tag=data[data.startIndex+offset];offset+=1
            switch tag {
            case 0:cells.append(.null)
            case 1:cells.append(.integer(Int64(bitPattern:try number())))
            case 2:
                let bits=try number();guard Double(bitPattern:bits).isFinite else {throw OSwindError.invalid("Nonfinite sync row value")};cells.append(.real(bits))
            case 3,4:
                let count=try number();guard count<=UInt64(data.count-offset) else {throw OSwindError.invalid("Truncated sync row bytes")}
                let bytes=Data(data[(data.startIndex+offset)..<(data.startIndex+offset+Int(count))]);offset+=Int(count)
                cells.append(tag==3 ? .text(bytes):.blob(bytes))
            default:throw OSwindError.invalid("Unknown sync row storage class")
            }
        }
        guard offset==data.count else {throw OSwindError.invalid("Trailing sync row bytes")}
        return try Self(cells)
    }
    static func register(on db:RoutineDatabase)throws {
        try SyncVersionStore.register(on:db)
        try HistoricalEvidenceStore.registerWriter(db)
        let flags=SQLITE_UTF8|SQLITE_DETERMINISTIC|SQLITE_INNOCUOUS
        guard sqlite3_create_function_v2(db.handle,"oswind_sync_row_v1",-1,flags,nil,{context,count,values in
            SyncRowSnapshot.result(context,count,values,key:false)
        },nil,nil,nil)==SQLITE_OK else {throw db.error()}
        guard sqlite3_create_function_v2(db.handle,"oswind_sync_key_v1",-1,flags,nil,{context,count,values in
            SyncRowSnapshot.result(context,count,values,key:true)
        },nil,nil,nil)==SQLITE_OK else {throw db.error()}
    }
    private static func result(_ context:OpaquePointer?,_ count:Int32,_ values:UnsafeMutablePointer<OpaquePointer?>?,key:Bool) {
        guard let context,let values,(1...32).contains(count) else {sqlite3_result_error(context,"Invalid sync row width",-1);return}
        do {
            var cells=[SyncRowCell](),bytes=0
            let limit=key ? SyncProtocolLimits.operationBytes:maximumBytes
            for index in 0..<Int(count) {
                guard let value=values[index] else {throw OSwindError.invalid("Invalid SQLite row value")}
                let kind=sqlite3_value_type(value)
                guard !key || kind==SQLITE_INTEGER || kind==SQLITE_TEXT else {throw OSwindError.invalid("Invalid canonical row key")}
                switch kind {
                case SQLITE_NULL:cells.append(.null)
                case SQLITE_INTEGER:cells.append(.integer(sqlite3_value_int64(value)))
                case SQLITE_FLOAT:cells.append(.real(sqlite3_value_double(value).bitPattern))
                case SQLITE_TEXT,SQLITE_BLOB:
                    let text=kind==SQLITE_TEXT
                    let pointer=text ? sqlite3_value_text(value).map(UnsafeRawPointer.init):sqlite3_value_blob(value)
                    let size=Int(sqlite3_value_bytes(value));guard size>=0,size<=limit,bytes<=limit-size,!key || size>0 else {throw OSwindError.invalid("Sync row exceeds its bound")}
                    guard size==0 || pointer != nil else {throw OSwindError.invalid("Missing SQLite row bytes")}
                    let data=size==0 ? Data():Data(bytes:pointer!,count:size);bytes+=size
                    cells.append(text ? .text(data):.blob(data))
                default:throw OSwindError.invalid("Unsupported SQLite row storage class")
                }
            }
            let encoded=try SyncRowSnapshot(cells).encoded()
            let data=key ? Data(SHA256.hash(data:encoded)):encoded;guard data.count<=limit else {throw OSwindError.invalid("Oversized sync row")}
            data.withUnsafeBytes {sqlite3_result_blob(context,$0.baseAddress,Int32($0.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
        }catch {sqlite3_result_error(context,"Invalid or oversized sync row snapshot",-1)}
    }
}
