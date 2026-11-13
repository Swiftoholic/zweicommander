import AppKit
import CommanderCore
import CryptoKit
import CoreFoundation
import Darwin

private struct RestartSmokeProof:Codable {
    let version:Int,beforePID:Int32,beforeChecks:Int
    let domain:String,personalStateID:String,restoredStateID:String,intentID:UUID
}

private enum RestartSmokeFingerprint {
    static func current() throws -> String {
        var nodes = 0,bytes = 0
        func value(_ raw:Any,_ depth:Int) throws -> Any {
            nodes += 1
            guard depth <= 64,nodes <= 300_000,bytes <= 32*1024*1024 else { throw CommanderError.message("Die persönliche Einstellungsprüfung überschreitet ihre Grenzen.") }
            if let data = raw as? Data { guard data.count <= 32*1024*1024-bytes else { throw CommanderError.message("Die persönliche Einstellungsprüfung ist zu groß.") };bytes += data.count;return ["data":data.base64EncodedString()] }
            if let date = raw as? Date { return ["date":date.timeIntervalSinceReferenceDate] }
            if let text = raw as? String { guard text.utf8.count <= 32*1024*1024-bytes else { throw CommanderError.message("Die persönliche Einstellungsprüfung ist zu groß.") };bytes += text.utf8.count;return ["text":text] }
            if let number = raw as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? ["bool":number.boolValue] : ["number":String(cString:number.objCType)+":"+number.stringValue] }
            if let dictionary = raw as? [String:Any] {
                guard dictionary.count <= 300_000-nodes else { throw CommanderError.message("Zu viele persönliche Einstellungswerte.") }
                var entries:[[String:Any]] = []
                for key in dictionary.keys.sorted() { guard key.utf8.count <= 32*1024*1024-bytes else { throw CommanderError.message("Die persönliche Einstellungsprüfung ist zu groß.") };bytes += key.utf8.count;entries.append(["key":key,"value":try value(dictionary[key]!,depth+1)]) };return entries
            }
            if let array = raw as? [Any] { guard array.count <= 300_000-nodes else { throw CommanderError.message("Zu viele persönliche Einstellungswerte.") };var entries:[Any] = [];for item in array { entries.append(try value(item,depth+1)) };return entries }
            throw CommanderError.message("Unbekannter Wert in der persönlichen Einstellungsprüfung.")
        }
        _ = UserDefaults.standard.synchronize()
        let contents = try value(UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:],0)
        return hash(try JSONSerialization.data(withJSONObject:contents,options:.sortedKeys))
    }
    static func hash(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
}

extension AppDelegate {
    /// Runs only in the coordinator's isolated fixture. The second phase is launched by the real bundled helper.
    func runRestartSmoke(root:URL,prefix:String,phase:String) {
        Task { @MainActor in
            let logURL = root.appendingPathComponent("Restart-Probe.log"),doneURL = root.appendingPathComponent("Restart-Probe.done"),proofURL = root.appendingPathComponent("Restart-Before.json"),domainURL = root.appendingPathComponent("Restart-Domain.txt")
            var checks = 0,failures:[String] = [],domainName:String?,defaults:UserDefaults?,senders:[Process] = []
            let originalAppearanceDefaults = Preferences.appearanceTestDefaults
            @MainActor func cleanup() {
                Preferences.appearanceTestDefaults = originalAppearanceDefaults
                for sender in senders where sender.isRunning { sender.terminate() }
                if let domainName,let defaults { defaults.removePersistentDomain(forName:domainName);_ = defaults.synchronize() }
            }
            @MainActor func emit(_ line:String) throws {
                if !FileManager.default.fileExists(atPath:logURL.path) { try SettingsBackupFile.writeNew(Data(),to:logURL) }
                let output = try FileHandle(forWritingTo:logURL);defer { try? output.close() };try output.seekToEnd();try output.write(contentsOf:Data((line+"\n").utf8));try output.synchronize()
            }
            @MainActor func check(_ condition:Bool,_ name:String) throws {
                checks += 1;try emit("RESTART UI \(condition ? "PASS" : "FAIL") "+name);if !condition { failures.append(name) }
            }
            @MainActor func require<T>(_ value:T?,_ name:String) throws -> T { guard let value else { throw CommanderError.message("Fehlende Neustart-Prüfbedingung: "+name) };return value }
            @MainActor func ensure(_ value:Bool,_ name:String) throws { guard value else { throw CommanderError.message(name) } }
            @MainActor func wait(_ name:String,_ condition:()->Bool) async throws {
                for _ in 0..<600 { if condition() { return };try await Task.sleep(nanoseconds:50_000_000) };throw CommanderError.message("Neustart-Prüfung: Zeitlimit "+name)
            }
            @MainActor func finish(_ success:Bool) {
                do { try emit("RESTART SMOKE \(success ? "PASS" : "FAIL") \(checks) checks");try SettingsBackupFile.writeNew(Data((success ? "PASS\n" : "FAIL\n").utf8),to:doneURL) }
                catch { fputs("RESTART SMOKE FAIL Ergebnisdatei\n",stderr) }
                cleanup();fflush(stdout);exit(success ? 0 : 1)
            }
            do {
                try ensure(phase == "before" || phase == "after","Unbekannte Neustart-Prüfphase.")
                let expectedDirectory = FileSystem.canonical(root.appendingPathComponent("Auftragsablage"))
                let journal = try require(self.main.jobs.journal,"Auftragsablage"),history = try require(self.main.jobs.history,"Wiederherstellungsablage")
                try ensure(Preferences.testMode && FileSystem.canonical(journal.directory).path == expectedDirectory.path,"Die Neustart-Prüfung benötigt ausschließlich ihre isolierte Auftragsablage.")
                let source = root.appendingPathComponent("Neustart-Quelle.txt"),stagedDestination = root.appendingPathComponent("Vor-Neustart-Ziel"),restoredLeft = root.appendingPathComponent("Wiederhergestellt Links"),restoredRight = root.appendingPathComponent("Wiederhergestellt Rechts")
                let sourceData = Data("Synthetic restart journal content ✔\n".utf8)
                if phase == "before" {
                    try emit("RESTART PHASE before")
                    try check(Bundle.main.bundleURL.pathExtension == "app","before phase uses an actual app bundle")
                    try ensure(Bundle.main.bundleURL.pathExtension == "app","Diese Prüfung benötigt das fertige App-Bundle.")
                    try check(self.main.jobs.journalError == nil && history.persistenceError == nil,"original process owns a usable isolated journal and history")
                    try check(!SettingsBackupStorage.persistenceSuspended && !self.main.settingsRestartInProgress,"original process begins without pending restore or restart flags")
                    try check(self.main.canTerminate && self.main.pendingWork == 0,"original process is idle and allows a controlled restart")
                    try ensure(self.main.canTerminate && self.main.pendingWork == 0,"Prüfprozess ist nicht zum Neustart bereit.")
                    for directory in [stagedDestination,restoredLeft,restoredRight] { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false) }
                    try SettingsBackupFile.writeNew(sourceData,to:source)
                    let transfer = try TransferPlanner.prepare([source],to:stagedDestination,kind:.copy,policy:.stop),intentID = UUID()
                    try journal.stage(TransferIntent(transfer),snapshot:.waiting(id:intentID,title:"Synthetischer Neustartauftrag",items:transfer.initialItems))
                    try check(journal.entry(intentID) != nil && !FileManager.default.fileExists(atPath:stagedDestination.appendingPathComponent(source.lastPathComponent).path),"a real journal intent is stored without executing its file transfer")
                    let name = "local.zweicommander.tests."+UUID().uuidString
                    domainName = name;defaults = try require(UserDefaults(suiteName:name),"Test-Einstellungsbereich");let testDefaults = defaults!
                    var previous = SavedState();previous.left = [SavedTab(path:root.appendingPathComponent("Links").path,title:nil,locked:false,view:nil,selected:nil)];previous.right = [SavedTab(path:root.appendingPathComponent("Rechts").path,title:nil,locked:false,view:nil,selected:nil)]
                    let encoder = JSONEncoder(),oldData = try encoder.encode(previous)
                    testDefaults.setPersistentDomain([SettingsBackupStores.state:oldData,"SyntheticUnownedMarker":"keep"],forName:name);_ = testDefaults.synchronize()
                    var changed = previous;changed.theme = 2;changed.showHidden = true;changed.left = [SavedTab(path:restoredLeft.path,title:"Neustart Links",locked:false,view:FolderViewSettings(),selected:nil)];changed.right = [SavedTab(path:restoredRight.path,title:"Neustart Rechts",locked:false,view:FolderViewSettings(),selected:nil)]
                    let changedData = try encoder.encode(changed),document = try SettingsBackupDocument(stores:[SettingsBackupStores.state:changedData],validator:SettingsBackupStorage.validate),storage = SettingsBackupStorage(defaults:testDefaults,domainName:name,rollbackDirectory:root.appendingPathComponent("Einstellungs-Sicherung"),requiresRestart:true)
                    let plan = try storage.prepare(document),personalID = try RestartSmokeFingerprint.current()
                    try check(plan.changedCount == 1,"actual settings restore reviews a changed synthetic session")
                    let receipt = try storage.restore(plan)
                    try check(FileManager.default.fileExists(atPath:receipt.rollbackURL.path),"actual settings restore retains the previous isolated settings")
                    try check(testDefaults.data(forKey:SettingsBackupStores.state) == changedData,"actual settings restore persists the changed session bytes before relaunch")
                    try check(SettingsBackupStorage.restartPending && SettingsBackupStorage.persistenceSuspended && !SettingsBackupStorage.isRestoring,"completed restore guards stale writes while awaiting restart")
                    Preferences.appearanceTestDefaults = testDefaults
                    do { try Preferences.saveAppearance(AppearanceSettings());try check(false,"ordinary preference mutators reject stale writes after restore") }
                    catch { try check(true,"ordinary preference mutators reject stale writes after restore") }
                    try check(testDefaults.data(forKey:Preferences.appearanceKey) == nil,"blocked stale appearance writes cannot alter the restored test domain")
                    try check(try RestartSmokeFingerprint.current() == personalID,"isolated restore leaves all personal standard preferences unchanged")
                    try check(self.main.canTerminate && self.main.jobs.journalError == nil,"storing the review intent does not block the controlled restart")
                    try ensure(failures.isEmpty,"Vorbedingungen des Neustarts sind fehlgeschlagen.")
                    Preferences.appearanceTestDefaults = originalAppearanceDefaults
                    try SettingsBackupFile.writeNew(Data((name+"\n").utf8),to:domainURL)
                    let proof = RestartSmokeProof(version:1,beforePID:getpid(),beforeChecks:checks,domain:name,personalStateID:personalID,restoredStateID:RestartSmokeFingerprint.hash(changedData),intentID:intentID)
                    try SettingsBackupFile.writeNew(encoder.encode(proof),to:proofURL)
                    self.main.settingsRestartArguments = ["--restart-smoke",root.path,prefix,"after"]
                    self.main.restartAfterSettingsRestore()
                    // A successful call terminates this process. Returning to its run loop is a failure.
                    try await Task.sleep(nanoseconds:2_000_000_000)
                    throw CommanderError.message("Der ursprüngliche Prüfprozess wurde durch den Neustart nicht beendet.")
                }
                let proof = try JSONDecoder().decode(RestartSmokeProof.self,from:SettingsBackupFile.read(proofURL))
                try ensure(proof.version == 1 && proof.domain.hasPrefix("local.zweicommander.tests.") && UUID(uuidString:String(proof.domain.dropFirst("local.zweicommander.tests.".count))) != nil,"Ungültiger isolierter Neustartnachweis.")
                domainName = proof.domain;defaults = try require(UserDefaults(suiteName:proof.domain),"wiederhergestellter Testbereich");let testDefaults = defaults!
                checks = proof.beforeChecks;try emit("RESTART PHASE after")
                try check(getpid() != proof.beforePID,"relaunch creates a different app process")
                errno = 0;let oldAlive = kill(proof.beforePID,0);let oldError = errno
                try check(oldAlive != 0 && oldError == ESRCH,"the original process has exited before the replacement uses its journal")
                try check(self.main.jobs.journalError == nil && FileSystem.canonical(journal.directory).path == expectedDirectory.path,"replacement process reacquires the isolated journal without a lock error")
                try check(self.main.jobs.history != nil && history.persistenceError == nil,"replacement process has a usable recovery history")
                try check(!SettingsBackupStorage.restartPending && !SettingsBackupStorage.isRestoring && !self.main.settingsRestartInProgress,"replacement process starts with cleared restore and restart flags")
                let stored = try require(testDefaults.data(forKey:SettingsBackupStores.state),"wiederhergestellter Sitzungsstand")
                try check(RestartSmokeFingerprint.hash(stored) == proof.restoredStateID,"replacement consumes the exact committed synthetic settings bytes")
                try check(Preferences.state.theme == 2 && Preferences.state.showHidden,"replacement consumes restored theme and hidden-file settings")
                try await wait("wiederhergestellte Dateifenster") { !self.main.left.isLoading && !self.main.right.isLoading }
                try check(FileSystem.canonical(self.main.left.currentURL).path == FileSystem.canonical(restoredLeft).path && FileSystem.canonical(self.main.right.currentURL).path == FileSystem.canonical(restoredRight).path,"replacement constructs both panes from restored session paths")
                try check(self.main.left.tab.title == "Neustart Links" && self.main.right.tab.title == "Neustart Rechts","replacement retains restored tab titles")
                try check(self.main.window?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"replacement applies restored dark appearance to the actual window")
                try check(testDefaults.string(forKey:"SyntheticUnownedMarker") == "keep","settings restore preserves unrelated values in the isolated test domain")
                try check(journal.entry(proof.intentID) != nil && self.main.jobs.scheduler.snapshots.contains { $0.id == proof.intentID && $0.state == .review },"existing journal intent survives the handoff in review state")
                try check(!FileManager.default.fileExists(atPath:stagedDestination.appendingPathComponent(source.lastPathComponent).path),"replacement does not automatically execute the saved review intent")
                try check(try Data(contentsOf:source) == sourceData,"restart preserves the reviewed transfer source contents")
                Preferences.appearanceTestDefaults = testDefaults
                var appearance = AppearanceSettings();appearance.compact = false;try Preferences.saveAppearance(appearance)
                try check(testDefaults.data(forKey:Preferences.appearanceKey) != nil,"ordinary guarded settings mutations work again after restart")
                Preferences.appearanceTestDefaults = originalAppearanceDefaults
                let destination = root.appendingPathComponent("Nach-Neustart-Ziel"),target = destination.appendingPathComponent(source.lastPathComponent),oldTarget = Data("Original synthetic target\n".utf8)
                try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false);try SettingsBackupFile.writeNew(oldTarget,to:target)
                let transfer = try TransferPlanner.prepare([source],to:destination,kind:.copy,policy:.replace)
                var result:Result<OperationReport,Error>?
                let jobID = try self.main.jobs.submitTransfer(transfer,start:true) { result = $0 }
                try await wait("Dateiauftrag nach Neustart") { result != nil && journal.entry(jobID)?.snapshot.state == .completed }
                let report = try result!.get()
                try check(report.errors.isEmpty && (try Data(contentsOf:target)) == sourceData,"replacement executes a real queued copy with verified output bytes")
                try check(journal.entry(jobID)?.snapshot.state == .completed && self.main.jobs.journalError == nil,"replacement persists the completed normal file job in its reacquired journal")
                let backup = try require(history.inspect().first { $0.kind == .backup && FileSystem.canonical($0.original).path == FileSystem.canonical(target).path },"Sicherung nach Neustart")
                try check(backup.available && (try Data(contentsOf:backup.stored)) == oldTarget,"replacement records a readable recovery backup for the replaced file")
                try history.restore(history.planRestore(backup.id))
                try check(try Data(contentsOf:target) == oldTarget && history.persistenceError == nil,"recovery remains usable after the journal handoff and normal file operation")
                // Exercise the ordinary command entry while this process holds the journal.
                // A sender must hand navigation over before loading preferences or creating a queue.
                let bundleID = try require(Bundle.main.bundleIdentifier,"Bundle-Kennung"),executable = try require(Bundle.main.executableURL,"App-Programm")
                try ensure(NSRunningApplication.runningApplications(withBundleIdentifier:bundleID).contains { $0.processIdentifier == getpid() && !$0.isTerminated },"Der bestehende Prüfprozess ist nicht zur Startübergabe registriert.")
                let literalFolder = root.appendingPathComponent("Normale Startübergabe"),literalINI = literalFolder.appendingPathComponent("literal.ini"),literalData = Data("[Form]\nColorSchema=RestartLiteral\nShowHiddenFile=0\n".utf8)
                try FileManager.default.createDirectory(at:literalFolder,withIntermediateDirectories:false);try SettingsBackupFile.writeNew(literalData,to:literalINI)
                let names = ["--import-settings","--inspect-binary","--export-settings-profile"],literalContents = Data("Literal command option filename\n".utf8)
                for name in names { try SettingsBackupFile.writeNew(literalContents,to:literalFolder.appendingPathComponent(name)) }
                let expectedNames = Set(names+[literalINI.lastPathComponent]),childPID = getpid()
                for name in names {
                    let sender = Process();sender.executableURL = executable;sender.currentDirectoryURL = literalFolder;sender.arguments = ["--",name,literalINI.lastPathComponent]
                    sender.standardInput = FileHandle.nullDevice;sender.standardOutput = FileHandle.nullDevice;sender.standardError = FileHandle.nullDevice;senders.append(sender)
                    try sender.run();try await wait("normale Startübergabe "+name) { !sender.isRunning }
                    try check(sender.terminationStatus == 0,"normal CLI sender exits successfully for literal "+name)
                    try await wait("übergebene Dateiauswahl "+name) {
                        !self.main.left.isLoading && !self.main.right.isLoading && !self.main.left.isSorting && !self.main.right.isSorting &&
                        self.main.left.selectedURLs.map(\.lastPathComponent) == [name] && self.main.right.selectedURLs.map(\.lastPathComponent) == [literalINI.lastPathComponent]
                    }
                    try check(FileSystem.canonical(self.main.left.currentURL).path == FileSystem.canonical(literalFolder).path && FileSystem.canonical(self.main.right.currentURL).path == FileSystem.canonical(literalFolder).path,"normal CLI navigation reaches existing process for literal "+name)
                    try check(getpid() == childPID && self.main.jobs.journal === journal && self.main.jobs.history === history && self.main.jobs.journalError == nil,"normal CLI handoff retains the original healthy process and journal for "+name)
                    try check(Preferences.state.importedProfile == nil && Preferences.state.showHidden && (try Data(contentsOf:literalINI)) == literalData && (try Data(contentsOf:literalFolder.appendingPathComponent(name))) == literalContents && Set(try FileManager.default.contentsOfDirectory(atPath:literalFolder.path)) == expectedNames,"literal option filenames never trigger import export or inspection for "+name)
                }
                try check(try RestartSmokeFingerprint.current() == proof.personalStateID,"both processes preserve all personal standard preference values")
                finish(failures.isEmpty)
            } catch {
                try? emit("RESTART SMOKE FAIL "+error.localizedDescription);finish(false)
            }
        }
    }
}
