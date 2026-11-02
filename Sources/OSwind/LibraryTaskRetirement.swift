import Foundation

/// Retain canceled actor completions until their actual detached work returns.
/// Replacing a public task slot cannot acknowledge storage departure.
@MainActor final class LibraryTaskRetirement {
    private var pending=[UUID:Task<Void,Never>]()
    private var drains=0
    var accepting:Bool {drains==0}
    func hold(_ task:Task<Void,Never>?) {
        guard let task else {return};let id=UUID()
        pending[id]=Task {[weak self] in await task.value;self?.pending[id]=nil}
    }
    func retire(_ task:Task<Void,Never>?) {task?.cancel();hold(task)}
    func drain()async {
        drains+=1;defer {drains-=1}
        while !pending.isEmpty {for task in Array(pending.values) {await task.value}}
    }
}
