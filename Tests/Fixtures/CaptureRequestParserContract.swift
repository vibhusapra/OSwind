import Foundation

@main struct CaptureRequestParserContract {
    static func main()throws {
        var checks=[String]()
        func require(_ value:Bool,_ label:String)throws {guard value else {throw NSError(domain:"OwnedCaptureParserContract",code:1,userInfo:[NSLocalizedDescriptionKey:label])};checks.append(label)}
        let target="com.oswind.fixture-Mac_3",root="/owned library with spaces",vault="/owned vault.oswindvault"
        for command in ["capture","capture-text","capture-replay"] {
            let seconds=command=="capture-replay" ? ["--seconds","1"]:[]
            let explicit=["--app-bundle",target]+seconds
            let parsed=try CaptureCLIRequest.parse(command:command,arguments:explicit,invocation:["--data",root,command]+explicit)
            try require(parsed?.targetBundleID?.utf8.elementsEqual(target.utf8)==true,command+" retains exact explicit target bytes")
            try require(parsed?.seconds==(command=="capture-replay" ? 1:nil),command+" preserves intended duration")
            let current=try CaptureCLIRequest.parse(command:command,arguments:seconds,invocation:[command]+seconds)
            try require(current != nil && current?.targetBundleID==nil,command+" allows current window only when target was omitted")
            let withVault=try CaptureCLIRequest.parse(command:command,arguments:explicit,invocation:[command]+explicit+["--vault",vault])
            try require(withVault?.targetBundleID==target,command+" preserves target with a spaced vault path")
            for invalid in [["--app-bundle"],["--app-bundle",""],["--app-bundle","--unknown"],["--app-bundle",target,"--app-bundle","other"],["--unknown"],["extra"]] {
                var refused=false
                do {_=try CaptureCLIRequest.parse(command:command,arguments:seconds+invalid,invocation:["--data",root,command]+seconds+invalid)}catch {refused=true}
                try require(refused,command+" refuses malformed intent "+String(checks.count))
            }
        }
        for value in ["1","1e0","120","120.0"] {
            let parsed=try CaptureCLIRequest.parse(command:"capture-replay",arguments:["--seconds",value,"--app-bundle",target],invocation:["capture-replay","--seconds",value,"--app-bundle",target])
            try require(parsed?.seconds==Double(value) && parsed?.targetBundleID==target,"replay preserves finite bound "+value)
        }
        for value in ["NaN","inf","-inf","-1","0","0.99","120.01"] {
            var refused=false
            do {_=try CaptureCLIRequest.parse(command:"capture-replay",arguments:["--seconds",value],invocation:["capture-replay","--seconds",value])}catch {refused=true}
            try require(refused,"replay refuses invalid duration "+value)
        }
        for command in ["note","stats","config","pii","help"] {
            let parsed=try CaptureCLIRequest.parse(command:command,arguments:["--app-bundle","","--unknown"],invocation:[command,"--data"])
            try require(parsed==nil,"non-capture "+command+" keeps its own argument semantics")
        }
        let data=try JSONSerialization.data(withJSONObject:["format":"OSwind actual capture-parser contract v1","passed":true,"checks":checks],options:[.sortedKeys,.prettyPrinted]);print(String(decoding:data,as:UTF8.self))
    }
}
