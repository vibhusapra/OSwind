import Foundation

protocol VisualMediaSnapshot:AnyObject,Sendable {
    var plan:VisualSourcePlan {get}
    var sha256:String {get}
    var bytes:Int64 {get}
    func withAdmission<T>(for store:MemoryStore,_ body:(Memory) throws -> T) throws -> T
    func release()
}
