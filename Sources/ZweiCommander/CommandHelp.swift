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
        "filter":"Die Dateiliste nach Namen oder Dateimuster eingrenzen, zum Beispiel *.pdf.",
        "tree":"Den Ordnerbaum für die aktive Seite ein- oder ausblenden.",
        "details":"Dateien als Tabelle mit Größe, Datum und weiteren Spalten anzeigen.",
        "thumbnails":"Vorschaubilder neben den Dateinamen anzeigen.",
        "icons":"Dateien als Symbolraster anzeigen.",
        "search":"Dateinamen und Inhalte suchen; Suchort und Regeln im Suchfenster festlegen.",
        "compare":"Beide Ordner gegenüberstellen und gewählte Unterschiede vor dem Kopieren prüfen.",
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
        "newTab":"Einen weiteren Tab mit dem aktuellen Ordner öffnen.",
        "closeTab":"Diesen Tab schließen. Gesperrte Tabs bleiben geöffnet.",
        "terminal":"Ein Terminal im Ordner der aktiven Seite öffnen.",
        "customizeToolbar":"Sichtbare Befehle und ihre Reihenfolge in der Werkzeugleiste ändern."
    ]
    static func shortcut(_ id:String) -> String {
        let fallback = AppDelegate.menuDefinitions.flatMap { $0.1 }.first { $0.1 == id }?.2 ?? ""
        var value = (Preferences.state.shortcuts[id] ?? fallback).lowercased()
        if value == "space" { return "Leertaste" }
        for (word,symbol) in [("cmd+","⌘"),("shift+","⇧"),("option+","⌥"),("alt+","⌥"),("control+","⌃"),("ctrl+","⌃"),("left","←"),("right","→"),("up","↑"),("down","↓")] { value = value.replacingOccurrences(of:word,with:symbol) }
        return value.uppercased()
    }
    static func apply(_ button:ActionButton,id:String,title:String? = nil,context:String? = nil) {
        let name = title ?? AppDelegate.menuDefinitions.flatMap { $0.1 }.first { $0.1 == id }?.0 ?? button.title
        button.setHelp(name,context ?? details[id] ?? "",shortcut:shortcut(id))
    }
}
