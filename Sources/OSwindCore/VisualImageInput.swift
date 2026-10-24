import Foundation
import CoreGraphics
import ImageIO

/// Matches the pinned processor's RGB, antialiased bilinear resize and NCHW
/// normalization. The separable 22-bit coefficient convention follows Pillow;
/// see ThirdParty/Pillow/LICENSE. No temporary image is written.
public enum VisualImageInput {
    public static let side=224
    public static func pixels(data:Data) throws -> [Float] {
        guard data.count<=64*1024*1024,let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetCount(source)==1,
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=16384,height<=16384,width*height<=16_777_216,
              (properties[kCGImagePropertyOrientation] as? Int ?? 1)==1,
              let image=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCache:false] as CFDictionary)
        else {throw OSwindError.invalid("Use an upright, single-frame image of at most 16 megapixels and 64 MiB")}
        return try pixels(image:image)
    }
    public static func pixels(image:CGImage) throws -> [Float] {
        let width=image.width,height=image.height
        guard width>0,height>0,width<=16384,height<=16384,width*height<=16_777_216 else {throw OSwindError.invalid("Image exceeds the visual encoder's pixel limit")}
        try Task.checkCancellation()
        var rgba=[UInt8](repeating:0,count:width*height*4)
        let success=rgba.withUnsafeMutableBytes {bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {return false}
            context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
            context.interpolationQuality = .none;context.setBlendMode(.normal)
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard success else {throw OSwindError.unavailable("Cannot decode visual model input")}
        let rgb=try resizedRGB(rgba:rgba,width:width,height:height)
        var output=[Float](repeating:0,count:3*side*side)
        for i in 0..<(side*side) {for channel in 0..<3 {output[channel*side*side+i]=(Float(rgb[i*3+channel])/255-0.5)/0.5}}
        return output
    }
    private struct Filter {var first:Int;var weights:[Int]}
    private static func filters(_ input:Int,_ output:Int) -> [Filter] {
        let scale=Double(input)/Double(output),support=max(1,scale)
        return (0..<output).map {i in
            let center=(Double(i)+0.5)*scale,first=max(0,Int(center-support+0.5)),last=min(input,Int(center+support+0.5))
            let values=(first..<last).map {j in max(0,1-abs((Double(j)-center+0.5)/support))},sum=values.reduce(0,+)
            return Filter(first:first,weights:values.map {Int($0/sum*Double(1<<22)+0.5)})
        }
    }
    /// Internal for exact RGB parity tests, independent of platform decoding.
    static func resizedRGB(rgba:[UInt8],width:Int,height:Int) throws -> [UInt8] {
        guard width>0,height>0,width<=16384,height<=16384,width*height<=16_777_216,rgba.count==width*height*4 else {throw OSwindError.invalid("Invalid visual RGB dimensions")}
        let horizontal=filters(width,side),vertical=filters(height,side)
        var rowImage=[UInt8](repeating:0,count:side*height*3)
        for y in 0..<height {
            if y%64==0 {try Task.checkCancellation()}
            for x in 0..<side {let f=horizontal[x];for c in 0..<3 {
                var sum=1<<21
                for (k,w) in f.weights.enumerated() {sum += Int(rgba[(y*width+f.first+k)*4+c])*w}
                rowImage[(y*side+x)*3+c]=UInt8(clamping:sum>>22)
            }}
        }
        var rgb=[UInt8](repeating:0,count:side*side*3)
        for y in 0..<side {
            if y%32==0 {try Task.checkCancellation()}
            let f=vertical[y]
            for x in 0..<side {for c in 0..<3 {
                var sum=1<<21
                for (k,w) in f.weights.enumerated() {sum += Int(rowImage[((f.first+k)*side+x)*3+c])*w}
                rgb[(y*side+x)*3+c]=UInt8(clamping:sum>>22)
            }}
        }
        return rgb
    }
}
