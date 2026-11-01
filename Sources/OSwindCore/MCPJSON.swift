import Foundation

/// Strict, bounded wire JSON. Reject ambiguous keys before Foundation decoding
/// can silently select one value. Number spelling stays exact for review hashes.
indirect enum MCPValue:Equatable,Sendable {
    case object([String:MCPValue]),array([MCPValue]),string(String),number(String),bool(Bool),null
    var fields:[String:MCPValue]? {if case .object(let v)=self {return v};return nil}
    var items:[MCPValue]? {if case .array(let v)=self {return v};return nil}
    var text:String? {if case .string(let v)=self {return v};return nil}
    var boolean:Bool? {if case .bool(let v)=self {return v};return nil}
    subscript(_ key:String)->MCPValue? {fields?[key]}
    func encoded()->Data {
        func quote(_ s:String)->String {String(data:try! JSONEncoder().encode(s),encoding:.utf8)!}
        func render(_ v:MCPValue)->String {
            switch v {
            case .object(let x):return "{"+x.keys.sorted().map {quote($0)+":"+render(x[$0]!)}.joined(separator:",")+"}"
            case .array(let x):return "["+x.map(render).joined(separator:",")+"]"
            case .string(let s):return quote(s)
            case .number(let n):return n
            case .bool(let b):return b ? "true":"false"
            case .null:return "null"
            }
        }
        return Data(render(self).utf8)
    }
    static func decode(_ data:Data,maximum:Int=262_144)throws->Self {var p=try MCPJSONReader(data,maximum:maximum);let v=try p.value(0);p.space();guard p.offset==p.bytes.count else {throw p.bad()};return v}
}
private struct MCPJSONReader {
    let bytes:[UInt8];var offset=0,nodes=0
    init(_ data:Data,maximum:Int)throws {guard data.count<=maximum else {throw OSwindError.invalid("MCP JSON exceeds its byte limit")};bytes=Array(data)}
    func bad()->OSwindError {.invalid("MCP JSON is malformed, ambiguous or exceeds its complexity limit")}
    mutating func space() {while offset<bytes.count && [9,10,13,32].contains(bytes[offset]) {offset+=1}}
    mutating func take(_ b:UInt8)->Bool {space();guard offset<bytes.count,bytes[offset]==b else {return false};offset+=1;return true}
    mutating func string()throws->String {
        guard take(34) else {throw bad()};let start=offset;var escaped=false
        while offset<bytes.count {
            let b=bytes[offset];offset+=1
            guard offset-start<=131_072 else {throw bad()}
            if b==34 && !escaped {
                // A marker prevents Foundation dropping a leading U+FEFF.
                var raw=Data([34,64]);raw.append(contentsOf:bytes[start..<offset])
                guard let marked=try? JSONDecoder().decode(String.self,from:raw),marked.utf8.first==64 else {throw bad()}
                return String(decoding:marked.utf8.dropFirst(),as:UTF8.self)
            }
            if b==92 && !escaped {escaped=true}else {escaped=false}
        };throw bad()
    }
    mutating func value(_ depth:Int)throws->MCPValue {
        try Task.checkCancellation();nodes+=1;guard depth<=24,nodes<=10_000 else {throw bad()};space();guard offset<bytes.count else {throw bad()}
        if bytes[offset]==34 {return .string(try string())}
        if take(123) {
            var o=[String:MCPValue]()
            if take(125) {return .object(o)}
            repeat {let k=try string();guard o[k]==nil,take(58) else {throw bad()};o[k]=try value(depth+1);if take(125) {return .object(o)}}while take(44)
            throw bad()
        }
        if take(91) {var a=[MCPValue]();if take(93) {return .array(a)};repeat {a.append(try value(depth+1));if take(93) {return .array(a)}}while take(44);throw bad()}
        for (word,v) in [("true",MCPValue.bool(true)),("false",.bool(false)),("null",.null)] {
            let token=Array(word.utf8);if bytes.dropFirst(offset).starts(with:token) {offset+=token.count;return v}
        }
        let start=offset
        while offset<bytes.count && ![9,10,13,32,44,93,125].contains(bytes[offset]) {offset+=1}
        let raw=String(decoding:bytes[start..<offset],as:UTF8.self)
        guard raw.utf8.count<=128,raw.range(of:#"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,options:.regularExpression) != nil,let n=Double(raw),n.isFinite else {throw bad()}
        return .number(raw)
    }
}
