import Foundation

public enum NativeModelKind:String,Codable,CaseIterable,Sendable,Identifiable {
    case parakeet,speakers
    public var id:String { rawValue }
    public var title:String { self == .parakeet ? "Parakeet v3":"Community-1 speakers" }
    var manifestID:String { self == .parakeet ? "parakeet-v3-coreml":"speaker-community1-coreml" }
    var directoryPrefix:String { self == .parakeet ? "parakeet-v3-":"speaker-community1-" }
    public func catalog() throws -> NativeModelManifest {
        guard let json=NativeModelManifest.embeddedJSON[self] else { throw OSwindError.invalid("Native model catalog is missing") }
        let result=try JSONDecoder().decode(NativeModelManifest.self,from:Data(json.utf8));try result.validate()
        guard result.id==manifestID else { throw OSwindError.invalid("Native model catalog identity mismatch") };return result
    }
}
public struct NativeModelManifest:Codable,Equatable,Sendable {
    public struct File:Codable,Equatable,Sendable { public var path:String;public var bytes:Int64;public var sha256:String }
    public var id:String
    public var publisher:String
    public var repository:String
    public var revision:String
    public var license:String
    public var licenseURL:String
    public var attribution:String
    public var files:[File]
    enum CodingKeys:String,CodingKey { case id,publisher,repository,revision,license,attribution,files;case licenseURL="license_url" }
    public var bytes:Int64 { files.reduce(0){ let (value,overflow)=$0.addingReportingOverflow($1.bytes);return overflow ? Int64.max:value } }
    func validate() throws {
        func token(_ value:String) -> Bool { !value.isEmpty && value.utf8.count<=255 && value.utf8.allSatisfy { (48...57).contains($0)||(65...90).contains($0)||(97...122).contains($0)||[45,46,95].contains($0) } && value != "." && value != ".." }
        guard token(id),repository.split(separator:"/",omittingEmptySubsequences:false).count==2,repository.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({token(String($0))}),revision.utf8.count==40,revision.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),(1...512).contains(files.count),!publisher.isEmpty,!license.isEmpty,!attribution.isEmpty,attribution.utf8.count<65536,let url=URL(string:licenseURL),url.scheme=="https",url.host != nil,url.user==nil,url.password==nil else { throw OSwindError.invalid("Invalid native model catalog") }
        var paths=Set<String>(),folded=Set<String>(),total:Int64=0
        for file in files {
            let parts=file.path.split(separator:"/",omittingEmptySubsequences:false)
            guard (1...16).contains(parts.count),parts.allSatisfy({token(String($0))}),file.path.utf8.count<=1024,!["OSWIND-MODEL.json","ATTRIBUTION.txt"].contains(file.path),paths.insert(file.path).inserted,folded.insert(file.path.lowercased()).inserted,(0...1_073_741_824).contains(file.bytes),file.sha256.utf8.count==64,file.sha256.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),total<=8_589_934_592-file.bytes else { throw OSwindError.invalid("Invalid or oversized native model member") }
            total += file.bytes
        }
        for path in paths { var parts=path.split(separator:"/");while parts.count>1 { parts.removeLast();guard !folded.contains(parts.joined(separator:"/").lowercased()) else { throw OSwindError.invalid("A native model file conflicts with a directory") } } }
    }
    func sourceURL(for file:File) -> URL { URL(string:"https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)?download=true")! }
}
