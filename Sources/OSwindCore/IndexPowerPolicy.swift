import Foundation

struct IndexBuildDeferred: LocalizedError {
    var reason: String
    var errorDescription: String? { reason }
}
enum IndexPowerPolicy {
    static func blockedReason(lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState, allowLowPower: Bool) -> String? {
        if thermal == .serious || thermal == .critical { return "Fast index build deferred while the Mac is hot; source vectors are retained" }
        if lowPower && !allowLowPower { return "Fast index build deferred in Low Power Mode; source vectors are retained" }
        return nil
    }
}
