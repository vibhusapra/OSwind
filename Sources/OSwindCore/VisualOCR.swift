import Foundation
import CoreVideo
import CoreGraphics
import Vision

enum VisualOCR {
    static func regions(_ buffer:CVPixelBuffer) throws -> [TextRegion] {
        try recognize(VNImageRequestHandler(cvPixelBuffer:buffer))
    }
    static func regions(_ image:CGImage) throws -> [TextRegion] {
        try recognize(VNImageRequestHandler(cgImage:image))
    }
    private static func recognize(_ handler:VNImageRequestHandler) throws -> [TextRegion] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true;request.automaticallyDetectsLanguage=true
        try handler.perform([request])
        return (request.results ?? []).compactMap {observation in
            guard let text=observation.topCandidates(1).first?.string else {return nil}
            let b=observation.boundingBox
            return TextRegion(text:text,x:b.minX,y:b.minY,width:b.width,height:b.height)
        }
    }
}
