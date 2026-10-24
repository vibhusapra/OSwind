import Foundation
import CryptoKit
import Darwin

/// A locally converted, content-addressed pair. A checksum manifest establishes
/// local integrity, not a publisher signature. No model or tokenizer is fetched.
public struct VisualModelBundle:Codable,Sendable {
    public static let recipe="oswind-siglip2-fp32-image-fp16-text-v1"
    public static let repository="google/siglip2-base-patch16-224"
    public static let revision="75de2d55ec2d0b4efc50b3e9ad70dba96a7b2fa2"
    public static let weightsSHA256="612923381c76ec5a9bed335d1c48827e3f2e506ac31b044b63b2031fadee6a0b"
    public static let tokenizerSHA256="cb9140fae3ac5122c972d37adf83e1248471a38147ad76f8215c8872c6fd8322"
    public var formatVersion:Int
    public var conversionRecipe:String
    public var sourceWeightsSHA256:String
    public var model:NativeModelManifest

    public struct Verified:Sendable {
        public var modelID:String
        public var bundle:VisualModelBundle
        public var directory:URL
    }
    func validate() throws {
        try model.validate()
        guard formatVersion==1,conversionRecipe==Self.recipe,sourceWeightsSHA256==Self.weightsSHA256,
              model.repository==Self.repository,model.revision==Self.revision,model.license=="Apache-2.0",
              model.id=="siglip2-base-patch16-224",model.files.count<=128,
              model.files.contains(where:{$0.path=="tokenizer.json" && $0.sha256==Self.tokenizerSHA256}),
              model.files.contains(where:{$0.path=="tokenizer_config.json" && $0.sha256=="14afe629fe4959b9e0d51e1852b8d9f7ad074f90a1a7125a4fcdd17f06e78fc8"}),
              model.files.contains(where:{$0.path.hasPrefix("image.mlmodelc/")}),
              model.files.contains(where:{$0.path.hasPrefix("text.mlmodelc/")}),
              model.files.allSatisfy({$0.path.hasPrefix("image.mlmodelc/") || $0.path.hasPrefix("text.mlmodelc/") || ["tokenizer.json","tokenizer_config.json","LICENSE.txt"].contains($0.path)})
        else {throw OSwindError.invalid("Unsupported visual model bundle. Use scripts/convert-visual-model.py.")}
    }
    public static func verify(at directory:URL) throws -> Verified {
        let tree=try BackupFileTree(root:directory),data=try tree.read("OSWIND-VISION.json",limit:131072)
        let bundle=try JSONDecoder().decode(Self.self,from:data);try bundle.validate()
        var allowed=Set(bundle.model.files.map(\.path));allowed.insert("OSWIND-VISION.json")
        var directories=Set<String>()
        for file in allowed {var parts=file.split(separator:"/");while parts.count>1 {parts.removeLast();directories.insert(parts.joined(separator:"/"))}}
        var seen=Set<String>()
        func inventory(_ relative:String?=nil) throws {
            try tree.forEachEntry(in:relative) {name in
                let path=relative.map {$0+"/"+name} ?? name
                if directories.contains(path) {try inventory(path)}
                else {guard allowed.contains(path),seen.insert(path).inserted else {throw OSwindError.invalid("Unlisted visual model member: "+path)}}
            }
        }
        try inventory()
        guard seen==allowed else {throw OSwindError.invalid("Visual model files are missing")}
        for file in bundle.model.files {
            try Task.checkCancellation();let actual=try tree.digest(file.path)
            guard actual.bytes==file.bytes,actual.sha256==file.sha256 else {throw OSwindError.invalid("Visual model checksum mismatch: "+file.path)}
        }
        try tree.requireRootIdentity(at:directory)
        return Verified(modelID:"siglip2:"+SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined(),bundle:bundle,directory:directory)
    }
}
