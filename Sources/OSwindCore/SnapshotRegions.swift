import Foundation
import CoreGraphics
import ColorSync

/// Coordinates are fractions of the source, measured from its top-left corner.
public struct SnapshotRegion:Codable,Equatable,Sendable {
    public var x:Double,y:Double,width:Double,height:Double
    public init(x:Double=0,y:Double=0,width:Double=1,height:Double=1){self.x=x;self.y=y;self.width=width;self.height=height}
    public var valid:Bool {[x,y,width,height].allSatisfy(\.isFinite) && x>=0 && y>=0 && width>0 && height>0 && x<1 && y<1 && x+width<=1+1e-12 && y+height<=1+1e-12}
    public func rect(in size:CGSize) throws -> CGRect {
        guard valid,size.width.isFinite,size.height.isFinite,size.width>0,size.height>0 else {throw OSwindError.invalid("Choose a crop entirely inside its source")}
        let rect=CGRect(x:x*size.width,y:y*size.height,width:(min(1,x+width)-x)*size.width,height:(min(1,y+height)-y)*size.height)
        guard rect.width>=1,rect.height>=1 else {throw OSwindError.invalid("The crop is smaller than one source point")}
        return rect
    }
    /// Round inward so a fractional edge cannot add pixels outside the crop.
    public func crop(_ image:CGImage) throws -> CGImage {
        let rect=try rect(in:CGSize(width:image.width,height:image.height)),left=ceil(rect.minX),top=ceil(rect.minY),right=floor(rect.maxX),bottom=floor(rect.maxY)
        guard right>left,bottom>top,let cropped=image.cropping(to:CGRect(x:left,y:top,width:right-left,height:bottom-top)) else {throw OSwindError.invalid("The crop contains no complete pixels")}
        return cropped
    }
}
public struct SnapshotRegionSettings:Codable,Equatable,Sendable {
    public private(set) var blocked=false
    /// nil means every attached display; an empty selection captures none.
    public var selectedDisplays:[String]?=nil
    public var displayCrops:[String:SnapshotRegion]=[:]
    public var focusedWindowCrop:SnapshotRegion?=nil
    public init(){}
    public static var disabled:Self {var value=Self();value.selectedDisplays=[];value.blocked=true;return value}
    public var valid:Bool {
        let selected=selectedDisplays ?? []
        return !blocked && selected.count<=32 && Set(selected).count==selected.count && selected.allSatisfy {Self.canonicalID($0)==$0} && displayCrops.count<=32 && displayCrops.allSatisfy {Self.canonicalID($0.key)==$0.key && $0.value.valid} && (focusedWindowCrop?.valid ?? true)
    }
    public static func canonicalID(_ value:String)->String? {UUID(uuidString:value)?.uuidString}
    public static func displayID(_ display:CGDirectDisplayID)->String? {
        guard let uuid=CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else {return nil}
        return canonicalID(CFUUIDCreateString(nil,uuid) as String)
    }
    public func includes(_ identifier:String)->Bool {valid && (selectedDisplays.map {$0.contains(identifier)} ?? true)}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        blocked=try c.decodeIfPresent(Bool.self,forKey:.blocked) ?? false
        selectedDisplays=try c.decodeIfPresent([String].self,forKey:.selectedDisplays)
        displayCrops=try c.decodeIfPresent([String:SnapshotRegion].self,forKey:.displayCrops) ?? [:]
        focusedWindowCrop=try c.decodeIfPresent(SnapshotRegion.self,forKey:.focusedWindowCrop)
        if let selected=selectedDisplays {
            selectedDisplays=try selected.map {guard let key=Self.canonicalID($0) else {throw OSwindError.invalid("Invalid selected display identity")};return key}
        }
        var canonical=[String:SnapshotRegion]()
        for (key,region) in displayCrops {
            guard let key=Self.canonicalID(key),canonical[key]==nil else {throw OSwindError.invalid("Invalid or repeated display crop identity")};canonical[key]=region
        }
        displayCrops=canonical
        guard valid else {throw OSwindError.invalid("Invalid display or crop selection")}
    }
}
/// Pure geometry used by the native source and owned fixtures. Global display
/// origins are deliberately absent: sourceRect is local to the display.
struct SnapshotRegionGeometry:Equatable {
    var sourceRect:CGRect
    var outputWidth:Int
    var outputHeight:Int
    init(size:CGSize,region:SnapshotRegion?,maximumDimension:Int) throws {
        guard maximumDimension>0,maximumDimension<=8192 else {throw OSwindError.invalid("Invalid snapshot output size")}
        let rect=try (region ?? SnapshotRegion()).rect(in:size),scale=min(2,Double(maximumDimension)/max(rect.width,rect.height))
        sourceRect=rect;outputWidth=max(1,Int(floor(rect.width*scale)));outputHeight=max(1,Int(floor(rect.height*scale)))
    }
}

struct SnapshotDisplayDescriptor:Equatable,Sendable {
    var identifier:String
    var displayID:UInt32
    var frame:CGRect
    var size:CGSize
    func current(in displays:[Self])->Bool {
        let matches=displays.filter {$0.identifier==identifier}
        return matches.count==1 && matches[0]==self
    }
}
extension SnapshotRegionSettings {
    func resolved(_ displays:[SnapshotDisplayDescriptor]) throws -> [SnapshotDisplayDescriptor] {
        guard valid else {throw OSwindError.invalid("Invalid display selection")}
        let selected=displays.filter {includes($0.identifier)}
        guard Set(selected.map(\.identifier)).count==selected.count,Set(selected.map(\.displayID)).count==selected.count else {throw OSwindError.invalid("Selected display identities are ambiguous")}
        return selected
    }
}
