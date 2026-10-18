import AppKit
import CommanderCore

extension MainWindow {
    func terminalScript(_ script:String,title:String) {
        do {
            let file = cache.appendingPathComponent(UUID().uuidString+".command")
            try ("#!/bin/zsh\n"+script+"\n").write(to:file,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
            NSWorkspace.shared.open([file],withApplicationAt:URL(fileURLWithPath:"/System/Applications/Utilities/Terminal.app"),configuration:.init()) { _,error in if let error { DispatchQueue.main.async { showFailure(error) } } }
        } catch { showFailure(error) }
    }
    func shellQuote(_ text:String) -> String { "'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'" }
    func openTerminal() { terminalScript("cd -- "+shellQuote(active.currentURL.path)+"\nexec /bin/zsh -l",title:"Terminal") }
    func shell() {
        guard ensureWritable(active),let command = prompt("Shell-Befehl ausführen",message:"Arbeitsordner: \(active.currentURL.path)\nDer eingegebene Befehl wird mit deinen Benutzerrechten in zsh ausgeführt. Befehle können Dateien verändern. Für interaktive Programme „Terminal öffnen“ verwenden."),!command.isEmpty else { return }
        let root = active.currentURL
        jobs.submit("Shell",work:{ token,_ in try ProcessRunner.run("/bin/zsh",arguments:["-lc",command],directory:root,token:token) },completion:{ [weak self] result in
            switch result { case .success(let text): self?.showText("Shell · "+command,text.isEmpty ? "Prozess erfolgreich beendet, keine Textausgabe." : text); case .failure(let e): self?.showText("Shell · Ergebnis",e.localizedDescription) }; self?.refresh()
        })
    }
    func connectServer() {
        guard let address = prompt("Mit Server verbinden",value:"smb://",message:"macOS verbindet den Server im Finder. Eingebundene SMB-/NFS-/WebDAV-Volumes erscheinen anschließend unter „Orte“."),let url = URL(string:address),let scheme = url.scheme, ["smb","nfs","https","http","afp"].contains(scheme) else { return }
        NSWorkspace.shared.open(url)
    }
    func sftpTerminal() {
        let host = input(),user = input(NSUserName()),port = input("22")
        guard dialog("SFTP im Terminal",message:"Öffnet den macOS-SFTP-Client im Terminal. Dort werden Hostschlüssel und Anmeldung geprüft. Beispiel: ls, get datei, put datei. Lokaler Ordner: "+active.currentURL.path,accessory:form([("Server",host),("Benutzer",user),("Port",port)]),buttons:["Verbinden","Abbrechen"]) == 0 else { return }
        let hostname = host.stringValue,username = user.stringValue
        let safe = CharacterSet(charactersIn:"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard !hostname.isEmpty,!hostname.hasPrefix("-"),hostname.unicodeScalars.allSatisfy({safe.contains($0)}),!username.isEmpty,!username.hasPrefix("-"),username.unicodeScalars.allSatisfy({safe.contains($0)}),let p = Int(port.stringValue),(1...65535).contains(p) else { showFailure(CommanderError.message("Ungültiger Server, Benutzer oder Port.")); return }
        terminalScript("cd -- "+shellQuote(active.currentURL.path)+"\n/usr/bin/sftp -P \(p) "+shellQuote(username+"@"+hostname)+"\n",title:"SFTP")
    }
    func settings() {
        let theme = NSPopUpButton(); theme.addItems(withTitles:["Wie macOS","Hell","Dunkel"]); theme.selectItem(at:Preferences.state.theme)
        let hidden = checkbox("Versteckte Dateien anzeigen",on:Preferences.state.showHidden)
        let shortcuts = NSTextView(frame:NSRect(x:0,y:0,width:360,height:150)); shortcuts.isRichText = false; shortcuts.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        shortcuts.string = Preferences.state.shortcuts.sorted { $0.key < $1.key }.map { $0.key+"="+$0.value }.joined(separator:"\n")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = shortcuts
        let answer = dialog("Einstellungen",message:"Eigene Tastenkürzel: eine Zeile je Befehl, z. B. copy=F5 oder search=cmd+f. Leere Liste verwendet die Standardbelegung. Befehlsnamen stehen in der Hilfe.",accessory:form([("Erscheinungsbild",theme),("",hidden),("Tastenkürzel",scroll)],width:620),buttons:["Speichern","Abbrechen"])
        guard answer == 0 else { return }
        var keys:[String:String] = [:]
        let known = Set(AppDelegate.menuDefinitions.flatMap { $0.1.map { $0.1 } })
        for line in shortcuts.string.components(separatedBy:.newlines) where !line.trimmingCharacters(in:.whitespaces).isEmpty {
            let parts = line.split(separator:"=",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
            guard parts.count == 2,known.contains(parts[0]),AppDelegate.parseShortcut(parts[1]) != nil else { showFailure(CommanderError.message("Ungültige Tastenkürzel-Zeile: "+line)); return }
            keys[parts[0]] = parts[1]
        }
        func shortcutID(_ text:String)->String? { AppDelegate.parseShortcut(text).map { $0.0+":"+String($0.1.rawValue) } }
        var assigned = Set(["cmd+q","cmd+h","cmd+m","cmd+,"].compactMap(shortcutID))
        for (_,commands) in AppDelegate.menuDefinitions {
            for (title,id,defaultKey) in commands where !id.isEmpty {
                let key = (keys[id] ?? defaultKey).lowercased()
                if key.isEmpty { continue }
                guard let normalized = shortcutID(key),assigned.insert(normalized).inserted else { showFailure(CommanderError.message("Tastenkürzel doppelt belegt: \(key) bei „\(title)“.")); return }
            }
        }
        Preferences.state.theme = theme.indexOfSelectedItem; Preferences.state.showHidden = hidden.state == .on; Preferences.state.shortcuts = keys
        left.showHidden = Preferences.state.showHidden; right.showHidden = Preferences.state.showHidden
        applyTheme(); Preferences.save(); onRebuildMenus?(); refresh()
    }
    var helpText:String {
        """
        ZWEICOMMANDER · Version 0.5.0

        ZweiCommander ist ein Dateimanager für macOS.

        BEDIENUNG
        Tab wechselt zwischen den beiden Dateifenstern. Enter öffnet den ausgewählten Ordner oder die Datei. Rückschritt navigiert zum übergeordneten Ordner. Leertaste und F3 öffnen die Vorschau. Die Schnellfilter unterstützen Text, * und ? sowie auf Wunsch reguläre Ausdrücke. Escape leert den Filter.

        F2 Umbenennen · F3 Vorschau · F4 TextEdit · F5 Kopieren · F6 Verschieben
        F7 Neuer Ordner · F8 Papierkorb · Cmd+T Neuer Tab · Cmd+W Tab schließen
        Cmd+L Pfad · Cmd+F Suche · Cmd+Shift+F Schnellfilter · Cmd+R Aktualisieren
        Cmd+C Kopieren · Cmd+X Ausschneiden · Cmd+V Einfügen · Cmd+Z Rückgängig
        Cmd+Shift+M Mehrfachumbenennen · Cmd+Shift+. Versteckte Dateien
        Cmd+Shift+J Aufträge anzeigen

        DATEIEN UND KONFLIKTE
        Dateiaktionen arbeiten mit der Auswahl des aktiven Fensters. Das andere Fenster wird als Ziel vorgeschlagen. Drag-and-drop kopiert und öffnet die Ziel-/Konfliktauswahl. Verschieben oder Ersetzen erfordert eine bewusste Auswahl im Dialog.
        Ersetzen bewahrt das vorherige Ziel unter einem versteckten Namen .zweicommander-backup-… im gleichen Ordner auf. Sicherungen werden nicht automatisch entfernt. „Versteckte Dateien“ einschalten, um sie bei Bedarf zurückzuholen oder in den Papierkorb zu legen.
        Cmd+Z kann den letzten Dateivorgang für unveränderte Einzeldateien oder die letzte Mehrfachumbenennung zurücknehmen. Verzeichnisse werden dabei aus Sicherheitsgründen nicht automatisch zurückgesetzt. Für Papierkorb-Ordner die Wiederherstellung im Finder verwenden. Rückgängig gilt nur für die aktuelle Sitzung.
        Der Auftragsdialog zeigt die geplanten Auswahlobjekte, Größen und belegten Ziele. Einzelne Zeilen lassen sich abwählen. Unter „Geplante Objekte“ erscheinen sämtliche enthaltenen Dateien, Ordner und Links. Kopieraufträge unterstützen Einschluss-/Ausschlussmuster (* und ?, mit ; getrennt) oder reguläre Ausdrücke sowie das Auslassen von Unterordnern. Groß-/Kleinschreibung wird bei den Namen ignoriert; Unterordnermuster sind immer Wildcards. „Leere Ordner übernehmen“ erhält auch durch den Dateifilter leer gewordene Ordner. „Nur Ordnerstruktur“ kopiert ausschließlich Ordner. Ohne „Unterordner einbeziehen“ wird nur die oberste Ebene berücksichtigt. Filter sind bei Verschieben gesperrt. Änderungen an Ziel oder Filtern erfordern eine Aktualisierung des Plans. Die Filter gelten für diesen Auftrag und werden nicht gespeichert. „Vormerken“ hält eine zuvor leere Warteschlange an, „Starten“ gibt sie frei. Im Auftragsfenster können wartende Aufträge umgeordnet, als Nächstes gestartet oder entfernt werden.
        Kopieren meldet übertragene Dateidaten in Bytes. Pause und Abbruch greifen auch innerhalb großer Dateien. Eine noch nicht veröffentlichte Kopie wird bei Abbruch verworfen; fertige Schritte bleiben erhalten. „Pausiert“ erscheint erst, wenn die Arbeit am Prüfpunkt wartet; zuvor heißt es „Pause angefordert“. Pause hält auch nachfolgende Aufträge an. Verschieben verwendet die Systemoperation: dort greifen Pause und Abbruch am nächsten Prüfpunkt, ohne Byte-Fortschrittsmessung. Die Warteschlange ist nur für die laufende Sitzung gespeichert; Fortsetzen nach App-Neustart ist noch nicht implementiert.

        ORDNER ZUSAMMENFÜHREN
        Beim Kopieren kann „Ordner zusammenführen“ eingeschaltet werden. Bestehende echte Zielordner bleiben erhalten. In „Geplante Objekte“ stehen Quell- und Zielgröße sowie Änderungsdatum nebeneinander. Dateikonflikte können einzeln übersprungen, unter dem angezeigten Alternativnamen kopiert oder mit Sicherung ersetzt werden. Bis alle Konflikte entschieden sind, bleiben Starten und Vormerken gesperrt. Konflikte zwischen Ordnern und Dateien oder Links können nur übersprungen werden. Zusätzliche Zieldateien bleiben erhalten. Bereits fertige Schritte und neu angelegte Ordner bleiben bei einem Abbruch bestehen; der gesamte Auftrag wird nicht zurückgerollt.

        ARCHIVE
        Doppelklick öffnet ZIP/TAR und unterstützte RAR-/7z-Archive in einer temporären, schreibgeschützten Ansicht. Von dort können Dateien in das andere Fenster kopiert werden. Unterarchive lassen sich ebenfalls öffnen. F4 oder Änderungen sind in Archivansichten gesperrt.
        Packen erzeugt ZIP, 7z oder mit der Endung .tar.gz ein TAR-GZip-Archiv. Entpacken benötigt einen neuen Zielordner. Absolute Pfade, ../, Links und Spezialdateien werden abgewiesen. Das Entpacklimit beträgt 100 GB. Archive bewahren in dieser Version keine Finder-Tags, Resource Forks oder erweiterten Attribute.

        SUCHE UND VERGLEICH
        Suche durchläuft Unterordner. Inhaltssuche liest UTF-8/UTF-16-Textdateien bis 32 MB. Die Office-Option extrahiert Text aus DOCX, XLSX, PPTX und ODT; maximal 32 MB relevante XML-Daten pro Dokument. Größere Dateien werden im Bericht genannt. Die Archivsuche sucht Dateinamen, keine Inhalte. Gespeicherte Dateisammlungen enthalten Pfade, keine Dateikopien. In einer Dateisammlung fügt ein Drop nur Verweise hinzu; „Aus Sammlung entfernen“ löscht keine Originaldatei.
        Duplikate werden anhand von Größe und SHA-256 erkannt; es wird nichts automatisch gelöscht. Der Ordnervergleich kann ebenfalls SHA-256 verwenden. Synchronisieren ergänzt und ersetzt nur in der gewählten Richtung. Es löscht keine zusätzlichen Zieldateien. Typkonflikte und Verknüpfungen müssen zuerst manuell geklärt werden.

        INI-EINSTELLUNGEN
        Das Hilfe-Menü importiert unterstützte INI-Hauptdateien mit den zugehörigen .shc-, .find.ini-, .mren.ini- und .wcx.ini-Dateien. Übernommen werden unterstützte Spalten, Listenfarben, Sortierung, versteckte Dateien und Tastenkürzel sowie Such-, Zähler- und Archivvorgaben. Favoriten und Laufwerkspfade bleiben unberücksichtigt. Der Importbericht zeigt erkannte aktive und inaktive Plug-ins. Windows-Programme werden nicht geladen. Die Dateistruktur-Vorschau liest PE-/Mach-O-Köpfe und PE-Versionsinformationen. Quick Look ergänzt die Office-Textvorschau. Über das Hilfe-Menü lassen sich die Einstellungen vor dem Import wiederherstellen.

        MACOS
        Systemeinstellungen → Datenschutz & Sicherheit regelt den Zugriff auf geschützte Ordner. Diese App umgeht die macOS-Zugriffskontrollen nicht. Eingebundene Netzwerkvolumes werden wie lokale Ordner angezeigt. Der FTP/FTPS/SFTP-Dialog kann Serverordner anzeigen und einzelne Dateien hoch-/herunterladen. SFTP setzt einen eingerichteten SSH-Schlüssel/ssh-agent und geprüfte Hostschlüssel voraus. Rekursive SFTP-Transfers und Passwortanmeldung sind über den Terminalclient möglich. Remote-Transfers überschreiben keine bei der Vorprüfung vorhandenen Namen. Ein unterbrochener Upload kann eine unvollständige Remote-Datei hinterlassen.

        STAND DIESER VERSION
        Dies ist eine frühe Version. Unter anderem fehlen rekursive Remote-Transfers im Fenster, Windows-Plug-ins, MTP-/iPhone-Geräteprotokolle, Metadaten-Plug-ins, automatische Ansichtsprofile, Secure Wipe und eine dauerhafte Warteschlange. Eine vollständige Liste liegt beim Quellcode.

        TASTENKÜRZEL-BEFEHLE
        """ + AppDelegate.menuDefinitions.flatMap { $0.1 }.map { "\($0.1) = \($0.0)  [\($0.2)]" }.joined(separator:"\n")
    }
}
