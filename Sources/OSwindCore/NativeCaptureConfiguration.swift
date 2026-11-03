import Foundation
import ScreenCaptureKit

/// Independent-window output fills its requested raster. Native pixels cap the
/// resolution: increasing a profile limit cannot create more source detail.
/// Aspect rounding must not add padding before normalized bitmap cropping.
enum NativeCaptureConfiguration {
    static func window(size:CGSize,nativePixelScale:Double,maximumDimension:Int,evenDimensions:Bool=false)throws->SCStreamConfiguration {
        let geometry=try SnapshotRegionGeometry(size:size,region:nil,maximumDimension:maximumDimension,nativePixelScale:nativePixelScale)
        var width=geometry.outputWidth,height=geometry.outputHeight
        if evenDimensions {width=width/2*2;height=height/2*2;guard width>=2,height>=2 else {throw OSwindError.invalid("The native window is too small for replay")}}
        let configuration=SCStreamConfiguration()
        configuration.width=width;configuration.height=height
        configuration.scalesToFit=true
        // Width/height are independently rounded to whole pixels (even pixels
        // for video). Fill that exact surface rather than letterboxing it.
        configuration.preservesAspectRatio=false
        configuration.ignoreShadowsSingleWindow=true
        configuration.showsCursor=false
        configuration.captureResolution = .best
        return configuration
    }
}
