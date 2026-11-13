import Foundation
import Darwin

/// Native argv avoids Foundation's filesystem normalization of arbitrary argument text.
enum ExternalToolProcess {
    static func run(_ plan:ExternalToolPlan,invocation:Int,token:CancellationToken) throws -> String {
        let call = plan.invocations[invocation]
        func checked(_ result:Int32) throws { guard result == 0 else { throw CommanderError.message("Werkzeugstart: "+String(cString:strerror(result))) } }
        let directory = open(call.directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard directory >= 0 else { throw CommanderError.message("Arbeitsordner kann nicht geöffnet werden.") };defer { close(directory) }
        var directoryStat = stat();guard fstat(directory,&directoryStat) == 0,call.observations.contains(where:{ $0.url == call.directory && $0.version.sameObject(RenameVersion(directoryStat)) }) else { throw CommanderError.message("Arbeitsordner wurde vor dem Start ausgetauscht.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("zwei-tool-output-"+UUID().uuidString)
        let output = open(temporary.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard output >= 0 else { throw CommanderError.message("Private Werkzeugausgabe kann nicht angelegt werden.") };defer { close(output) }
        guard unlink(temporary.path) == 0 else { throw CommanderError.message("Private Werkzeugausgabe kann nicht freigegeben werden.") }
        let null = open("/dev/null",O_RDONLY|O_CLOEXEC);guard null >= 0 else { throw CommanderError.message("Standardeingabe kann nicht geöffnet werden.") };defer { close(null) }
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions));defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes));defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_adddup2(&actions,null,STDIN_FILENO));try checked(posix_spawn_file_actions_adddup2(&actions,output,STDOUT_FILENO));try checked(posix_spawn_file_actions_adddup2(&actions,output,STDERR_FILENO))
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
        var status:Int32 = 0,stopped:String?,sentAt:TimeInterval?,reaped = false
        let started = ProcessInfo.processInfo.systemUptime;var pausedDuration:TimeInterval = 0
        defer {
            if !reaped { kill(-child,SIGKILL);while waitpid(child,&status,0) < 0 && errno == EINTR {} }
        }
        while true {
            let waited = waitpid(child,&status,WNOHANG)
            if waited == child { reaped = true;break }
            if waited < 0 { if errno == EINTR { continue };throw CommanderError.message("Werkzeugstatus kann nicht gelesen werden.") }
            if stopped == nil,token.isPaused {
                let pausedAt = ProcessInfo.processInfo.systemUptime;kill(-child,SIGSTOP)
                do { try token.check() } catch { stopped = "Werkzeugaufruf abgebrochen." }
                pausedDuration += ProcessInfo.processInfo.systemUptime-pausedAt;kill(-child,SIGCONT)
                if stopped != nil { kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime }
            }
            var outputStat = stat();guard fstat(output,&outputStat) == 0 else { throw CommanderError.message("Werkzeugausgabe kann nicht geprüft werden.") }
            if stopped == nil {
                if token.isCancelled { stopped = "Werkzeugaufruf abgebrochen." }
                else if ProcessInfo.processInfo.systemUptime-started-pausedDuration >= TimeInterval(plan.tool.timeoutSeconds) { stopped = "Zeitlimit für das Werkzeug erreicht." }
                else if outputStat.st_size > 32*1024*1024 { stopped = "Werkzeug wegen mehr als 32 MiB Textausgabe angehalten." }
                if stopped != nil { kill(-child,SIGTERM);sentAt = ProcessInfo.processInfo.systemUptime }
            }
            if let sentAt,ProcessInfo.processInfo.systemUptime-sentAt >= 0.5 { kill(-child,SIGKILL) }
            Thread.sleep(forTimeInterval:0.025)
        }
        if stopped != nil { kill(-child,SIGKILL) }
        var finalStat = stat();guard fstat(output,&finalStat) == 0 else { throw CommanderError.message("Werkzeugausgabe ist nicht lesbar.") }
        if finalStat.st_size > 32*1024*1024,stopped == nil { stopped = "Werkzeug überschritt 32 MiB Textausgabe." }
        guard lseek(output,0,SEEK_SET) >= 0 else { throw CommanderError.message("Werkzeugausgabe ist nicht lesbar.") }
        let handle = FileHandle(fileDescriptor:output,closeOnDealloc:false),data = try handle.read(upToCount:4*1024*1024) ?? Data()
        let text = String(decoding:data,as:UTF8.self)+(finalStat.st_size > 4*1024*1024 ? "\n[Ausgabe auf 4 MiB begrenzt]" : "")
        if let stopped { throw CommanderError.message(stopped+(text.isEmpty ? "" : "\n"+text)) }
        let signal = status & 0x7f,exitCode = (status >> 8) & 0xff
        guard signal == 0,exitCode == 0 else { throw CommanderError.message("Werkzeug endete "+(signal == 0 ? "mit Status \(exitCode)" : "durch Signal \(signal)")+":\n"+text) }
        return text
    }
}
