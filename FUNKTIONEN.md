# Funktionsstand 0.9.0

ZweiCommander ist ein nativer Dateimanager für macOS. „Vorhanden“ bedeutet implementiert; die tatsächlich geprüften Bereiche und verbleibenden Grenzen sind separat aufgeführt.

| Bereich | Stand | Umsetzung / Grenze |
|---|---|---|
| Zwei Dateifenster | Vorhanden | Nebeneinander, übereinander, Einzelansicht, Tausch und gemeinsamer Ordner |
| Navigation | Vorhanden | Pfadfeld, vor/zurück, übergeordnet, Benutzerordner, eingebundene Volumes |
| Tabs | Vorhanden | Neu, schließen, benennen, sperren, duplizieren, Reihenfolge per Ziehen/Menü, Wechsel mit Tastatur; andere ungesperrte Tabs schließen; Reihenfolge, ausgewählten Tab und manuelle Ansicht wiederherstellen |
| Ordnerbaum | Vorhanden | Pro Dateifenster zuschaltbar, Unterordner bei Bedarf geladen |
| Dateilisten | Vorhanden | Mehrfachauswahl, Sortierung, Ordner zuerst, konfigurierbare sichtbare Spalten |
| Schnellfilter | Vorhanden | Teiltext, Wildcards, regulärer Ausdruck |
| Ansichten | Vorhanden | Details, Vorschauliste und automatisch angeordnetes Symbolraster; gemeinsame Auswahl, Filter, Sortierung, Vorschau, Dateiaktionen und Datei-URLs per Drag-and-drop; keine freie Symbolplatzierung |
| Vorschau | Vorhanden | Quick Look, Text, Hex, Binär, PE-/Mach-O-Dateistruktur; große Dateien werden als markierter Auszug gelesen |
| Eingebettete Vorschau | Vorhanden | Zuschaltbares Quick-Look-Fenster rechts |
| Dateiaktionen | Vorhanden | Kopieren, Verschieben, neue Dateien/Ordner, Umbenennen, Papierkorb |
| Konflikte | Vorhanden | Abbrechen, überspringen, beide behalten, ersetzen mit Sicherung |
| Drag-and-drop | Vorhanden | Datei-URLs hinein/heraus; interner Drop kopiert nach Dialog |
| Zwischenablage | Vorhanden | Kopieren/Ausschneiden/Einfügen und Pfade kopieren |
| Kopier-/Verschiebeplan | Teilweise | Ziel-/Konfliktvorschau, abwählbare Auswahlobjekte und vollständige Dateiliste; Kopien mit Einschluss/Ausschluss, RegEx, ausgeschlossenen Unterordnern, Rekursion, leeren Ordnern und Strukturkopie. Filter gelten pro Auftrag und nur für Kopien. Zusammenführen bestehender echter Zielordner, Metadatenvergleich und Einzelentscheidungen bei Dateikonflikten |
| Kopierprofile und Metadatenfilter | Vorhanden | Bis zu 50 lokale Profile für Regeln und globale Konfliktvorgaben; Dateigröße, feste Änderungszeitpunkte oder relatives Alter in Minuten/Stunden/Tagen/Wochen mit einer gemeinsamen Bezugszeit pro Dateiplan. Keine Pfade oder Einzelentscheidungen; bei aktiven Grenzen werden Links ausgelassen |
| Hintergrundvorgänge | Teilweise | Verwaltungsfenster mit Einzelstatus, Vormerken, Umordnen/Entfernen und als Nächstes starten; Kopien mit Byte-Fortschritt, Pause und Abbruch während der Übertragung. Verschieben nur an System-Prüfpunkten |
| Aufträge nach Neustart | Teilweise | Privates lokales Journal für Kopier-/Verschiebeabsichten, Regeln, Reihenfolge und letzten gemeldeten Fortschritt. Wiederanlauf nur mit neuem Dateiplan und erneuten Einzelentscheidungen. Bis zu 200 Aufträge/16 MiB und 200 Fortschrittszeilen pro Auftrag. Kein Fortsetzen an Bytepositionen, kein dauerhaftes Rückgängig; andere Hintergrundvorgänge bleiben sitzungsbezogen |
| Rückgängig | Teilweise | Unveränderte Einzeldateien und letzte Mehrfachumbenennung in der Sitzung; keine automatische Ordner-Rücksetzung |
| Mehrfachumbenennen | Vorhanden | Muster, Zähler, Datum, RegEx, Ersetzen, Schreibweise, Vorschau, Konfliktprüfung, zyklische Namenswechsel |
| Dateisuche | Teilweise | Rekursiv, Namen, Text bis 32 MB, Office-XML aus DOCX/XLSX/PPTX/ODT, Größenbereich, Alter und versteckte Dateien; keine PDF-Inhaltsextraktion oder alten DOC-/XLS-Formate |
| Archivsuche | Teilweise | Dateinamen im Archiv; keine Textsuche innerhalb der Archive |
| Duplikate | Vorhanden | Gruppierung nach Größe und SHA-256; keine automatische Löschung |
| Prüfsummen | Vorhanden | SHA-256, SHA-512, SHA-1, MD5; Listen erstellen und prüfen |
| Ordnergrößen | Vorhanden | Rekursive Größen-/Dateizählung; tatsächlicher belegter Speicher wird nicht berechnet |
| Vergleich | Vorhanden | Rekursiv; Inhalte oder Größe/Zeit; Unterschiede und Typkonflikte |
| Synchronisation | Teilweise | Links→rechts oder rechts→links, Vorschau, Änderungen seit Vorschau erkennen; keine Löschspiegelung/automatische Konfliktzusammenführung |
| Archive schreiben | Teilweise | ZIP, 7z und TAR-GZip; ZIP-/7z-Kompressionsstufe aus Import; keine Verschlüsselung, Links, Resource Forks oder erweiterten Metadaten |
| Archive lesen | Teilweise | macOS-libarchive; ZIP/TAR/7z geprüft, RAR je nach System-Codec noch nicht mit Formatvarianten geprüft; Passwortfeld beim Entpacken |
| Verschachtelte Archive | Vorhanden | Temporäre schreibgeschützte Ansichten; neu entpacken beim Öffnen |
| Rechte / Datum | Vorhanden | Ausgewählte Objekte, POSIX-Rechte und Änderungsdatum; keine rekursive ACL-Bearbeitung |
| Dateisammlungen | Vorhanden | Leer oder aus Auswahl/Suchergebnis, Verweise per Drop/Kopieren hinzufügen, entfernen ohne Löschen, speichern/laden |
| Flache Ansicht | Vorhanden | Unterordner als gemeinsame Liste |
| Verknüpftes Navigieren | Teilweise | Gleiche Unterordner-/Elternschritte auf beiden Seiten |
| Favoriten | Teilweise | Lokale Ordner- und Programmfavoriten mit Namen, Ziel, Reihenfolge und Entfernen; Programme starten oder ausgewählte Datei-URLs öffnen; noch keine frei programmierbare Werkzeugleiste |
| Teilen / Zusammenfügen | Vorhanden | Eigene Teileliste mit SHA-256 je Teil; keine fremden Split-Formate |
| Export | Vorhanden | Aktuelle Dateiliste als TSV |
| Kommandozeile | Vorhanden | zsh-Befehl mit Ausgabefenster und Terminal im aktuellen Ordner |
| Netzwerkvolumes | Vorhanden | macOS-gemountete Volumes, vom System verwaltete Anmeldung |
| FTP / FTPS / SFTP | Teilweise | Eigenes Fenster für Navigation/Einzeldateitransfers; SFTP per Schlüssel/Agent; erweiterte SFTP-Nutzung im Terminal |
| Tastenkürzel / Erscheinungsbild | Teilweise | Konfigurierbare Menübefehle, Hell/Dunkel/System; keine vollständige Themen-/Toolbar-Engine |
| INI-Einstellungsimport | Teilweise | INI-/SHC-Import unterstützter Farben, Spalten, Sortierung, Tasten, Such-/Archiv-/Zählervorgaben; Rücksetzung; Favoriten und Laufwerkspfade bewusst ausgelassen |
| Dateistruktur-Vorschau | Teilweise | PE-/Mach-O-Köpfe, Architektur, PE-Sektionen und Versionsfelder; keine komplette Ressourcen-/Symboloberfläche |
| Dokumentvorschau | Teilweise | System-Quick-Look und Office-XML-Textextraktion; zusätzliche Formate hängen von Vorschauanbietern ab |
| Windows-Shell / DOS / Registry | Plattformabhängig | Finder, Programme, macOS-Dateisystem und zsh als Entsprechungen |
| Windows-Plug-ins | Offen | Keine Windows-DLL-/WCX-/WLX-Kompatibilität |
| Mobile Geräte | Offen | Gemountete Volumes funktionieren; keine eigene MTP-/iOS-Protokollanbindung |
| Metadaten-Plug-ins | Offen | Keine EXIF-/ID3-gesteuerte Umbenennung oder frei programmierbare Spalten |
| Automatische Ordneransichten | Vorhanden | Darstellung, Sortierung, Ordner zuerst, Baum und Spalten pro Pfad; optional Unterordner, speziellste passende Regel hat Vorrang; Verwaltung zum Entfernen und Ändern des Geltungsbereichs |
| Sicheres Überschreiben | Nicht angeboten | Kein Secure-Wipe-Versprechen für APFS, SSDs oder Snapshots |
| Bildschirmfoto | Offen | Keine eigene Aufnahmefunktion |
| Vollständige Lokalisierung | Offen | Oberfläche deutsch; macOS-Fehlermeldungen folgen der Systemsprache |

## Prüfung

137 Dateikern- und Integrationstests prüfen unter anderem Ordnerregeln, Favoriten und strukturierte Programmaufrufe, das lokale Auftragsjournal, Wiederanlauf ohne automatische Ausführung, Speichergrenzen und Dateirechte, Kopierfortschritt, Pause/Abbruch, Metadaten, Dateifilter, Zusammenführen, Konfliktentscheidungen, Sicherungen, Rückgängig, veränderte Quellen und Ziele, symbolische Verknüpfungen, Umbenennungszyklen, Suche, Hashwerte, Archive, Pfadmanipulationen und einen lokalen FTP-Server.

Die sechzehn nativen Oberflächendurchläufe mit 277 Prüfungen kontrollieren Dateifenster und Import, Symbolansicht und Dateikopie, Tabs, Favoriten und Ordnerregeln, Warteschlange, Kopierfilter, Zusammenführen, Kopierprofile, relative Altersregeln sowie gespeicherte und unterbrochene Dateiübertragungen über getrennte App-Prozesse. Sie bedienen die tatsächlichen Auswahlfelder und Konfliktmenüs und vergleichen das Ergebnis mit dem geplanten Bestand. Details stehen in [PRUEFBERICHT.txt](PRUEFBERICHT.txt).

FTPS und SFTP sind bisher nicht Ende zu Ende gegen einen Server geprüft. Große Bestände, Cloud-Platzhalter, ACL-Sonderfälle, externe Datenträger, lange Alltagssitzungen sowie Apple Silicon und ältere macOS-Versionen benötigen weitere Laufzeitprüfungen.

## Weitere Entwicklung

1. Fortsetzen großer Dateien an geprüften Bytepositionen, erweiterte Auftrags-/Sicherungsverwaltung und gefiltertes Verschieben.
2. Remote-Profile mit Keychain, rekursive Übertragungen, Fortsetzen und Remote-Umbenennen/Löschen.
3. Archivbearbeitung, weitere Codec-Prüfungen sowie zusätzliche Metadaten- und EXIF-/ID3-Regeln.
4. Frei belegbare Werkzeugleiste, weitergehende Ansichtsregeln und weitere Lokalisierung.
5. Geräteprotokolle, weitere Plattformtests und signierte, notarisierte Auslieferung.
