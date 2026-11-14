import AppKit
import CommanderCore

enum LaunchRouting {
    /// A second normal invocation delivers navigation to the existing process
    /// before it can acquire a second journal or load a stale session snapshot.
    static func handoffIfRunning(_ request:LaunchRequest) throws -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app",let identifier = Bundle.main.bundleIdentifier,
              let executable = Bundle.main.executableURL else { return false }
        func inventory() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier:identifier).filter {
                !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
        }
        var candidates = inventory()
        let launchDeadline = ProcessInfo.processInfo.systemUptime+10
        while !candidates.isEmpty && !candidates.contains(where:{ $0.isFinishedLaunching && $0.activationPolicy == .regular }) {
            guard ProcessInfo.processInfo.systemUptime < launchDeadline else { throw CommanderError.message("Eine Ausgabe von ZweiCommander startet noch und kann die Anfrage noch nicht annehmen. Den Start kurz später wiederholen.") }
            RunLoop.current.run(until:Date().addingTimeInterval(0.02));candidates = inventory()
        }
        let ready = candidates.filter { $0.isFinishedLaunching && $0.activationPolicy == .regular }
        guard ready.contains(where:{ $0.executableURL.map(FileSystem.canonical)?.path == FileSystem.canonical(executable).path }) else {
            guard candidates.isEmpty else { throw CommanderError.message("Eine andere Ausgabe von ZweiCommander läuft bereits. Diese zuerst beenden und den Start wiederholen.") }
            return false
        }
        let url = try request.navigationURL(),configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true;configuration.createsNewApplicationInstance = false
        var finished = false,error:Error?
        NSWorkspace.shared.open([url],withApplicationAt:Bundle.main.bundleURL,configuration:configuration) { _,failure in
            DispatchQueue.main.async { error = failure;finished = true }
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished,Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        guard finished else { throw CommanderError.message("Die laufende App hat die Startübergabe nicht rechtzeitig bestätigt.") }
        if let error { throw error };return true
    }
}

extension AppDelegate {
    func application(_ application:NSApplication,open urls:[URL]) {
        do {
            let request:LaunchRequest
            if urls.count == 1,urls[0].scheme?.lowercased() == LaunchRequest.urlScheme { request = try LaunchRequest.navigationRequest(urls[0]) }
            else {
                guard !urls.isEmpty,urls.count <= 2,urls.allSatisfy(\.isFileURL) else { throw CommanderError.message("Zum Öffnen höchstens zwei lokale Startpfade übergeben.") }
                request = try LaunchRequest.parse(["--"]+urls.map(\.absoluteString))
            }
            if main == nil { pendingOpenRequests.append(request) }
            else { try main.applyLaunchRequest(request);main.showWindow(nil);NSApp.activate(ignoringOtherApps:true) }
        } catch {
            if main != nil { main.content.status.stringValue = error.localizedDescription }
            else { fputs("Startübergabe fehlgeschlagen: \(error.localizedDescription)\n",stderr) }
        }
    }
}
