import Foundation
import Darwin

struct ExternalToolProcessFailure:LocalizedError {
    let message:String,output:String
    var errorDescription:String? { message }
}

/// Native argv avoids Foundation's filesystem normalization of arbitrary argument text.
enum ExternalToolProcess {
    static func run(_ plan:ExternalToolPlan,invocation:Int,token:CancellationToken) throws -> String {
        let call = plan.invocations[invocation]
        func checked(_ result:Int32) throws { guard result == 0 else { throw CommanderError.message("Werkzeugstart: "+String(cString:strerror(result))) } }
        let directory = open(call.directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard directory >= 0 else { throw CommanderError.message("Arbeitsordner kann nicht geöffnet werden.") };defer { close(directory) }
        var directoryStat = stat();guard fstat(directory,&directoryStat) == 0,call.observations.contains(where:{ $0.url == call.directory && $0.version.sameObject(RenameVersion(directoryStat)) }) else { throw CommanderError.message("Arbeitsordner wurde vor dem Start ausgetauscht.") }
        var capture:[Int32] = [-1,-1]
        guard pipe(&capture) == 0 else { throw CommanderError.message("Private Werkzeugausgabe kann nicht angelegt werden.") }
        let output = capture[0];var writer = capture[1]
        defer { close(output);if writer >= 0 { close(writer) } }
        guard fcntl(output,F_SETFD,FD_CLOEXEC) == 0,fcntl(writer,F_SETFD,FD_CLOEXEC) == 0,
              fcntl(output,F_SETFL,fcntl(output,F_GETFL)|O_NONBLOCK) == 0 else { throw CommanderError.message("Private Werkzeugausgabe kann nicht abgesichert werden.") }
        let null = open("/dev/null",O_RDONLY|O_CLOEXEC);guard null >= 0 else { throw CommanderError.message("Standardeingabe kann nicht geöffnet werden.") };defer { close(null) }
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions));defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes));defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions,null,STDIN_FILENO));try checked(posix_spawn_file_actions_adddup2(&actions,writer,STDOUT_FILENO));try checked(posix_spawn_file_actions_adddup2(&actions,writer,STDERR_FILENO))
        if #available(macOS 26.0,*) { try checked(posix_spawn_file_actions_addfchdir(&actions,directory)) }
        else { try checked(posix_spawn_file_actions_addfchdir_np(&actions,directory)) }
        try checked(posix_spawnattr_setpgroup(&attributes,0))
        var mask = sigset_t();sigemptyset(&mask);try checked(posix_spawnattr_setsigmask(&attributes,&mask))
        var defaults = sigset_t();sigemptyset(&defaults);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);sigaddset(&defaults,SIGPIPE);try checked(posix_spawnattr_setsigdefault(&attributes,&defaults))
        try checked(posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF)))
        let argumentStrings = [plan.target.path]+call.arguments
        var environment = ProcessInfo.processInfo.environment;environment["PWD"] = call.directory.path
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { $0.key+"="+$0.value }
        guard !environmentStrings.contains(where:{ $0.contains("\0") }) else { throw CommanderError.message("Ungültige Prozessumgebung.") }
        var argv = argumentStrings.map { strdup($0) },envp = environmentStrings.map { strdup($0) }
        defer { for value in argv { free(value) };for value in envp { free(value) } }
        guard argv.allSatisfy({ $0 != nil }),envp.allSatisfy({ $0 != nil }) else { throw CommanderError.message("Nicht genug Speicher für den Werkzeugaufruf.") }
        argv.append(nil);envp.append(nil);try token.check();try ExternalToolPlanner.validate(plan,invocation:invocation)
        var child:pid_t = 0
        let launch = argv.withUnsafeMutableBufferPointer { args in envp.withUnsafeMutableBufferPointer { env in posix_spawn(&child,plan.target.path,&actions,&attributes,args.baseAddress!,env.baseAddress!) } }
        try checked(launch)
        close(writer);writer = -1
        var status:Int32 = 0,stopped:String?,sentAt:TimeInterval?,reaped = false
        let started = ProcessInfo.processInfo.systemUptime;var pausedDuration:TimeInterval = 0
        var eof = false,totalBytes:Int64 = 0,stored = Data(),buffer = [UInt8](repeating:0,count:65_536)
        defer {
            if !reaped { kill(-child,SIGKILL);while waitpid(child,&status,0) < 0 && errno == EINTR {} }
        }
        while true {
            // Drain a bounded batch before checking cancellation and active time.
            // Keeping the direct child unreaped until EOF also reserves its PID/
            // process-group identity while descendants still own the capture pipe.
            if !eof {
                for _ in 0..<8 {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(output,$0.baseAddress,$0.count) }
                    if count > 0 {
                        totalBytes += Int64(count)
                        if stored.count < 4*1024*1024 { stored.append(contentsOf:buffer.prefix(min(count,4*1024*1024-stored.count))) }
                        if totalBytes > 32*1024*1024,stopped == nil { stopped = "Werkzeug wegen mehr als 32 MiB Textausgabe angehalten.";kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime;break }
                    } else if count == 0 { eof = true;break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else { throw CommanderError.message("Werkzeugausgabe kann nicht gelesen werden.") }
                }
            }
            if eof {
                if stopped != nil { kill(-child,SIGKILL) }
                let waited = waitpid(child,&status,WNOHANG)
                if waited == child { reaped = true;break }
                if waited < 0 { if errno == EINTR { continue };if errno == ECHILD { reaped = true };throw CommanderError.message("Werkzeugstatus kann nicht gelesen werden.") }
            }
            if stopped == nil,token.isPaused {
                let pausedAt = ProcessInfo.processInfo.systemUptime;kill(-child,SIGSTOP)
                do { try token.check() } catch { stopped = "Werkzeugaufruf abgebrochen." }
                pausedDuration += ProcessInfo.processInfo.systemUptime-pausedAt;kill(-child,SIGCONT)
                if stopped != nil { kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime }
            }
            if stopped == nil {
                if token.isCancelled { stopped = "Werkzeugaufruf abgebrochen." }
                else if ProcessInfo.processInfo.systemUptime-started-pausedDuration >= TimeInterval(plan.tool.timeoutSeconds) { stopped = "Zeitlimit für das Werkzeug erreicht." }
                if stopped != nil { kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime }
            }
            if let sentAt,ProcessInfo.processInfo.systemUptime-sentAt >= 0.5 { kill(-child,SIGKILL) }
            if let sentAt,ProcessInfo.processInfo.systemUptime-sentAt >= 1 {
                // An independently detached writer may keep a pipe open. Closing
                // our read end bounds capture; it cannot retain a growing file.
                kill(-child,SIGKILL);while true { let waited = waitpid(child,&status,0);if waited == child { reaped = true;break };if waited < 0,errno == EINTR { continue };if waited < 0,errno == ECHILD { reaped = true };throw CommanderError.message("Werkzeugstatus kann nicht gelesen werden.") };break
            }
            Thread.sleep(forTimeInterval:0.025)
        }
        let text = String(decoding:stored,as:UTF8.self)+(totalBytes > 4*1024*1024 ? "\n[Ausgabe auf 4 MiB begrenzt]" : "")
        if let stopped { throw ExternalToolProcessFailure(message:stopped,output:text) }
        let signal = status & 0x7f,exitCode = (status >> 8) & 0xff
        guard signal == 0,exitCode == 0 else { throw ExternalToolProcessFailure(message:"Werkzeug endete "+(signal == 0 ? "mit Status \(exitCode)" : "durch Signal \(signal)"),output:text) }
        return text
    }
}
