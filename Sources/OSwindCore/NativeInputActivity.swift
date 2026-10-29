import Foundation
import CoreGraphics

/// Reads elapsed activity only; no event tap, input contents or device changes.
enum NativeInputActivity {
    typealias Reader = (CGEventSourceStateID,CGEventType)->TimeInterval
    static func secondsSinceLastInput(read:Reader={CGEventSource.secondsSinceLastEventType($0,eventType:$1)})->TimeInterval {
        // Core Graphics defines kCGAnyInputEventType as (CGEventType)~0.
        // Null events have their own counter; their age is not user inactivity.
        let seconds=read(.combinedSessionState,CGEventType(rawValue:UInt32.max)!)
        return seconds.isFinite && seconds>=0 ? seconds:.infinity
    }
}
