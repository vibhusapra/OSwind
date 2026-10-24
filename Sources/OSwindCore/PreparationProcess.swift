import Foundation
import Darwin

struct PreparationProcessResult:Sendable {var status:Int32;var stdout:Data;var stderr:Data}
/// A dedicated process group owns the conversion and every inherited child.
/// Keep the direct child unreaped until group cleanup, preventing PID reuse.
/// No shell, inherited library descriptors or ambient provider credentials.
enum PreparationProcess {
    static var guardian:URL? {
        guard let executable=Bundle.main.executableURL else {return nil}
        let candidate=executable.deletingLastPathComponent().appendingPathComponent("oswind-preparation-guardian")
        return FileManager.default.isExecutableFile(atPath:candidate.path) ? candidate:nil
    }
    static func run(_ executable:URL,_ arguments:[String],environment:[String:String],timeout:Double=3600,outputLimit:Int=4*1024*1024,guardian:URL?=nil,keepAlive:[Int32]=[],onOutput:@escaping @Sendable (Data)->Void={_ in}) async throws -> PreparationProcessResult {
        try Task.checkCancellation()
        guard executable.isFileURL,executable.path.hasPrefix("/"),!executable.path.utf8.contains(0),arguments.allSatisfy({!$0.utf8.contains(0)}),environment.allSatisfy({!$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)}),timeout>0,timeout<=7200,keepAlive.count<=8,keepAlive.allSatisfy({$0>=0}),(1...4*1024*1024).contains(outputLimit) else {throw OSwindError.invalid("Invalid preparation process configuration")}
        let job=Task.detached(priority:.utility) {() throws -> PreparationProcessResult in
            try Task.checkCancellation()
            var watch:[Int32]=[-1,-1]
            if guardian != nil {guard pipe(&watch)==0 else {throw OSwindError.unavailable("Cannot prepare the parent-death watch")};for fd in watch {_ = fcntl(fd,F_SETFD,FD_CLOEXEC)}}
            defer {for fd in watch where fd>=0 {close(fd)}}
            var out:[Int32]=[-1,-1],err:[Int32]=[-1,-1]
            guard pipe(&out)==0 else {throw OSwindError.unavailable("Cannot prepare model output pipe")}
            defer {for fd in out where fd>=0 {close(fd)}}
            guard pipe(&err)==0 else {throw OSwindError.unavailable("Cannot prepare model error pipe")}
            defer {for fd in err where fd>=0 {close(fd)}}
            let input=open("/dev/null",O_RDONLY | O_CLOEXEC);guard input>=0 else {throw OSwindError.unavailable("Cannot prepare model input")};defer {close(input)}
            for fd in out+err {_ = fcntl(fd,F_SETFD,FD_CLOEXEC)}
            var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions)==0 else {throw OSwindError.unavailable("Cannot prepare model process actions")};defer {posix_spawn_file_actions_destroy(&actions)}
            guard posix_spawnattr_init(&attributes)==0 else {throw OSwindError.unavailable("Cannot prepare model process attributes")};defer {posix_spawnattr_destroy(&attributes)}
            var mask=sigset_t(),defaults=sigset_t();sigemptyset(&mask);sigemptyset(&defaults)
            for signal in [SIGCHLD,SIGTERM,SIGINT,SIGHUP,SIGPIPE,SIGQUIT] {sigaddset(&defaults,signal)}
            guard posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))==0,posix_spawnattr_setpgroup(&attributes,0)==0,
                  posix_spawnattr_setsigmask(&attributes,&mask)==0,posix_spawnattr_setsigdefault(&attributes,&defaults)==0,
                  posix_spawn_file_actions_adddup2(&actions,input,STDIN_FILENO)==0,posix_spawn_file_actions_adddup2(&actions,out[1],STDOUT_FILENO)==0,posix_spawn_file_actions_adddup2(&actions,err[1],STDERR_FILENO)==0 else {throw OSwindError.unavailable("Cannot isolate the model process group")}
            var retained=[Int32]();defer {for fd in retained {close(fd)}}
            if guardian != nil {
                guard posix_spawn_file_actions_adddup2(&actions,watch[0],3)==0,posix_spawn_file_actions_addinherit_np(&actions,3)==0 else {throw OSwindError.unavailable("Cannot pass the parent-death watch")}
                // Stable high-numbered copies avoid overlapping dup2 sources
                // and destinations when the caller's descriptors happen to be 10+.
                for fd in keepAlive {
                    let copy=fcntl(fd,F_DUPFD_CLOEXEC,128);guard copy>=0 else {throw OSwindError.unavailable("Cannot retain a preparation reservation")};retained.append(copy)
                }
                for (index,fd) in retained.enumerated() {guard posix_spawn_file_actions_adddup2(&actions,fd,Int32(10+index))==0,posix_spawn_file_actions_addinherit_np(&actions,Int32(10+index))==0 else {throw OSwindError.unavailable("Cannot pass a preparation reservation")}}

            }
            let target=guardian ?? executable
            let parameters=guardian == nil ? arguments:["3",String(getpgrp()),"--",executable.path]+arguments
            let argv=([target.path]+parameters).map {strdup($0)},env=environment.sorted {$0.key<$1.key}.map {strdup($0.key+"="+$0.value)}
            defer {for item in argv+env {free(item)}}
            var argvPointers=argv+[nil],envPointers=env+[nil],pid:pid_t=0
            let spawned=posix_spawn(&pid,target.path,&actions,&attributes,&argvPointers,&envPointers)
            guard spawned==0,pid>0 else {throw OSwindError.unavailable("Cannot start local model preparation (system error \(spawned))")}
            close(out[1]);out[1] = -1;close(err[1]);err[1] = -1
            for fd in [out[0],err[0]] {_ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK)}
            var reaped=false,stdout=Data(),stderr=Data()
            func drain(_ fd:Int32,_ buffer:inout Data,emit:Bool) throws {
                var bytes=[UInt8](repeating:0,count:16384),total=0
                while total<256*1024 {
                    let count=read(fd,&bytes,bytes.count)
                    if count<0 && errno==EINTR {continue};guard count>0 else {break}
                    guard count<=outputLimit-buffer.count else {throw OSwindError.unavailable("Local model preparation output exceeded its limit")}
                    let data=Data(bytes.prefix(count));buffer.append(data);if emit {onOutput(data)};total+=count
                }
            }
            func exited() throws -> Bool {
                var info=siginfo_t()
                guard waitid(P_PID,id_t(pid),&info,WEXITED | WNOHANG | WNOWAIT)==0 else {throw OSwindError.unavailable("Cannot inspect local model preparation")}
                return info.si_pid==pid
            }
            func reap() {
                var status:Int32=0
                while waitpid(pid,&status,0)<0 && errno==EINTR {}
                reaped=true
            }
            defer {
                if !reaped {
                    // Signal while the child PID is still reserved, then reap.
                    kill(-pid,SIGTERM);kill(pid,SIGTERM);let deadline=ProcessInfo.processInfo.systemUptime+1
                    while ProcessInfo.processInfo.systemUptime<deadline {
                        if (try? exited())==true {break};Thread.sleep(forTimeInterval:0.01)
                    }
                    kill(-pid,SIGKILL);kill(pid,SIGKILL);reap()
                }
            }
            let deadline=ContinuousClock.now.advanced(by:.seconds(timeout))
            while true {
                try drain(out[0],&stdout,emit:true);try drain(err[0],&stderr,emit:false)
                try Task.checkCancellation();guard ContinuousClock.now<deadline else {throw OSwindError.unavailable("Local model preparation timed out; its process group was stopped")}
                if try exited() {break};Thread.sleep(forTimeInterval:0.02)
            }
            // A completed parent must not leave background descendants alive.
            kill(-pid,SIGKILL)
            for _ in 0..<32 {try drain(out[0],&stdout,emit:true);try drain(err[0],&stderr,emit:false)}
            var status:Int32=0,result:pid_t
            repeat {result=waitpid(pid,&status,0)} while result<0 && errno==EINTR
            guard result==pid else {throw OSwindError.unavailable("Cannot finish local model preparation")};reaped=true
            try Task.checkCancellation()
            let code=(status & 0x7f)==0 ? (status>>8)&0xff:128+(status & 0x7f)
            return .init(status:code,stdout:stdout,stderr:stderr)
        }
        let result=try await withTaskCancellationHandler {try await job.value} onCancel:{job.cancel()}
        try Task.checkCancellation();return result
    }
}
