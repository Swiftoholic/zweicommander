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
        executeShellCommand(command,in:active.currentURL)
    }
    func executeShellCommand(_ command: String,in root: URL) {
        jobs.submit("Shell",work:{ token,_ in try ProcessRunner.run("/bin/zsh",arguments:["-lc",command],directory:root,token:token) },completion:{ [weak self] result in
            switch result { case .success(let text): self?.showText("Shell · "+command,text.isEmpty ? "Prozess erfolgreich beendet, keine Textausgabe." : text);case .failure(let error): self?.showText("Shell · Ergebnis",error.localizedDescription) };self?.refresh()
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
        let appearance = Preferences.appearanceSettings()
        let density = NSPopUpButton();density.addItems(withTitles:["Kompakt","Mehr Abstand"]);density.selectItem(at:appearance.compact ? 0 : 1)
        let fontSize = NSPopUpButton();fontSize.addItems(withTitles:AppearanceSettings.fontSizes.map { $0 == 0 ? "Vorgabe / Import" : "\($0) pt" });fontSize.selectItem(at:AppearanceSettings.fontSizes.firstIndex(of:appearance.fontSize) ?? 0)
        let toolbarLabels = checkbox("Beschriftungen unter Werkzeug-Symbolen",on:appearance.toolbarLabels)
        let importedColors = checkbox("Importierte Farben passend zum Modus verwenden",on:appearance.importedColors)
        let hidden = checkbox("Versteckte Dateien anzeigen",on:Preferences.state.showHidden)
        let shortcuts = CommanderTextView(frame:NSRect(x:0,y:0,width:360,height:150)); shortcuts.isRichText = false; shortcuts.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        shortcuts.string = Preferences.state.shortcuts.sorted { $0.key < $1.key }.map { $0.key+"="+$0.value }.joined(separator:"\n")
        shortcuts.updateColors()
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.documentView = shortcuts
        let answer = dialog("Einstellungen",message:"Eigene Tastenkürzel: eine Zeile je Befehl, z. B. copy=F5 oder search=cmd+f. Leere Liste verwendet die Standardbelegung. Befehlsnamen stehen in der Hilfe.",accessory:form([("Erscheinungsbild",theme),("Listendichte",density),("Listenschrift",fontSize),("Werkzeugleiste",toolbarLabels),("Farben",importedColors),("",hidden),("Tastenkürzel",scroll)],width:660),buttons:["Speichern","Abbrechen"])
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
        var updatedAppearance = AppearanceSettings();updatedAppearance.compact = density.indexOfSelectedItem == 0;updatedAppearance.fontSize = AppearanceSettings.fontSizes[fontSize.indexOfSelectedItem];updatedAppearance.toolbarLabels = toolbarLabels.state == .on;updatedAppearance.importedColors = importedColors.state == .on
        do { try Preferences.saveAppearance(updatedAppearance) } catch { showFailure(error);return }
        Preferences.state.theme = theme.indexOfSelectedItem; Preferences.state.showHidden = hidden.state == .on; Preferences.state.shortcuts = keys
        left.showHidden = Preferences.state.showHidden; right.showHidden = Preferences.state.showHidden
        applyTheme();applyAppearanceSettings();Preferences.save();onRebuildMenus?();refresh()
    }
    var helpText:String {
        """
        ZWEICOMMANDER · Version 0.14.1

        ZweiCommander ist ein Dateimanager für macOS.

        BEDIENUNG
        Tab wechselt zwischen den beiden Dateifenstern. Enter öffnet den ausgewählten Ordner oder die Datei. Rückschritt navigiert zum übergeordneten Ordner. Leertaste und F3 öffnen die Vorschau. Die Schnellfilter unterstützen Text, * und ? sowie auf Wunsch reguläre Ausdrücke. Escape leert den Filter.

        F2 Umbenennen · F3 Vorschau · F4 TextEdit · F5 Kopieren · F6 Verschieben
        F7 Neuer Ordner · F8 Papierkorb · Cmd+T Neuer Tab · Cmd+W Tab schließen
        Cmd+L Pfad · Cmd+F Suche · Cmd+Shift+F Schnellfilter · Cmd+R Aktualisieren
        Cmd+C Kopieren · Cmd+X Ausschneiden · Cmd+V Einfügen · Cmd+Z Rückgängig
        Cmd+Shift+M Mehrfachumbenennen · Cmd+Shift+. Versteckte Dateien
        Cmd+Shift+J Aufträge anzeigen

        DARSTELLUNG UND NAVIGATION
        Oben rechts zwischen System, Hell und Dunkel wählen. Hell verwendet helle Dateilisten und Dokumentflächen; Dunkel Grautöne mit heller Schrift. Die aktive Seite erhält eine blaue Pfadzeile. Importierte Hintergrundfarben gelten nur im passenden Modus; Schrift- und Dateitypfarben werden bei Bedarf für ausreichenden Kontrast angepasst. Über Einstellungen lassen sich kompakte oder größere Zeilen, Listenschriftgröße, Werkzeugbeschriftungen und importierte Farben wählen. Die Darstellungsvorgaben werden getrennt von Tabs und Importprofil lokal gespeichert.
        Beide Seiten haben eigene Ortsleisten. Pfadbestandteile sind anklickbar; „…“ zeigt alle übergeordneten Ordner. Cmd+L öffnet den Pfadeditor, Escape kehrt zur Pfadzeile zurück. Jeder ungesperrte Tab hat bei mehreren Tabs einen eigenen Schließen-Knopf. Die mittlere Funktionsleiste bietet verteilte Gruppen für Tausch, Vergleich, gleichen Ordner, verknüpftes Navigieren, Anordnung und Einzelansicht; der Papierkorb steht am Ende. Nur die schmale Kante daneben verändert die Fensteraufteilung. Die Funktionsleiste verwendet den normalen Mauszeiger.
        Die untere Eingabezeile startet im Modus „Pfad“ und öffnet mit Enter einen absoluten oder zum aktiven Ordner relativen Ordnerpfad. Im ausdrücklich gewählten Modus „Befehl“ führt Enter zsh mit deinen Benutzerrechten im aktiven Ordner aus und zeigt die Textausgabe. Shell-Befehle können Dateien verändern; für interaktive Programme den Terminal-Knopf verwenden. Es wird kein Befehlsverlauf gespeichert.

        KOPIEREN, VERSCHIEBEN UND FILTER
        F5 und F6 zeigen die Zielrichtung; ohne Auswahl sind die Knöpfe deaktiviert. Bei einer Dateisammlung als Ziel fügt F5 Verweise hinzu und erhält die Originaldateien. Der Übertragungsdialog zeigt zuerst Quelle, Ziel, Konfliktregel und Vorschau. „Weitere Optionen“ blendet Kopierprofile, Namens-/Größen-/Datumsfilter und Ordnerregeln ein. Aktive Regeln bleiben bei geschlossenen Optionen sichtbar. Änderungen werden nach kurzer Tippause neu geprüft. Offene Konflikte sowie „Abbrechen bei Konflikt“ mit belegten Zielen sperren Kopieren und Vormerken bis zu einer anderen Entscheidung.
        Eine zusätzliche Filterzeile zeigt Trefferzahl und Gesamtzahl der eingelesenen Objekte. „Filter aufheben“ entfernt Muster und RegEx-Modus. Leere Ordner, fehlende Treffer, ungültige Ausdrücke und Ladefehler werden direkt in der Dateifläche erklärt. Bei Ladefehlern steht „Erneut versuchen“ bereit. Eine Hintergrundaktualisierung des gleichen Ordners erhält Auswahl und Dateiaktionen.
        Über „Ansicht → Werkzeugleiste anpassen …“ oder das Menü am rechten Ende der Werkzeugleiste Befehle einblenden, ausblenden und ordnen. Erst „Übernehmen“ speichert die Auswahl lokal. Bei schmalen Fenstern enthält das Menü die nicht mehr passenden Befehle. „Miniaturbilder“ ändert die Dateiansicht; „Schnellansicht“ öffnet die Vorschau rechts.

        ANSICHTEN, TABS UND FAVORITEN
        Cmd+1 zeigt Details, Cmd+2 Miniaturbilder, Cmd+3 Symbole. Darstellung, Sortierspalte und Richtung lassen sich auch direkt über der Dateiliste wählen. Auswahl, Schnellfilter, Vorschau, Zwischenablage und Dateiaktionen gelten in allen drei Darstellungen. Bildvorschauen werden verkleinert geladen; andere Dateien behalten ihr Programmsymbol.
        Tabs lassen sich innerhalb eines Dateifensters ziehen oder über das Tabs-Menü verschieben. Das Kontextmenü bietet Duplizieren, Benennen, Sperren und Schließen. „Andere Tabs schließen“ erhält gesperrte Tabs. Cmd+Option+Pfeil rechts/links wechselt Tabs. Normale Tabs speichern Reihenfolge, ausgewählten Tab und ihre manuell gewählte Ansicht; Archive und Sammlungen bleiben sitzungsbezogen.
        „Ansicht → Ordneransicht merken …“ speichert Darstellung, Sortierung, Ordnerbaum und Spalten für den aktuellen Ordner, auf Wunsch mit Unterordnern. Die speziellste passende Regel hat Vorrang. Unter „Gespeicherte Ordneransichten …“ lassen sich der Geltungsbereich ändern und Regeln entfernen. Ohne passende Regel gilt wieder die manuelle Ansicht des Tabs. Die Regeln beziehen sich auf vollständige Pfadnamen; symbolische Ordnerverknüpfungen haben ihre eigenen Pfade.
        „Gehe zu → Favoriten bearbeiten …“ oder der letzte Eintrag im Favoritenmenü öffnet die Verwaltung für Ordner und macOS-Programme. Name und Ziel mit Übernehmen speichern; Pfeile und Entfernen wirken sofort. Bei Programmen kann „Ausgewählte Dateien öffnen“ aktiviert werden. Dann benötigt der Aufruf eine Dateiauswahl. Ohne diese Option startet das Programm. Alle Angaben bleiben in den lokalen Benutzereinstellungen. Beschädigte Daten werden nicht automatisch ersetzt.

        MEHRFACHUMBENENNEN
        Cmd+Shift+M öffnet einen Arbeitsbereich mit Livevorschau. Nur angehakte Dateien werden verarbeitet und gezählt. Die Pfeile sowie das Reihenfolgemenü ordnen die Auswahl vor der Nummerierung. Zeilenfehler und doppelte oder belegte Ziele sperren den gesamten Auftrag. Änderungen an Regeln verwerfen sofort den ausführbaren Plan.
        Platzhalter: {name} ohne Endung, {full} vollständiger Name, {ext} Endung, {n} Zähler, {parent} tatsächlicher Elternordner, {date} Änderungs- oder Erstellungsdatum. {name:2:5} nimmt fünf Zeichen ab Position 2; Unicode-Zeichen bleiben zusammen. {{ und }} schreiben Klammern. Eingesetzte Dateinamen werden nicht nochmals als Platzhalter ausgewertet.
        Ohne {full}/{ext} bleibt die Endung erhalten. „Endung separat bearbeiten“ verwendet das Endungsmuster ohne Punkt; leer entfernt die Endung. Im Namensmuster dann {name} verwenden. Ordner erhalten keine zusätzliche Endung. Zähler unterstützen positive und negative Schritte ungleich null, 1–20 Stellen und einen Neustart je Ordner. Suchen/Ersetzen und Schreibweise können auf den ganzen Namen, den Namen ohne Endung oder die Endung beschränkt werden. RegEx-Ersetzungen unterstützen Gruppen wie $1.
        Das Datumsformat ist frei wählbar, etwa yyyyMMdd_HHmmss. Dateidaten verwenden die lokale Zeitzone oder UTC. {width}/{height} lesen Bildabmessungen, {taken} das EXIF-Originalaufnahmedatum ohne Zeitzonenumrechnung. Fehlende Metadaten sind Zeilenfehler; einzelne Dateien lassen sich abwählen. Bilddaten werden nur aus regulären Dateien bis 64 MiB gelesen, nicht aus Verknüpfungen.
        Bis zu 50 benannte Umbenennungsprofile bleiben lokal gespeichert. Sie enthalten Regeln, keine ausgewählten Pfade. Profile werden ausdrücklich geladen; andere offene Fenster behalten ungespeicherte Eingaben. Beschädigte Profildaten werden nicht ersetzt.
        „Umbenennen“ führt den geprüften Plan als Hintergrundauftrag aus. Der Abbruchknopf betrifft diesen Auftrag; Rückgängig über Cmd+Z läuft ebenfalls im Hintergrund und prüft die Dateiversionen. Quellen und Elternordner werden erneut geprüft; bestehende Ziele werden nicht überschrieben. Bei kontrolliertem Abbruch werden vorbereitete Namen möglichst zurückgesetzt. Blockiert ein fremdes Objekt die Wiederherstellung, bleiben eigene Zwischenablagen erhalten und der Bericht nennt ihre Orte. Mehrfachnamen desselben Dateiobjekts sowie gemeinsam ausgewählte Ordner und enthaltene Objekte müssen getrennt verarbeitet werden. Umbenennungen und Rückgängig bleiben sitzungsbezogen.

        DATEIEN UND KONFLIKTE
        Dateiaktionen arbeiten mit der Auswahl des aktiven Fensters. Das andere Fenster wird als Ziel vorgeschlagen. Drag-and-drop kopiert und öffnet die Ziel-/Konfliktauswahl. Verschieben oder Ersetzen erfordert eine bewusste Auswahl im Dialog.
        Ersetzen bewahrt das vorherige Ziel unter einem versteckten Namen .zweicommander-backup-… im gleichen Ordner auf. Sicherungen werden nicht automatisch entfernt. „Versteckte Dateien“ einschalten, um sie bei Bedarf zurückzuholen oder in den Papierkorb zu legen.
        Cmd+Z kann den letzten Dateivorgang für unveränderte Einzeldateien oder die letzte Mehrfachumbenennung zurücknehmen. Verzeichnisse werden dabei aus Sicherheitsgründen nicht automatisch zurückgesetzt. Für Papierkorb-Ordner die Wiederherstellung im Finder verwenden. Rückgängig gilt nur für die aktuelle Sitzung.
        Der Auftragsdialog zeigt die geplanten Auswahlobjekte, Größen und belegten Ziele. Einzelne Zeilen lassen sich abwählen. Unter „Geplante Objekte“ erscheinen sämtliche enthaltenen Dateien, Ordner und Links. Kopieraufträge unterstützen Einschluss-/Ausschlussmuster (* und ?, mit ; getrennt) oder reguläre Ausdrücke sowie das Auslassen von Unterordnern. Groß-/Kleinschreibung wird bei den Namen ignoriert; Unterordnermuster sind immer Wildcards. „Leere Ordner übernehmen“ erhält auch durch den Dateifilter leer gewordene Ordner. „Nur Ordnerstruktur“ kopiert ausschließlich Ordner. Ohne „Unterordner einbeziehen“ wird nur die oberste Ebene berücksichtigt. Filter sind bei Verschieben gesperrt. Änderungen an Ziel oder Filtern erfordern eine Aktualisierung des Plans. Die Filter gelten für diesen Auftrag; benannte Kopierprofile können sie für spätere Aufträge speichern. „Vormerken“ hält eine zuvor leere Warteschlange an, „Starten“ gibt sie frei. Im Auftragsfenster können wartende Aufträge umgeordnet, als Nächstes gestartet oder entfernt werden.
        Kopieren meldet übertragene Dateidaten in Bytes. Pause und Abbruch greifen auch innerhalb großer Dateien. Eine noch nicht veröffentlichte Kopie wird bei Abbruch verworfen; fertige Schritte bleiben erhalten. „Pausiert“ erscheint erst, wenn die Arbeit am Prüfpunkt wartet; zuvor heißt es „Pause angefordert“. Pause hält auch nachfolgende Aufträge an. Verschieben verwendet die Systemoperation: dort greifen Pause und Abbruch am nächsten Prüfpunkt, ohne Byte-Fortschrittsmessung. Kopier- und Verschiebeaufträge speichern ihre Absicht und den zuletzt gemeldeten Fortschritt lokal. Andere Hintergrundvorgänge bleiben sitzungsbezogen.

        AUFTRÄGE NACH NEUSTART
        Offene Kopier- und Verschiebeaufträge erscheinen nach einem Neustart mit „Erneut prüfen“. Es wird nichts automatisch ausgeführt. Der angezeigte Fortschritt ist der letzte gemeldete Stand. „Erneut prüfen …“ liest Quellen und Ziele neu ein; einzelne Konfliktentscheidungen müssen erneut getroffen werden. Fehlende Quellen werden genannt und ausgelassen, nicht automatisch als erfolgreich verschoben gewertet. Starten oder Vormerken ersetzt den alten Auftrag durch den neu geprüften Plan. Vorhandene fertige Ziele können beispielsweise übersprungen werden. Unvollständige Dateien werden neu kopiert; es gibt kein Fortsetzen an einer Byteposition.
        Regeln, Pfade und Reihenfolge liegen nur lokal in Library/Application Support/ZweiCommander/Transfers im Benutzerordner. Bis zu 200 Aufträge und 16 MiB sind vorgesehen; je Auftrag werden höchstens 200 Objektzeilen als Fortschrittsauszug gespeichert. „Erledigte ausblenden“ erhält noch zu prüfende Aufträge. Gespeicherte wartende Dateiübertragungen erlauben reguläres Beenden. Laufende Vorgänge, andere Sitzungsvorgänge und Aufträge aus temporären Archivansichten müssen zuvor abgeschlossen oder entfernt werden. Beschädigte oder außerhalb der App geänderte Auftragsdaten werden nicht automatisch überschrieben. Speicherfehler während einer Übertragung fordern einen Abbruch an und halten die Warteschlange an. Nach abruptem Prozessende können versteckte unveröffentlichte Kopien zurückbleiben; sie werden beim Wiederanlauf nicht automatisch entfernt. Rückgängig und Sicherungsverwaltung bleiben auf die Sitzung beschränkt.

        KOPIERPROFILE UND ZUSÄTZLICHE FILTER
        „Speichern als …“ legt ein benanntes Kopierprofil an. Es umfasst Namens-/Unterordnerfilter, Rekursion, leere Ordner, Strukturkopie, Größe, Änderungsdatum, die globale Konfliktregel und Zusammenführen. Pfade, die Dateiauswahl und Entscheidungen für einzelne Konflikte werden nicht gespeichert. Neue Kopierdialoge starten mit eigenen Einstellungen; ein Profil muss ausdrücklich ausgewählt werden. „Speichern“ aktualisiert das ausgewählte Profil. Änderungen an den Feldern verändern das Profil erst nach dem Speichern. Bis zu 50 Profile können lokal gespeichert werden. Nicht lesbare Profildaten werden nicht automatisch ersetzt.
        „Größe / Datum …“ ergänzt eine minimale und maximale Dateigröße sowie feste Zeitpunkte für „Geändert ab“ und „Geändert vor“. Beide Größengrenzen sind einschließlich, der Beginn des Zeitbereichs einschließlich und das Ende ausschließlich. Leer bedeutet keine Grenze. Ohne Einheit gilt Byte; KB/MB/GB verwenden 1000, KiB/MiB/GiB verwenden 1024. Punkt oder Komma dient als Dezimalzeichen, ohne Tausendertrennzeichen. Aktive Größen- oder Datumsgrenzen lassen symbolische Links aus. Bei Strukturkopie sind die Grenzen ausgesetzt. Beim Ausschalten der Strukturkopie kehrt die zuvor gewählte Regel für leere Ordner zurück.

        RELATIVES DATEIALTER
        Unter „Größe / Datum …“ kann „Relatives Alter“ gewählt werden. „Mindestens so alt“ und „Höchstens so alt“ beziehen sich auf das Änderungsdatum, jeweils einschließlich der Grenze. Ein leeres Feld bleibt unbeschränkt. Zum Beispiel: höchstens 7 Tage für die letzte Woche oder mindestens 1 Tag und höchstens 1 Woche. Künftige Änderungsdaten werden ausgelassen. Ganze Zahlen in Minuten, Stunden, Tagen und Wochen sind möglich; ein Tag hat genau 24 Stunden, eine Woche 7 Tage. Jede Grenze darf höchstens 36.500 Tage betragen. Kalendermonate/-jahre und auf Mitternacht gerundete Bereiche sind nicht vorgesehen.
        Der Dateiplan hält eine gemeinsame Bezugszeit fest; der Hinweistext der Filterzusammenfassung zeigt sie an. Auch vorgemerkte Aufträge verwenden diesen Zeitpunkt. „Plan aktualisieren“, Profil laden oder „Erneut prüfen …“ nach einem Neustart berechnen neu. Profile und Aufträge speichern die Regel, nicht die alte Bezugszeit. Feste Zeitpunkte und relatives Alter sind getrennte Modi. Strukturkopie setzt Altersregeln aus; Verschieben unterstützt diese Filter nicht. Profile und Auftragsdateien mit Altersregeln benötigen Version 0.8 oder neuer; ältere Daten ohne solche Regeln bleiben lesbar.

        ORDNER ZUSAMMENFÜHREN
        Beim Kopieren kann „Ordner zusammenführen“ eingeschaltet werden. Bestehende echte Zielordner bleiben erhalten. In „Geplante Objekte“ stehen Quell- und Zielgröße sowie Änderungsdatum nebeneinander. Dateikonflikte können einzeln übersprungen, unter dem angezeigten Alternativnamen kopiert oder mit Sicherung ersetzt werden. Bis alle Konflikte entschieden sind, bleiben Starten und Vormerken gesperrt. Konflikte zwischen Ordnern und Dateien oder Links können nur übersprungen werden. Zusätzliche Zieldateien bleiben erhalten. Bereits fertige Schritte und neu angelegte Ordner bleiben bei einem Abbruch bestehen; der gesamte Auftrag wird nicht zurückgerollt.

        ARCHIVE
        Doppelklick öffnet ZIP/TAR und unterstützte RAR-/7z-Archive in einer temporären, schreibgeschützten Ansicht. Von dort können Dateien in das andere Fenster kopiert werden. Unterarchive lassen sich ebenfalls öffnen. F4 oder Änderungen sind in Archivansichten gesperrt.
        Packen erzeugt ZIP, 7z oder mit der Endung .tar.gz ein TAR-GZip-Archiv. Entpacken benötigt einen neuen Zielordner. Absolute Pfade, ../, Links und Spezialdateien werden abgewiesen. Das Entpacklimit beträgt 100 GB. Archive bewahren in dieser Version keine Finder-Tags, Resource Forks oder erweiterten Attribute.

        SUCHE UND VERGLEICH
        Cmd+F öffnet ein eigenes Suchfenster. Mehrere Namensmuster mit Semikolon trennen; ohne Platzhalter wird ein Namensteil gesucht. Namens-RegEx, ausgeschlossene Dateinamen und ganze Unterordner, Rekursion, versteckte Einträge und Dateien/Ordner sind einstellbar. „Größe und Datum …“ ergänzt Größenbereiche, feste Zeitpunkte oder relatives Alter mit einer gemeinsamen Bezugszeit je Suche. Namensausschlüsse und Ordnerausschlüsse verwenden * und ?. Die Ergebnisliste lässt sich zusätzlich filtern und nach Spalten sortieren.
        Treffer erscheinen während der Suche. Abbrechen behält die bisherigen Ergebnisse; eine erreichte Treffergrenze wird als Teilergebnis markiert. Standard sind 10.000, höchstens 50.000 Treffer. „Im Dateifenster“ zeigt und markiert den ausgewählten Treffer im ursprünglichen Dateifenster. Kopieren verwendet die Suchauswahl und öffnet den regulären Dateiplan mit dem gegenüberliegenden Fenster als Ziel. Mehrere echte Dateitreffer lassen sich als Sammlung übernehmen. Archivtreffer öffnen das zugehörige Archiv; sie sind keine Dateipfade und können nicht direkt kopiert werden.
        Inhaltssuche sucht wörtlichen Text, auf Wunsch mit Groß-/Kleinschreibung oder ganzen Wörtern. Automatisch erkannt werden UTF-8 und UTF-16 mit BOM. UTF-16 ohne BOM und Windows-1252 sind ausdrücklich wählbar. Reguläre Textdateien werden bis 32 MiB gelesen. Die Office-Option extrahiert bis 32 MiB relevante XML-Daten aus DOCX, XLSX, PPTX und ODT. Symbolische Links werden nicht für Inhalte verfolgt. Archivsuche prüft nur Namen und Größen; Inhalt und Datum sind ein getrennter Suchmodus. Hinweise nennen Leseprobleme und Limits; höchstens 200 Hinweistexte werden behalten.
        Bis zu 50 Suchprofile mit zusammen höchstens 1 MiB speichern nur Regeln, keinen Suchordner oder Treffer. Sie bleiben lokal und werden ausdrücklich geladen. Beschädigte oder unbekannte Daten sperren Änderungen. Die Suche läuft unabhängig von Dateiübertragungen und wird beim Schließen ihres Fensters abgebrochen.
        Gespeicherte Dateisammlungen enthalten Pfade, keine Dateikopien. In einer Dateisammlung fügt ein Drop nur Verweise hinzu; „Aus Sammlung entfernen“ löscht keine Originaldatei.
        Duplikate werden anhand von Größe und SHA-256 erkannt; es wird nichts automatisch gelöscht.

        ORDNERVERGLEICH UND SYNCHRONISATION
        Cmd+Shift+D öffnet den Arbeitsbereich für die beiden normalen Dateifenster. Zwei getrennte, nicht ineinander liegende Ordner wählen. Vergleich nach SHA-256-Inhalt, Größe/Änderungszeit oder nur Größe. Zeittoleranz: 0 bis 3600 Sekunden einschließlich der Grenze. Namensmuster und Ausschlüsse unterstützen * und ?; mehrere Muster mit Semikolon trennen. Ordnerausschlüsse schneiden ganze Zweige ab. Ordner bleiben zur Darstellung der Struktur sichtbar. Arbeits- und Sicherungsnamen mit .zweicommander- werden immer ausgelassen.
        Die Liste zeigt Pfad, Zustand sowie Größe und Datum beider Seiten. Filter und Spaltensortierung ändern nur die Ansicht. Pro Zeile Links → Rechts, Rechts → Links oder Auslassen wählen. „Auswahl →“, „← Auswahl“ und „Auswahl auslassen“ bearbeiten mehrere markierte Zeilen. Vorschläge gelten für alle Zeilen: eine Richtung, neuere/fehlende Dateien in beide Richtungen oder nur fehlende. Bei unterschiedlichen Inhalten mit zu ähnlichen Zeitpunkten bleibt die Richtung offen; manuell entscheiden oder auslassen. Gleiche Dateien, Links, Spezialdateien, Typ- und Schreibweisenkonflikte werden nicht automatisch kopiert. Nachfahren eines blockierenden Konflikts bleiben ebenfalls gesperrt.
        „Plan prüfen …“ zeigt jede konkrete Quelle, jedes Ziel, neue Ordner und Ersetzungen. Erst Starten oder Vormerken gibt den Auftrag frei. Es werden nur aufgeführte Dateien übertragen; erforderliche Elternordner kommen dazu, keine nicht aufgeführten Unterordnerinhalte. Zusätzliche Dateien bleiben erhalten. Kopien laufen mit Byte-Fortschritt, Pause und Abbruch über die Warteschlange. Ersetzungen erhalten versteckte Sicherungen. Fertige Schritte bleiben bei Abbruch erhalten; es gibt keine automatische Gesamtrücksetzung. Dateien können über die bestehende Sitzungsfunktion zurückgenommen werden; neu angelegte Ordner werden dabei nicht entfernt. Nach einem Auftrag erneut vergleichen.
        Vormerkungen für Synchronisation sind sitzungsbezogen und müssen vor Beenden ausgeführt oder entfernt werden. Es gibt keine Löschspiegelung, dauerhafte Zweiwege-Beziehung oder Konfliktzusammenführung. Bis zu 50 lokale Vergleichsprofile speichern Regeln und Vorschlag, keine Ordner oder Zeilenentscheidungen. Beschädigte Profildaten bleiben erhalten. Vergleich auf höchstens 50.000 erfasste Einträge je Seite und 50.000 gemeinsame Zeilen begrenzt; gegebenenfalls kleinere Ordner oder mehr Ordnerausschlüsse wählen.

        INI-EINSTELLUNGEN
        Das Hilfe-Menü importiert unterstützte INI-Hauptdateien mit den zugehörigen .shc-, .find.ini-, .mren.ini- und .wcx.ini-Dateien. Übernommen werden unterstützte Spalten, Listenfarben, Sortierung, versteckte Dateien und Tastenkürzel sowie Such-, Zähler- und Archivvorgaben. Favoriten und Laufwerkspfade bleiben unberücksichtigt. Der Importbericht zeigt erkannte aktive und inaktive Plug-ins. Windows-Programme werden nicht geladen. Die Dateistruktur-Vorschau liest PE-/Mach-O-Köpfe und PE-Versionsinformationen. Quick Look ergänzt die Office-Textvorschau. Über das Hilfe-Menü lassen sich die Einstellungen vor dem Import wiederherstellen.

        MACOS
        Systemeinstellungen → Datenschutz & Sicherheit regelt den Zugriff auf geschützte Ordner. Diese App umgeht die macOS-Zugriffskontrollen nicht. Eingebundene Netzwerkvolumes werden wie lokale Ordner angezeigt. Der FTP/FTPS/SFTP-Dialog kann Serverordner anzeigen und einzelne Dateien hoch-/herunterladen. SFTP setzt einen eingerichteten SSH-Schlüssel/ssh-agent und geprüfte Hostschlüssel voraus. Rekursive SFTP-Transfers und Passwortanmeldung sind über den Terminalclient möglich. Remote-Transfers überschreiben keine bei der Vorprüfung vorhandenen Namen. Ein unterbrochener Upload kann eine unvollständige Remote-Datei hinterlassen.

        STAND DIESER VERSION
        Dies ist eine frühe Version. Unter anderem fehlen rekursive Remote-Transfers im Fenster, Windows-Plug-ins, MTP-/iPhone-Geräteprotokolle, frei programmierbare Metadaten-Spalten, ID3-Regeln, Secure Wipe und das Fortsetzen großer Dateien an Bytepositionen. Eine vollständige Liste liegt beim Quellcode.

        TASTENKÜRZEL-BEFEHLE
        """ + AppDelegate.menuDefinitions.flatMap { $0.1 }.map { "\($0.1) = \($0.0)  [\($0.2)]" }.joined(separator:"\n")
    }
}
