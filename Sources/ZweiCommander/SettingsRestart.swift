import AppKit
import CommanderCore
import Darwin

enum SettingsRelaunchHelper {
    /// Runs before NSApplication/Preferences/JobQueue are initialized, so this
    /// short-lived helper never acquires the journal that its parent still owns.
    static func runIfRequested(_ arguments:[String]) -> Int32? {
        guard arguments.dropFirst().first == "--relaunch-after" else { return nil }
        guard arguments.count == 3 || arguments.count == 8,
              let parent = Int32(arguments[2]),parent > 1,parent != getpid(),
              Bundle.main.bundleURL.pathExtension == "app" else { return 2 }
        var forwarded:[String] = []
        if arguments.count == 8 {
            guard arguments[3] == "--",arguments[4] == "--restart-smoke",arguments[5].hasPrefix("/"),
                  arguments[6].hasPrefix("/"),arguments[7] == "after" else { return 2 }
            forwarded = Array(arguments[4...7])
        }
        let deadline = ProcessInfo.processInfo.systemUptime+30
        while kill(parent,0) == 0 || errno == EPERM {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return 2 }
            Thread.sleep(forTimeInterval:0.05)
        }
        let process = Process();process.executableURL = URL(fileURLWithPath:"/usr/bin/open")
        process.arguments = ["-n","-a",Bundle.main.bundleURL.path]+(forwarded.isEmpty ? [] : ["--args"]+forwarded)
        process.standardInput = FileHandle.nullDevice;process.standardOutput = FileHandle.nullDevice;process.standardError = FileHandle.nullDevice
        do { try process.run();process.waitUntilExit();return process.terminationStatus }
        catch { return 2 }
    }
}

extension MainWindow {
    func restartAfterSettingsRestore() {
        guard SettingsBackupStorage.restartPending, !settingsRestartInProgress else { return }
        guard canTerminate, pendingWork == 0 else {
            content.status.stringValue = "Laufende Vorgänge vor dem Neustart abschließen.";return
        }
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", !Preferences.testMode || settingsRestartArguments != nil,
              let executable = Bundle.main.executableURL else {
            content.status.stringValue = "Einstellungen übernommen. Die App schließen und erneut aus Programme öffnen.";return
        }
        settingsRestartInProgress = true
        let helper = Process();helper.executableURL = executable
        helper.arguments = ["--relaunch-after",String(getpid())]+(settingsRestartArguments.map { ["--"]+$0 } ?? [])
        helper.standardInput = FileHandle.nullDevice;helper.standardOutput = FileHandle.nullDevice;helper.standardError = FileHandle.nullDevice
        helper.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return };self.settingsRestartInProgress = false
                self.settingsRelaunchProcess = nil
                if process.terminationStatus != 0 { self.content.status.stringValue = "Neustart angehalten. Die App schließen und erneut aus Programme öffnen." }
            }
        }
        do { try helper.run();settingsRelaunchProcess = helper;NSApp.terminate(nil) }
        catch { settingsRestartInProgress = false;showFailure(error) }
    }
}
