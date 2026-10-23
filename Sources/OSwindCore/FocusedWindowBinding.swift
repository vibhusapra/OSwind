import Foundation
import CoreGraphics

struct CaptureWindowDescriptor:Sendable {
    var frame:CGRect
    var title:String?
}
enum FocusedWindowBinding {
    /// Explicit focus evidence may narrow the candidates, never authorize a
    /// different window when the focused one is absent/unshareable.
    static func select(_ candidates:[CaptureWindowDescriptor],context:WindowContext)->Int? {
        let matches=candidates.indices.filter {index in
            let window=candidates[index]
            if let bounds=context.bounds {
                guard [bounds.minX,bounds.minY,bounds.width,bounds.height,window.frame.minX,window.frame.minY,window.frame.width,window.frame.height].allSatisfy(\.isFinite),bounds.width>0,bounds.height>0 else {return false}
                return abs(window.frame.minX-bounds.minX)<4 && abs(window.frame.minY-bounds.minY)<4 && abs(window.frame.width-bounds.width)<4 && abs(window.frame.height-bounds.height)<4
            }
            if !context.title.isEmpty {return window.title==context.title}
            return candidates.count==1
        }
        return matches.count==1 ? matches[0]:nil
    }
}
