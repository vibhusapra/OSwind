import Foundation
import CoreGraphics

/// Reads elapsed activity only; no event tap, input contents or device changes.
public enum NativeInputActivity {
    typealias Reader = (CGEventSourceStateID,CGEventType)->TimeInterval
    public static func secondsSinceLastInput()->TimeInterval {secondsSinceLastInput(read:{CGEventSource.secondsSinceLastEventType($0,eventType:$1)})}
    static func secondsSinceLastInput(read:Reader)->TimeInterval {
        // Core Graphics defines kCGAnyInputEventType as (CGEventType)~0.
        // Null events have their own counter; their age is not user inactivity.
        let seconds=read(.combinedSessionState,CGEventType(rawValue:UInt32.max)!)
        return seconds.isFinite && seconds>=0 ? seconds:.infinity
    }
}
