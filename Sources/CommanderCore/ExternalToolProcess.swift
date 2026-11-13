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
        guard let expected = call.observations.first(where:{ $0.url == call.directory })?.version else { throw CommanderError.message("Arbeitsordnerbeleg fehlt.") }
        return try NativeProcessCapture.run(executable:plan.target.path,arguments:call.arguments,directory:call.directory,input:nil,token:token,timeout:TimeInterval(plan.tool.timeoutSeconds),expectedDirectory:expected,validate:{ try ExternalToolPlanner.validate(plan,invocation:invocation) })
    }
}

enum NativeProcessCapture {
    static func run(executable:String,arguments:[String],directory requestedDirectory:URL?,input:Data?,token:CancellationToken,timeout:TimeInterval,expectedDirectory:RenameVersion? = nil,validate:()throws->Void = {}) throws -> String {
        func checked(_ result:Int32) throws { guard result == 0 else { throw CommanderError.message("Werkzeugstart: "+String(cString:strerror(result))) } }
        guard !executable.isEmpty,!executable.contains("\0"),arguments.allSatisfy({ !$0.contains("\0") }),timeout.isFinite,timeout > 0 else { throw CommanderError.message("Programm, Argumente und ein positives endliches Zeitlimit angeben.") }
        let target = URL(fileURLWithPath:executable),location = requestedDirectory ?? URL(fileURLWithPath:FileManager.default.currentDirectoryPath,isDirectory:true)
        guard location.isFileURL,location.host == nil || location.host == "" || location.host == "localhost",!location.path.contains("\0") else { throw CommanderError.message("Ein lokaler Arbeitsordner wird benötigt.") }
        let directory = open(location.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|(expectedDirectory == nil ? 0 : O_NOFOLLOW))
        guard directory >= 0 else { throw CommanderError.message("Arbeitsordner kann nicht geöffnet werden.") };defer { close(directory) }
        var directoryStat = stat();guard fstat(directory,&directoryStat) == 0,expectedDirectory?.sameObject(RenameVersion(directoryStat)) ?? true else { throw CommanderError.message("Arbeitsordner wurde vor dem Start ausgetauscht.") }
        var capture:[Int32] = [-1,-1]
        guard pipe(&capture) == 0 else { throw CommanderError.message("Private Werkzeugausgabe kann nicht angelegt werden.") }
        let output = capture[0];var writer = capture[1]
        defer { close(output);if writer >= 0 { close(writer) } }
        guard fcntl(output,F_SETFD,FD_CLOEXEC) == 0,fcntl(writer,F_SETFD,FD_CLOEXEC) == 0,
              fcntl(output,F_SETFL,fcntl(output,F_GETFL)|O_NONBLOCK) == 0 else { throw CommanderError.message("Private Werkzeugausgabe kann nicht abgesichert werden.") }
        var stdinRead:Int32 = -1,stdinWriter:Int32 = -1,inputOffset = 0
        defer { if stdinRead >= 0 { close(stdinRead) };if stdinWriter >= 0 { close(stdinWriter) } }
        if let input {
            var descriptors:[Int32] = [-1,-1];guard pipe(&descriptors) == 0 else { throw CommanderError.message("Standardeingabe kann nicht angelegt werden.") };stdinRead = descriptors[0];stdinWriter = descriptors[1]
            guard fcntl(stdinRead,F_SETFD,FD_CLOEXEC) == 0,fcntl(stdinWriter,F_SETFD,FD_CLOEXEC) == 0,fcntl(stdinWriter,F_SETNOSIGPIPE,1) == 0,
                  fcntl(stdinWriter,F_SETFL,fcntl(stdinWriter,F_GETFL)|O_NONBLOCK) == 0 else { throw CommanderError.message("Standardeingabe kann nicht abgesichert werden.") }
            if input.isEmpty { close(stdinWriter);stdinWriter = -1 }
        } else { stdinRead = open("/dev/null",O_RDONLY|O_CLOEXEC);guard stdinRead >= 0 else { throw CommanderError.message("Standardeingabe kann nicht geöffnet werden.") } }
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions));defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes));defer { posix_spawnattr_destroy(&attributes) }
        if #available(macOS 26.0,*) { try checked(posix_spawn_file_actions_addfchdir(&actions,directory)) }
        else { try checked(posix_spawn_file_actions_addfchdir_np(&actions,directory)) }
        // Resolve cwd before stdio actions: its retained FD can occupy 0/1/2 if
        // the caller deliberately closed one of those standard descriptors.
        try checked(posix_spawn_file_actions_adddup2(&actions,stdinRead,STDIN_FILENO));try checked(posix_spawn_file_actions_adddup2(&actions,writer,STDOUT_FILENO));try checked(posix_spawn_file_actions_adddup2(&actions,writer,STDERR_FILENO))
        try checked(posix_spawnattr_setpgroup(&attributes,0))
        var mask = sigset_t();sigemptyset(&mask);try checked(posix_spawnattr_setsigmask(&attributes,&mask))
        var defaults = sigset_t();sigemptyset(&defaults);sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);sigaddset(&defaults,SIGPIPE);try checked(posix_spawnattr_setsigdefault(&attributes,&defaults))
        try checked(posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF)))
        let argumentStrings = [target.path]+arguments
        var environment = ProcessInfo.processInfo.environment;environment["PWD"] = location.path
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { $0.key+"="+$0.value }
        guard !environmentStrings.contains(where:{ $0.contains("\0") }) else { throw CommanderError.message("Ungültige Prozessumgebung.") }
        var argv = argumentStrings.map { strdup($0) },envp = environmentStrings.map { strdup($0) }
        defer { for value in argv { free(value) };for value in envp { free(value) } }
        guard argv.allSatisfy({ $0 != nil }),envp.allSatisfy({ $0 != nil }) else { throw CommanderError.message("Nicht genug Speicher für den Werkzeugaufruf.") }
        argv.append(nil);envp.append(nil);try token.check();try validate()
        var child:pid_t = 0
        let launch = argv.withUnsafeMutableBufferPointer { args in envp.withUnsafeMutableBufferPointer { env in posix_spawn(&child,target.path,&actions,&attributes,args.baseAddress!,env.baseAddress!) } }
        try checked(launch)
        close(writer);writer = -1
        close(stdinRead);stdinRead = -1
        var status:Int32 = 0,stopped:String?,sentAt:TimeInterval?,reaped = false
        let started = ProcessInfo.processInfo.systemUptime;var pausedDuration:TimeInterval = 0
        var eof = false,totalBytes:Int64 = 0,stored = Data(),buffer = [UInt8](repeating:0,count:65_536)
        func stop(_ message:String) {
            guard stopped == nil else { return };stopped = message
            if stdinWriter >= 0 { close(stdinWriter);stdinWriter = -1 }
            kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime
        }
        defer {
            if !reaped { kill(-child,SIGKILL);while waitpid(child,&status,0) < 0 && errno == EINTR {} }
        }
        while true {
            var transferred = false
            // Drain a bounded batch before checking cancellation and active time.
            // Keeping the direct child unreaped until EOF also reserves its PID/
            // process-group identity while descendants still own the capture pipe.
            if !eof {
                for _ in 0..<8 {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(output,$0.baseAddress,$0.count) }
                    if count > 0 {
                        transferred = true
                        totalBytes += Int64(count)
                        if stored.count < 4*1024*1024 { stored.append(contentsOf:buffer.prefix(min(count,4*1024*1024-stored.count))) }
                        if totalBytes > 32*1024*1024,stopped == nil { stop("Werkzeug wegen mehr als 32 MiB Textausgabe angehalten.");break }
                    } else if count == 0 { eof = true;break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else { throw CommanderError.message("Werkzeugausgabe kann nicht gelesen werden.") }
                }
            }
            if stdinWriter >= 0,let input,stopped == nil {
                for _ in 0..<8 {
                    guard inputOffset < input.count else { close(stdinWriter);stdinWriter = -1;break }
                    let count = input.withUnsafeBytes { bytes in Darwin.write(stdinWriter,bytes.baseAddress!.advanced(by:inputOffset),min(65_536,input.count-inputOffset)) }
                    if count > 0 { inputOffset += count;transferred = true }
                    else if count == 0 { break }
                    else if errno == EINTR { continue }
                    else if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    else { stop(errno == EPIPE ? "Prozess hat die Standardeingabe vorzeitig geschlossen." : "Standardeingabe konnte nicht vollständig übertragen werden.");break }
                }
                if inputOffset == input.count,stdinWriter >= 0 { close(stdinWriter);stdinWriter = -1 }
            }
            if eof,stdinWriter < 0 {
                if stopped != nil { kill(-child,SIGKILL) }
                let waited = waitpid(child,&status,WNOHANG)
                if waited == child { reaped = true;break }
                if waited < 0 { if errno == EINTR { continue };if errno == ECHILD { reaped = true };throw CommanderError.message("Werkzeugstatus kann nicht gelesen werden.") }
            }
            if stopped == nil,token.isPaused {
                let pausedAt = ProcessInfo.processInfo.systemUptime;kill(-child,SIGSTOP)
                do { try token.check() } catch { stop("Werkzeugaufruf abgebrochen.") }
                pausedDuration += ProcessInfo.processInfo.systemUptime-pausedAt;kill(-child,SIGCONT)
                if stopped != nil { kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime }
            }
            if stopped == nil {
                if token.isCancelled { stop("Werkzeugaufruf abgebrochen.") }
                else if ProcessInfo.processInfo.systemUptime-started-pausedDuration >= timeout { stop("Zeitlimit für das Werkzeug erreicht.") }
            }
            if let sentAt,ProcessInfo.processInfo.systemUptime-sentAt >= 0.5 { kill(-child,SIGKILL) }
            if let sentAt,ProcessInfo.processInfo.systemUptime-sentAt >= 1 {
                // An independently detached writer may keep a pipe open. Closing
                // our read end bounds capture; it cannot retain a growing file.
                kill(-child,SIGKILL);while true { let waited = waitpid(child,&status,0);if waited == child { reaped = true;break };if waited < 0,errno == EINTR { continue };if waited < 0,errno == ECHILD { reaped = true };throw CommanderError.message("Werkzeugstatus kann nicht gelesen werden.") };break
            }
            Thread.sleep(forTimeInterval:transferred ? 0.001 : 0.01)
        }
        let text = String(decoding:stored,as:UTF8.self)+(totalBytes > 4*1024*1024 ? "\n[Ausgabe auf 4 MiB begrenzt]" : "")
        let signal = status & 0x7f,exitCode = (status >> 8) & 0xff
        if let stopped { throw ExternalToolProcessFailure(message:stopped+(signal != 0 ? " (Signal \(signal))" : exitCode != 0 ? " (Prozessstatus \(exitCode))" : ""),output:text) }
        guard signal == 0,exitCode == 0 else { throw ExternalToolProcessFailure(message:"Werkzeug endete "+(signal == 0 ? "mit Status \(exitCode)" : "durch Signal \(signal)"),output:text) }
        return text
    }
}
