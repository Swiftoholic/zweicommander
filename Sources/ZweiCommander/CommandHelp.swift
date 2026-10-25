import AppKit

enum CommandHelp {
    private static let details: [String:String] = [
        "back":"Zum vorherigen Ordner dieses Tabs zurückkehren.",
        "forward":"Den nächsten Ordner im Verlauf dieses Tabs öffnen.",
        "parent":"Eine Ordnerebene nach oben wechseln.",
        "home":"Deinen macOS-Benutzerordner in dieser Seite öffnen.",
        "path":"Adresse bearbeiten. Ordner werden beim Tippen vorgeschlagen; Tab ergänzt, Enter öffnet.",
        "pack":"Ausgewählte Dateien und Ordner in ein neues Archiv packen.",
        "extract":"Das ausgewählte Archiv mit einer Vorschau des Ziels entpacken.",
        "archiveContainer":"Zurück zum Ordner mit dem geöffneten Archiv wechseln. Bei verschachtelten Archiven zum äußeren Archiv zurückkehren.",
        "archivePassword":"Ein Passwort nur für diese geöffnete Archivsitzung eingeben und den Inhalt neu lesen.",
        "filter":"Die Dateiliste nach Namen oder Dateimuster eingrenzen, zum Beispiel *.pdf.",
        "tree":"Den Ordnerbaum für die aktive Seite ein- oder ausblenden.",
        "details":"Dateien als Tabelle mit Größe, Datum und weiteren Spalten anzeigen.",
        "thumbnails":"Vorschaubilder neben den Dateinamen anzeigen.",
        "icons":"Dateien als Symbolraster anzeigen.",
        "search":"Dateinamen und Inhalte suchen; Suchort und Regeln im Suchfenster festlegen.",
        "compare":"Beide Ordner gegenüberstellen und gewählte Unterschiede vor dem Kopieren prüfen.",
        "fileCompare":"Zwei lokale Dateien als Text oder Binärdaten mit sichtbaren Unterschieden vergleichen. Zwei Dateien auf einer Seite oder je eine pro Seite auswählen.",
        "rename":"Den ausgewählten Namen direkt bearbeiten. Enter übernimmt, Escape verwirft.",
        "batchRename":"Mehrere Dateien mit einer Livevorschau der neuen Namen umbenennen.",
        "quickView":"Die Vorschau neben den Dateifenstern ein- oder ausblenden.",
        "refresh":"Den Inhalt beider Dateifenster neu einlesen.",
        "swap":"Die Inhalte der linken und rechten Seite tauschen.",
        "sameFolder":"Den Ordner der aktiven Seite auch auf der anderen Seite öffnen.",
        "linked":"Ordnerwechsel auf der anderen Seite relativ mitführen. Erneut klicken zum Ausschalten.",
        "orientation":"Zwischen Dateifenstern nebeneinander und untereinander wechseln.",
        "onePane":"Zwischen einer und zwei sichtbaren Seiten wechseln.",
        "trash":"Ausgewählte Dateien nach Rückfrage in den macOS-Papierkorb legen.",
        "preview":"Die ausgewählte Datei mit Quick Look ansehen.",
        "edit":"Die ausgewählte Datei mit TextEdit öffnen.",
        "newFolder":"Im aktiven Ordner einen neuen Unterordner anlegen.",
        "workspaces":"Vollständige lokale Arbeitsbereiche mit Tabs, Filtern, Sperren und Fensteranordnung speichern und wieder öffnen.",
        "tabUnlock":"Die Tabsperre vollständig aufheben.",
        "tabCloseLock":"Das Schließen dieses Tabs verhindern; Ordnerwechsel bleiben in diesem Tab möglich.",
        "tabFixedLock":"Den Ordner dieses Tabs festhalten; neue Ziele über einen neuen Tab öffnen.",
        "tabNewLock":"Den Tab erhalten und Ordnerwechsel in einem neuen Tab öffnen.",
        "tabGroups":"Ordner beider Seiten als lokale Gruppe speichern, verwalten und mit Vorschau öffnen.",
        "lastTab":"Zum zuletzt verwendeten anderen Tab dieser Seite wechseln. Wiederholtes Drücken wechselt zwischen zwei Tabs.",
        "reopenTab":"Den zuletzt geschlossenen verfügbaren lokalen Tab mit Verlauf, Namen und Ansicht wieder öffnen. Der Merkspeicher gilt für diese Sitzung.",
        "copyTabToOther":"Den aktuellen Tab mit Verlauf und Ansicht auf die andere Seite kopieren; der Fokus bleibt hier.",
        "openInNewTab":"Den fokussierten Ordner in einem neuen Tab auf dieser Seite öffnen.",
        "openInOther":"Den fokussierten Ordner auf der anderen Seite öffnen; der Fokus bleibt hier.",
        "openInOtherTab":"Den fokussierten Ordner in einem neuen Tab auf der anderen Seite öffnen; der Fokus bleibt hier.",
        "newTab":"Einen weiteren Tab mit dem aktuellen Ordner öffnen.",
        "closeTab":"Diesen Tab schließen. Gesperrte Tabs bleiben geöffnet.",
        "terminal":"Ein Terminal im Ordner der aktiven Seite öffnen.",
        "operations":"Wartende, laufende und frühere Dateiübertragungen ansehen und mit der Tastatur verwalten.",
        "recovery":"Sicherungen wiederherstellen und vorhandene Teilkopien vor dem Fortsetzen prüfen.",
        "pauseTransfers":"Laufende Dateiübertragung und nachfolgende Aufträge pausieren oder fortsetzen.",
        "stopTransfers":"Laufenden Auftrag abbrechen. Fertige Schritte bleiben erhalten.",
        "customizeToolbar":"Sichtbare Befehle und ihre Reihenfolge in der Werkzeugleiste ändern.",
        "selectPattern":"Muster, RegEx und Datei-/Ordnerwahl mit unverbindlicher Vorschau. Ersetzen, hinzufügen, abwählen oder eingrenzen.",
        "selectFiles":"Alle sichtbaren Dateien auswählen; Ordner bleiben unmarkiert.",
        "deselectAll":"Nur die Markierungen aufheben. Dateien und Ordner bleiben unverändert.",
        "invertFiles":"Nur Dateimarkierungen umkehren; markierte Ordner beibehalten.",
        "sameExtension":"Dateien mit derselben letzten Endung wie das fokussierte Objekt hinzufügen.",
        "deselectExtension":"Dateien mit derselben letzten Endung wie das fokussierte Objekt abwählen.",
        "sameStem":"Sichtbare Dateien mit demselben Namen ohne letzte Endung hinzufügen. Bei Ordnern zählt der ganze Name.",
        "deselectStem":"Sichtbare Einträge mit demselben Stammnamen abwählen.",
        "saveSelection":"Die aktuellen Markierungen für diesen Tab und diesen Ordner in der Sitzung merken.",
        "restoreSelection":"Noch sichtbare Markierungen des gemerkten Ordners wiederherstellen.",
        "saveSelectionFile":"Markierte Adressen in eine lokale Auswahldatei schreiben; keine Dateiinhalte oder Zugangsdaten.",
        "loadSelectionFile":"Passende sichtbare Adressen aus einer Auswahldatei markieren; keine Dateien öffnen.",
        "copyNames":"Ausgewählte Namen in Listenreihenfolge als Text kopieren.",
        "copyStems":"Namen ohne letzte Dateiendung kopieren. Ordnernamen bleiben vollständig.",
        "copyPath":"Ausgewählte Pfade kopieren; ohne Auswahl die aktuelle Ordneradresse.",
        "copyURLs":"Ausgewählte Datei-/Serveradressen als URLs ohne Zugangsdaten kopieren.",
        "copyShellPaths":"Lokale Pfade als einzeln zitierte Argumente für zsh oder andere POSIX-Shells kopieren. Es wird nichts ausgeführt.",
        "copySelectionTable":"Name, Bytes, Datum, Art und Pfad als TSV kopieren. Steuerzeichen werden sichtbar maskiert."
    ]
    static func menuHelp(_ id:String) -> String? { (details[id] ?? (id.hasPrefix("workspace") ? "Gespeicherten Arbeitsbereich dieses Listenplatzes öffnen. Die Belegung kann in den Einstellungen geändert werden." : nil)).map { $0+(shortcut(id).isEmpty ? "" : "\n"+shortcut(id)) } }
    static func shortcut(_ id:String) -> String {
        var value = AppDelegate.resolvedShortcut(id).lowercased()
        if value == "space" { return "Leertaste" }
        for (word,symbol) in [("cmd+","⌘"),("shift+","⇧"),("option+","⌥"),("alt+","⌥"),("control+","⌃"),("ctrl+","⌃"),("left","←"),("right","→"),("up","↑"),("down","↓"),("return","↩"),("tab","⇥")] { value = value.replacingOccurrences(of:word,with:symbol) }
        return value.uppercased()
    }
    static func apply(_ button:ActionButton,id:String,title:String? = nil,context:String? = nil) {
        let name = title ?? AppDelegate.menuDefinitions.flatMap { $0.1 }.first { $0.1 == id }?.0 ?? button.title
        button.setHelp(name,context ?? details[id] ?? "",shortcut:shortcut(id))
    }
}
