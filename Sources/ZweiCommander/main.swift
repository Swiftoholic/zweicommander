import AppKit
import CommanderCore

final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuItemValidation {
    var main:MainWindow!
    static let menuDefinitions:[(String,[(String,String,String)])] = [
        ("Datei",[("Öffnen","open","cmd+o"),("Ordner in neuem Tab öffnen","openInNewTab","cmd+return"),("Ordner auf anderer Seite öffnen","openInOther","cmd+option+return"),("Ordner in neuem Tab auf anderer Seite","openInOtherTab","cmd+option+o"),("Vorschau","preview","F3"),("Mit TextEdit bearbeiten","edit","F4"),("Neuer Ordner …","newFolder","F7"),("Neue Datei …","newFile","shift+F4"),("—","",""),("Kopieren …","copy","F5"),("Verschieben …","move","F6"),("Umbenennen …","rename","F2"),("Mehrfachumbenennen …","batchRename","cmd+shift+m"),("In den Papierkorb …","trash","F8"),("—","",""),("Archiv erstellen …","pack","option+F5"),("Archiv entpacken …","extract","option+F6"),("Zum Archivcontainer","archiveContainer","cmd+option+up"),("Archivpasswort …","archivePassword",""),("Symbolische Verknüpfung …","symlink",""),("Eigenschaften","properties","cmd+i"),("Rechte und Datum …","attributes","")]),
        ("Bearbeiten",[("Rückgängig","undo","cmd+z"),("Ausschneiden","clipboardCut","cmd+x"),("Kopieren","clipboardCopy","cmd+c"),("Einfügen …","clipboardPaste","cmd+v"),("—","",""),("Namen kopieren","copyNames","cmd+option+c"),("Namen ohne Endung kopieren","copyStems","cmd+option+shift+c"),("Vollständige Pfade kopieren","copyPath","cmd+shift+c"),("Datei-URLs kopieren","copyURLs",""),("Als Shell-Argumente kopieren","copyShellPaths",""),("Als Tabelle kopieren","copySelectionTable",""),("—","",""),("Alles auswählen","selectAll","cmd+a")]),
        ("Auswahl",[("Alle Dateien auswählen","selectFiles","cmd+option+a"),("Alles abwählen","deselectAll","cmd+option+shift+a"),("Auswahl umkehren","invertSelection","cmd+shift+a"),("Nur Dateien umkehren","invertFiles",""),("Nach Muster auswählen …","selectPattern","cmd+shift+s"),("—","",""),("Gleiche Endung hinzufügen","sameExtension","cmd+option+e"),("Gleiche Endung abwählen","deselectExtension","cmd+option+shift+e"),("Gleichen Stammnamen hinzufügen","sameStem","cmd+option+n"),("Gleichen Stammnamen abwählen","deselectStem","cmd+option+shift+n"),("—","",""),("Auswahl merken","saveSelection","cmd+option+s"),("Auswahl wiederherstellen","restoreSelection","cmd+option+r"),("Auswahl in Datei speichern …","saveSelectionFile",""),("Auswahl aus Datei laden …","loadSelectionFile","")]),
        ("Ansicht",[("Aktualisieren","refresh","cmd+r"),("Versteckte Dateien","hidden","cmd+shift+."),("Ordnerbaum","tree","cmd+shift+t"),("Details","details","cmd+1"),("Miniaturbilder","thumbnails","cmd+2"),("Symbole","icons","cmd+3"),("Ordneransicht merken …","rememberView",""),("Gespeicherte Ordneransichten …","folderViews",""),("Schnellansicht","quickView","cmd+y"),("Anordnung wechseln","orientation","cmd+option+h"),("Ein-/Zweifensteransicht","onePane","cmd+shift+1"),("Fensterinhalte tauschen","swap","cmd+u"),("Gleicher Ordner im anderen Fenster","sameFolder","cmd+shift+u"),("Verknüpftes Navigieren","linked",""),("Flache Ansicht","flat","cmd+b"),("Schnellfilter","filter","cmd+shift+f"),("Werkzeugleiste anpassen …","customizeToolbar","")]),
        ("Gehe zu",[("Pfad eingeben","path","cmd+l"),("Übergeordneter Ordner","parent","cmd+up"),("Zurück","back","cmd+["),("Vorwärts","forward","cmd+]"),("Benutzerordner","home","cmd+shift+h"),("Im Finder zeigen","reveal","cmd+shift+r"),("Favorit hinzufügen/entfernen","favorite","cmd+d"),("Favoriten bearbeiten …","editFavorites",""),("Terminal öffnen","terminal","cmd+shift+p"),("Mit Netzwerkvolume verbinden …","connect","cmd+k"),("Serververbindungen …","remote","cmd+shift+k"),("SFTP im Terminal …","sftp","")]),
        ("Tabs",[("Neuer Tab","newTab","cmd+t"),("Tab duplizieren","duplicateTab",""),("Tab auf andere Seite kopieren","copyTabToOther","cmd+option+u"),("Geschlossenen Tab wieder öffnen","reopenTab","cmd+option+z"),("Zuletzt verwendeter Tab","lastTab","ctrl+tab"),("Tabgruppen …","tabGroups","cmd+option+g"),("Tab schließen","closeTab","cmd+w"),("Andere Tabs schließen","closeOtherTabs",""),("Nächster Tab","nextTab","cmd+option+right"),("Vorheriger Tab","previousTab","cmd+option+left"),("Nach links verschieben","moveTabLeft",""),("Nach rechts verschieben","moveTabRight",""),("Tab sperren/entsperren","lockTab",""),("Tabsperre aufheben","tabUnlock",""),("Nur Schließen verhindern","tabCloseLock",""),("Ordner festhalten","tabFixedLock",""),("Ordnerwechsel in neuem Tab","tabNewLock",""),("Tab benennen …","nameTab",""),("Leere Dateisammlung","newCollection",""),("Aus Sammlung entfernen","removeCollectionItem",""),("Auswahl als Dateisammlung","collection",""),("Dateisammlung speichern …","saveCollection",""),("Dateisammlung öffnen …","loadCollection","")]),
        ("Arbeitsbereiche",[("Arbeitsbereiche verwalten …","workspaces","cmd+option+l")]+(1...9).map { ("Arbeitsbereich \($0)","workspace\($0)","cmd+ctrl+\($0)") }),
        ("Werkzeuge",[("Dateien suchen …","search","cmd+f"),("Duplikate suchen …","duplicates",""),("Ordner vergleichen / synchronisieren …","compare","cmd+shift+d"),("Ordnergröße berechnen","folderSize",""),("Prüfsummen berechnen …","hash",""),("Prüfsummenliste prüfen …","verifyHash",""),("Datei teilen …","split",""),("Teileliste zusammenfügen …","join",""),("Dateiliste exportieren …","export",""),("Shell-Befehl …","shell",""),("Vorgangsprotokoll","log","")]),
        ("Aufträge",[("Warteschlange anzeigen","operations","cmd+shift+j"),("Sicherungen und Teilkopien …","recovery","cmd+option+j"),("—","",""),("Pause / Fortsetzen","pauseTransfers","cmd+option+p"),("Laufenden Auftrag abbrechen","stopTransfers","cmd+option+.")]),
        ("Hilfe",[("Bedienung und Funktionsstand","help","F1"),("INI-Einstellungen importieren …","importSettings",""),("Importierte Einstellungen anzeigen","importReport",""),("Einstellungen vor dem Import wiederherstellen","restoreImport","")])
    ]
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args = CommandLine.arguments
        let smoke = args.firstIndex(of:"--smoke-test")
        let operationsSmoke = args.firstIndex(of:"--operations-smoke")
        let filtersSmoke = args.firstIndex(of:"--filters-smoke")
        let mergeSmoke = args.firstIndex(of:"--merge-smoke")
        let profilesSmoke = args.firstIndex(of:"--profiles-smoke")
        let journalSmoke = args.firstIndex(of:"--journal-smoke")
        let ageSmoke = args.firstIndex(of:"--age-smoke")
        let workspaceSmoke = args.firstIndex(of:"--workspace-smoke")
        let renameSmoke = args.firstIndex(of:"--rename-smoke")
        let searchSmoke = args.firstIndex(of:"--search-smoke")
        let appearanceSmoke = args.firstIndex(of:"--appearance-smoke")
        let uxSmoke = args.firstIndex(of:"--ux-smoke")
        let railSmoke = args.firstIndex(of:"--rail-smoke")
        let navigationSmoke = args.firstIndex(of:"--navigation-smoke")
        let fileUXSmoke = args.firstIndex(of:"--file-ux-smoke")
        let recoverySmoke = args.firstIndex(of:"--recovery-smoke")
        let remoteSmoke = args.firstIndex(of:"--remote-smoke")
        let serverPaneSmoke = args.firstIndex(of:"--server-pane-smoke")
        let selectionSmoke = args.firstIndex(of:"--selection-smoke")
        let tabsSmoke = args.firstIndex(of:"--tabs-smoke")
        let layoutSmoke = args.firstIndex(of:"--layout-smoke")
        let archiveSmoke = args.firstIndex(of:"--archive-smoke")
        let compareSmoke = args.firstIndex(of:"--compare-smoke")
        let testIndex = [smoke,operationsSmoke,filtersSmoke,mergeSmoke,profilesSmoke,journalSmoke,ageSmoke,workspaceSmoke,renameSmoke,searchSmoke,compareSmoke,appearanceSmoke,uxSmoke,railSmoke,navigationSmoke,fileUXSmoke,recoverySmoke,remoteSmoke,serverPaneSmoke,selectionSmoke,tabsSmoke,layoutSmoke,archiveSmoke].compactMap { $0 }.first
        Preferences.testMode = testIndex != nil
        if Preferences.testMode { setvbuf(stdout,nil,_IOLBF,0) }
        if Preferences.testMode { Preferences.state = SavedState() }
        if remoteSmoke != nil,let index = args.firstIndex(of:"--remote-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.remoteProfileTestDefaults = UserDefaults(suiteName:args[index+1])
        }
        if let index = journalSmoke ?? ageSmoke ?? recoverySmoke,args.indices.contains(index+1) {
            Preferences.transferJournalTestDirectory = URL(fileURLWithPath:args[index+1]).appendingPathComponent("Auftragsablage")
        }
        if profilesSmoke != nil || ageSmoke != nil,let index = args.firstIndex(of:"--profile-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.copyProfileTestDefaults = UserDefaults(suiteName:args[index+1])
        }
        if workspaceSmoke != nil,let index = args.firstIndex(of:"--workspace-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.workspaceTestDefaults = UserDefaults(suiteName:args[index+1])
            if args.contains("--reload-workspace"),let data = Preferences.workspaceTestDefaults?.data(forKey:"session"),let state = Preferences.decode(data) { Preferences.state = state }
        }
        if renameSmoke != nil,let index = args.firstIndex(of:"--rename-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.renameTestDefaults = UserDefaults(suiteName:args[index+1])
        }
        if searchSmoke != nil,let index = args.firstIndex(of:"--search-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.searchTestDefaults = UserDefaults(suiteName:args[index+1])
        }
        if compareSmoke != nil,let index = args.firstIndex(of:"--compare-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.compareTestDefaults = UserDefaults(suiteName:args[index+1])
        }
        if appearanceSmoke != nil,let index = args.firstIndex(of:"--appearance-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") { Preferences.appearanceTestDefaults = UserDefaults(suiteName:args[index+1]) }
        if uxSmoke != nil,let index = args.firstIndex(of:"--ux-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") { Preferences.toolbarTestDefaults = UserDefaults(suiteName:args[index+1]) }
        if tabsSmoke != nil,let index = args.firstIndex(of:"--tabs-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") { Preferences.tabGroupsTestDefaults = UserDefaults(suiteName:args[index+1]);Preferences.workspaceTestDefaults = Preferences.tabGroupsTestDefaults }
        if layoutSmoke != nil,let index = args.firstIndex(of:"--layout-test-suite"),args.indices.contains(index+1),args[index+1].hasPrefix("local.zweicommander.tests.") {
            Preferences.layoutTestDefaults = UserDefaults(suiteName:args[index+1]);Preferences.workspaceTestDefaults = Preferences.layoutTestDefaults;Preferences.tabGroupsTestDefaults = Preferences.layoutTestDefaults
            if args.contains("--reload-layout"),let data = Preferences.layoutTestDefaults?.data(forKey:"session"),let state = Preferences.decode(data) { Preferences.state = state }
        }
        if let index = args.firstIndex(of:"--import-settings"),args.indices.contains(index+1) {
            do {
                let profile = try INISettingsImport.load(directory:URL(fileURLWithPath:args[index+1]))
                Preferences.apply(profile)
                if let export = args.firstIndex(of:"--export-settings-profile"),args.indices.contains(export+1) {
                    let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    try encoder.encode(profile).write(to:URL(fileURLWithPath:args[export+1]),options:.atomic)
                }
                print("INI-Einstellungen importiert: \(profile.columns.count) Spalten, \(profile.plugins.filter(\.enabled).count) aktive Plug-in-Einträge. Pfadzuordnungen ausgelassen.")
            } catch { fputs("Einstellungsimport fehlgeschlagen: \(error.localizedDescription)\n",stderr);exit(2) }
        }
        let root = testIndex.flatMap { args.indices.contains($0+1) ? URL(fileURLWithPath:args[$0+1]) : nil }
        let restoringWorkspace = workspaceSmoke != nil && args.contains("--reload-workspace")
        let restoringLayout = layoutSmoke != nil && args.contains("--reload-layout")
        main = MainWindow(startLeft:restoringWorkspace || restoringLayout ? nil : root?.appendingPathComponent("Links"),startRight:restoringWorkspace || restoringLayout ? nil : root?.appendingPathComponent("Rechts"))
        main.onRebuildMenus = { [weak self] in self?.buildMenus(); self?.main.updateFunctionLabels() }
        buildMenus(); main.showWindow(nil); main.active.focus()
        NSApp.activate(ignoringOtherApps:true)
        if let archiveSmoke,args.indices.contains(archiveSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runArchiveSmoke(root:root,prefix:args[archiveSmoke+2]) }
        }
        if let layoutSmoke,args.indices.contains(layoutSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runLayoutSmoke(root:root,prefix:args[layoutSmoke+2],reload:args.contains("--reload-layout")) }
        }
        if let tabsSmoke,args.indices.contains(tabsSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runTabGroupsSmoke(root:root,prefix:args[tabsSmoke+2],reload:args.contains("--reload-tabs")) }
        }
        if let selectionSmoke,args.indices.contains(selectionSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runSelectionSmoke(root:root,prefix:args[selectionSmoke+2]) }
        }
        if let serverPaneSmoke,args.indices.contains(serverPaneSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runServerPaneSmoke(root:root,prefix:args[serverPaneSmoke+2]) }
        }
        if let remoteSmoke,args.indices.contains(remoteSmoke+3),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runRemoteSmoke(root:root,prefix:args[remoteSmoke+2],reload:args[remoteSmoke+3] == "reload") }
        }
        if let recoverySmoke,args.indices.contains(recoverySmoke+3),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runRecoverySmoke(root:root,prefix:args[recoverySmoke+2],reload:args[recoverySmoke+3] == "reload") }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.main.content.layoutSubtreeIfNeeded()
            let split = self.main.content.split
            if !split.arrangedSubviews.contains(where: \.isHidden) {
                split.setPosition(((split.isVertical ? split.bounds.width : split.bounds.height)-split.dividerThickness)*self.main.content.preferredSplitRatio,ofDividerAt:0)
            }
        }
        if let railSmoke,args.indices.contains(railSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runRailSmoke(root:root,prefix:args[railSmoke+2]) }
        }
        if let fileUXSmoke,args.indices.contains(fileUXSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runFileUXSmoke(root:root,prefix:args[fileUXSmoke+2]) }
        }
        if let navigationSmoke,args.indices.contains(navigationSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runNavigationSmoke(root:root,prefix:args[navigationSmoke+2]) }
        }
        if let uxSmoke,args.indices.contains(uxSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runUXSmoke(root:root,prefix:args[uxSmoke+2],reload:args.contains("--reload-ux")) }
        }
        if let appearanceSmoke,args.indices.contains(appearanceSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+1) { self.runAppearanceSmoke(root:root,prefix:args[appearanceSmoke+2],reload:args.contains("--reload-appearance")) }
        }
        if let smoke, args.indices.contains(smoke+2) {
            let imagePath = args[smoke+2]
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
                guard let self else { return }
                self.main.content.layoutSubtreeIfNeeded()
                self.runSmoke(imagePath:imagePath)
            }
        }
        if let operationsSmoke,args.indices.contains(operationsSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runOperationsSmoke(root:root,prefix:args[operationsSmoke+2]) }
        }
        if let filtersSmoke,args.indices.contains(filtersSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runFiltersSmoke(root:root,prefix:args[filtersSmoke+2]) }
        }
        if let mergeSmoke,args.indices.contains(mergeSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runMergeSmoke(root:root,prefix:args[mergeSmoke+2]) }
        }
        if let profilesSmoke,args.indices.contains(profilesSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runProfilesSmoke(root:root,prefix:args[profilesSmoke+2],reload:args.contains("--reload-profiles")) }
        }
        if let journalSmoke,args.indices.contains(journalSmoke+3),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runJournalSmoke(root:root,prefix:args[journalSmoke+2],phase:args[journalSmoke+3]) }
        } else if !Preferences.testMode,(main.jobs.journalError != nil || main.jobs.scheduler.snapshots.contains { $0.state == .review }) {
            DispatchQueue.main.async { self.main.showOperations() }
        }
        if let ageSmoke,args.indices.contains(ageSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runAgeSmoke(root:root,prefix:args[ageSmoke+2],reload:args.contains("--reload-age")) }
        }
        if let workspaceSmoke,args.indices.contains(workspaceSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runWorkspaceSmoke(root:root,prefix:args[workspaceSmoke+2],reload:restoringWorkspace) }
        }
        if let compareSmoke,args.indices.contains(compareSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runCompareSmoke(root:root,prefix:args[compareSmoke+2],reload:args.contains("--reload-compare")) }
        }
        if let searchSmoke,args.indices.contains(searchSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runSearchSmoke(root:root,prefix:args[searchSmoke+2],reload:args.contains("--reload-search")) }
        }
        if let renameSmoke,args.indices.contains(renameSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runRenameSmoke(root:root,prefix:args[renameSmoke+2],reload:args.contains("--reload-rename")) }
        }
    }
    static func parseShortcut(_ text:String) -> (String,NSEvent.ModifierFlags)? {
        if text.isEmpty { return ("",[]) }
        let pieces = text.lowercased().split(separator:"+").map(String.init)
        guard let last = pieces.last else { return nil }
        var flags:NSEvent.ModifierFlags = []
        for piece in pieces.dropLast() {
            switch piece { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "option","alt": flags.insert(.option); case "ctrl","control": flags.insert(.control); default:return nil }
        }
        let key:String
        if last.hasPrefix("f"),let n = Int(last.dropFirst()),(1...20).contains(n) { key = String(UnicodeScalar(Int(NSF1FunctionKey)+n-1)!) }
        else if last == "up" { key = String(UnicodeScalar(NSUpArrowFunctionKey)!) }
        else if last == "down" { key = String(UnicodeScalar(NSDownArrowFunctionKey)!) }
        else if last == "left" { key = String(UnicodeScalar(NSLeftArrowFunctionKey)!) }
        else if last == "right" { key = String(UnicodeScalar(NSRightArrowFunctionKey)!) }
        else if last == "space" { key = " " }
        else if last == "delete" { key = "\u{7f}" }
        else if last == "escape" { key = "\u{1b}" }
        else if last == "tab" { key = "\t" }
        else if last == "return" { key = "\r" }
        else if last.count == 1 { key = last }
        else { return nil }
        return (key,flags)
    }
    static func shortcutOverrides(_ text:String) throws -> [String:String] {
        var keys:[String:String] = [:]
        let known = Set(menuDefinitions.flatMap { $0.1.map { $0.1 } }.filter { !$0.isEmpty })
        for line in text.components(separatedBy:.newlines) where !line.trimmingCharacters(in:.whitespaces).isEmpty {
            let parts = line.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false).map { $0.trimmingCharacters(in:.whitespaces) }
            guard parts.count == 2,known.contains(parts[0]),keys[parts[0]] == nil,parseShortcut(parts[1]) != nil else { throw CommanderError.message("Ungültige oder doppelte Tastenkürzel-Zeile: "+line) }
            keys[parts[0]] = parts[1]
        }
        func signature(_ text:String) -> String? { parseShortcut(text).map { $0.0+":"+String($0.1.rawValue) } }
        var assigned = Set(["cmd+q","cmd+h","cmd+m","cmd+,"].compactMap(signature))
        for (_,commands) in menuDefinitions {
            for (title,id,fallback) in commands where !id.isEmpty {
                let key = keys[id] ?? fallback
                if key.isEmpty { continue }
                guard let normalized = signature(key),assigned.insert(normalized).inserted else { throw CommanderError.message("Tastenkürzel doppelt belegt: \(key) bei „\(title)“.") }
            }
        }
        return keys
    }
    func buildMenus() {
        let profiles = (try? Preferences.layouts().profiles) ?? []
        let bar = NSMenu(); NSApp.mainMenu = bar
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; bar.addItem(appItem)
        let about = appMenu.addItem(withTitle:"Über ZweiCommander",action:#selector(about),keyEquivalent:""); about.target = self
        let settings = appMenu.addItem(withTitle:"Einstellungen …",action:#selector(dispatch(_:)),keyEquivalent:","); settings.representedObject = "settings"; settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"ZweiCommander ausblenden",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"ZweiCommander beenden",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        for (title,commands) in Self.menuDefinitions {
            let menu = NSMenu(title:title), top = NSMenuItem(title:title,action:nil,keyEquivalent:""); top.submenu = menu; bar.addItem(top)
            for (label,id,defaultKey) in commands {
                if id.isEmpty { menu.addItem(.separator()); continue }
                let key = Preferences.state.shortcuts[id] ?? defaultKey, parsed = Self.parseShortcut(key) ?? ("",[])
                // AppKit compares shifted letters using their uppercase key equivalent.
                let shifted = parsed.0.uppercased(),menuKey = parsed.1.contains(.shift) && shifted.count == 1 ? shifted : parsed.0
                let slot = id.hasPrefix("workspace") ? Int(id.dropFirst(9)) : nil
                let title = slot.flatMap { profiles.indices.contains($0-1) ? "\($0) · "+profiles[$0-1].name : nil } ?? label
                let item = NSMenuItem(title:title,action:#selector(dispatch(_:)),keyEquivalent:menuKey); item.keyEquivalentModifierMask = parsed.1;item.allowsAutomaticKeyEquivalentLocalization = Preferences.state.shortcuts[id] == nil; item.target = self; item.representedObject = id;item.toolTip = CommandHelp.menuHelp(id);menu.addItem(item)
            }
        }
        let windowMenu = NSMenu(title:"Fenster"), top = NSMenuItem(title:"Fenster",action:nil,keyEquivalent:""); top.submenu = windowMenu; bar.insertItem(top,at:bar.items.count-1)
        windowMenu.addItem(withTitle:"Minimieren",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(withTitle:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        NSApp.windowsMenu = windowMenu
    }
    @objc func dispatch(_ sender:NSMenuItem) { if let id = sender.representedObject as? String { main.command(id) } }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        guard let id = item.representedObject as? String else { return true }
        if let workflow = main?.keyWorkflowWindow { return workflow.canPerformCommand(id) }
        if id == "pauseTransfers" || id == "stopTransfers" { return main?.jobs.active != nil || (id == "pauseTransfers" && (main?.jobs.pending ?? 0) > 0) }
        if ["operations","recovery"].contains(id) { return true }
        if let compare = main?.keyCompareController { return compare.canPerformCommand(id) }
        if let search = main?.keySearchController { return search.canPerformCommand(id) }
        if let enabled = main?.archiveCommandEnabled(id) { return enabled }
        if let enabled = main?.selectionCommandEnabled(id) { return enabled }
        if let mode = ["tabUnlock":TabLockMode.none,"tabCloseLock":.closeOnly,"tabFixedLock":.fixed,"tabNewLock":.newTab][id] { item.state = main?.active.tab.lockMode == mode ? .on : .off }
        if let enabled = main?.workspaceCommandEnabled(id) { return enabled }
        if let enabled = main?.tabCommandEnabled(id) { return enabled }
        if id == "copy" || id == "move" { item.title = (main?.serverTransferTitle(id) ?? (id == "copy" ? "Kopieren" : "Verschieben"))+" …" }
        if id == "trash" { item.title = main?.active.remote == nil ? "In den Papierkorb …" : "Endgültig auf Server löschen …" }
        if let mode = ["details":PaneDisplayMode.details,"thumbnails":.thumbnails,"icons":.icons][id] { item.state = main?.active.displayMode == mode ? .on : .off }
        if id == "tree" { item.state = main?.active.treeVisible == true ? .on : .off }
        if id == "lockTab" { item.state = main?.active.tab.locked == true ? .on : .off }
        if let enabled = main?.serverCommandEnabled(id) { return enabled }
        if id == "removeCollectionItem" { return main?.active.tab.collection != nil && NSApp.keyWindow === main?.window }
        if item.keyEquivalentModifierMask.isEmpty, item.keyEquivalent == " ", NSApp.keyWindow?.firstResponder is NSTextView { return false }
        return true
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"ZweiCommander",.applicationVersion:Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.23.0",.version:Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "24",.credits:NSAttributedString(string:"Dateimanager für macOS.\nSwift · AppKit · macOS-Systembibliotheken")]) }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if main?.canTerminate == false { _ = dialog("Dateivorgänge laufen",message:"Laufende Vorgänge einschließlich Suchen, vorgemerkte Synchronisationen und Aufträge aus temporären Archivansichten erst abschließen oder entfernen. Gespeicherte wartende Kopier- und Verschiebeaufträge bleiben beim Beenden erhalten.",buttons:["OK"]); return .terminateCancel }
        main?.saveState(); return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { main.showWindow(nil); return true }
    func applicationWillTerminate(_ notification:Notification) {
        main?.saveState()
        if let cache = main?.cache { try? FileManager.default.removeItem(at:cache) }
    }
    func applicationDidBecomeActive(_ notification:Notification) { if main != nil { main.refresh() } }
    func runSmoke(imagePath:String) {
        var failures:[String] = []
        func check(_ condition:Bool,_ name:String) { print("UI \(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures.append(name) } }
        check(main.left.visibleEntries.count == 9 && main.right.visibleEntries.count == 3,"directory listing")
        print("UI geometry left=\(main.left.frame) right=\(main.right.frame) split=\(main.content.split.frame)")
        check(main.left.frame.width > 300 && main.right.frame.width > 300,"two visible panes")
        main.left.filterField.stringValue = "*.txt"; main.left.applyFilter()
        check(main.left.visibleEntries.count == 3,"wildcard quick filter")
        main.left.clearFilter()
        main.right.focus(); check(main.active === main.right,"pane focus")
        main.left.focus(); check(main.active === main.left,"pane switching")
        main.command("tree"); main.content.layoutSubtreeIfNeeded(); check(!main.left.tree.isHidden,"folder tree")
        main.command("tree")
        main.command("orientation"); main.content.layoutSubtreeIfNeeded()
        check(!main.content.split.isVertical && main.left.frame.height > 180 && main.right.frame.height > 180,"horizontal panes")
        main.command("orientation"); main.content.layoutSubtreeIfNeeded()
        main.command("quickView"); main.content.layoutSubtreeIfNeeded(); check(main.content.quickVisible && main.left.frame.width > 250,"quick preview layout")
        main.command("quickView"); main.content.layoutSubtreeIfNeeded()
        let originalTabs = main.left.tabs.count
        main.left.newTab(); check(main.left.tabs.count == originalTabs+1,"new tab")
        main.left.closeTab(); check(main.left.tabs.count == originalTabs,"close tab")
        let keys = Self.menuDefinitions.flatMap { $0.1 }.filter { !$0.2.isEmpty }.map { $0.2.lowercased() }
        check(Set(keys).count == keys.count,"unique default shortcuts")
        main.left.showCollection([],title:"Sammlungstest")
        main.left.addToCollection([main.right.currentURL.appendingPathComponent("Lesen.txt")])
        check(main.left.tab.collection?.count == 1,"collection references")
        main.left.tab.collection = [];main.left.closeTab()
        if let profile = Preferences.state.importedProfile {
            var previous = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state))) as? [String:Any] ?? [:]
            previous["previousProfile"] = previous.removeValue(forKey:"importedProfile")
            let migrated = (try? JSONSerialization.data(withJSONObject:previous)).flatMap { Preferences.decode($0) }
            check(migrated?.importedProfile == profile && migrated?.shortcuts == Preferences.state.shortcuts,"previous profile schema preserved")
            let columns = main.left.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
            check(columns == profile.columns.map(\.id),"imported columns")
            check(main.left.showHidden == profile.showHidden && main.left.importedProfile == profile,"imported appearance and hidden files")
            check(Preferences.state.shortcuts["newCollection"] == profile.shortcuts["newCollection"],"imported shortcuts")
            main.left.restoreConfigurationBeforeImport()
            check(main.left.importedProfile == nil && main.left.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == ["name","ext","size","modified"],"restore original columns")
            main.left.configure(profile:profile,isLeft:true)
            check(main.left.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == profile.columns.map(\.id),"reapply imported columns")
        }
        Preferences.state.theme = 1; main.applyTheme()
        check(main.content.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua,"light appearance")
        Preferences.state.theme = 2; main.applyTheme()
        check(main.content.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"dark appearance")
        Preferences.state.theme = Preferences.state.importedProfile.map { $0.darkAppearance ? 2 : 1 } ?? 0; main.applyTheme()
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in
            guard let self else { return }
            self.main.content.layoutSubtreeIfNeeded()
            if let rep = self.main.content.bitmapImageRepForCachingDisplay(in:self.main.content.bounds) {
                self.main.content.cacheDisplay(in:self.main.content.bounds,to:rep)
                if let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:URL(fileURLWithPath:imagePath)) }
            }
            print("SMOKE \(failures.isEmpty ? "PASS" : "FAIL")")
            if !failures.isEmpty { exit(1) }
            NSApp.terminate(nil)
        }
    }
}

if let index = CommandLine.arguments.firstIndex(of:"--inspect-binary"),CommandLine.arguments.indices.contains(index+1) {
    do { print(try BinaryInspector.describe(URL(fileURLWithPath:CommandLine.arguments[index+1])) ?? "Kein PE-/Mach-O-Binärformat.");exit(0) }
    catch { fputs(error.localizedDescription+"\n",stderr);exit(2) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
