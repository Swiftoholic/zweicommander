# Funktionsstand 0.16.0

ZweiCommander ist ein nativer Dateimanager für macOS. „Vorhanden“ bedeutet implementiert; die tatsächlich geprüften Bereiche und verbleibenden Grenzen sind separat aufgeführt.

| Bereich | Stand | Umsetzung / Grenze |
|---|---|---|
| Zwei Dateifenster | Vorhanden | Nebeneinander, übereinander, Einzelansicht, Tausch und gemeinsamer Ordner |
| Navigation | Vorhanden | Eigene Ortsleisten je Seite, Pfadsegmente mit direkter Unterordnerwahl und Kontextmenü, Vorfahrenmenü, Ordner-Drop, Pfadeditor mit asynchronen Vorschlägen, Tab/Enter/Escape, relativen Pfaden, ~ und lokalen file://-Adressen; Sitzungsverlauf und Fehler an der Eingabe; vor/zurück, übergeordnet, Benutzerordner, eingebundene Volumes |
| Tabs | Vorhanden | Neu, schließen, benennen, sperren, duplizieren, Reihenfolge per Ziehen/Menü, Wechsel mit Tastatur; andere ungesperrte Tabs schließen; Reihenfolge, ausgewählten Tab und manuelle Ansicht wiederherstellen |
| Ordnerbaum | Vorhanden | Pro Dateifenster zuschaltbar, Unterordner bei Bedarf geladen |
| Dateilisten | Vorhanden | Mehrfachauswahl mit gesondertem Fokusrahmen, Sortierung, Ordner zuerst, konfigurierbare Spalten; schrittweises Einlesen neuer Ordner, Hintergrundsortierung großer Listen, wiederverwendete Zellen und asynchron geladene Symbole/Vorschaubilder; Auswahl bei Hintergrundaktualisierung erhalten |
| Schnellfilter | Vorhanden | Teiltext, Wildcards, regulärer Ausdruck; sichtbare Treffer-/Gesamtzahl und Aufheben-Aktion; eigene Lade-, Leer-, Fehler- und Keine-Treffer-Zustände |
| Ansichten | Vorhanden | Details, Miniaturbilder und automatisch angeordnetes Symbolraster; gemeinsame Auswahl, Filter, Sortierung, Vorschau, Dateiaktionen und Datei-URLs per Drag-and-drop; keine freie Symbolplatzierung |
| Vorschau | Vorhanden | Quick Look, Text, Hex, Binär, PE-/Mach-O-Dateistruktur; große Dateien werden als markierter Auszug gelesen |
| Eingebettete Vorschau | Vorhanden | Zuschaltbares Quick-Look-Fenster rechts |
| Dateiaktionen | Vorhanden | Kopieren, Verschieben, neue Dateien/Ordner, Papierkorb; F2 bearbeitet einen Namen direkt in Liste/Symbolansicht mit Enter/Escape, Eingabefehlern am Namen, Versionsprüfung, erhaltener Auswahl und Sitzungsrücknahme |
| Konflikte | Vorhanden | Abbrechen, überspringen, beide behalten, ersetzen mit Sicherung |
| Drag-and-drop | Vorhanden | Datei-URLs hinein/heraus; hervorgehobene echte Unterordner und Tabs als Ziele, Statushinweis, verzögertes Öffnen beim Verweilen; Kopieren nach Dialog, Sammlungen erhalten Verweise, Archive schreibgeschützt |
| Zwischenablage | Vorhanden | Kopieren/Ausschneiden/Einfügen und Pfade kopieren |
| Kopier-/Verschiebeplan | Teilweise | Kompakter Grunddialog mit aufklappbaren Optionen, automatische Neuprüfung nach Eingaben und sichtbare Konfliktsperre; Ziel-/Konfliktvorschau, abwählbare Auswahlobjekte und vollständige Dateiliste; Kopien mit Einschluss/Ausschluss, RegEx, ausgeschlossenen Unterordnern, Rekursion, leeren Ordnern und Strukturkopie. Filter gelten pro Auftrag und nur für Kopien. Zusammenführen bestehender echter Zielordner, Metadatenvergleich und Einzelentscheidungen bei Dateikonflikten |
| Kopierprofile und Metadatenfilter | Vorhanden | Bis zu 50 lokale Profile für Regeln und globale Konfliktvorgaben; Dateigröße, feste Änderungszeitpunkte oder relatives Alter in Minuten/Stunden/Tagen/Wochen mit einer gemeinsamen Bezugszeit pro Dateiplan. Keine Pfade oder Einzelentscheidungen; bei aktiven Grenzen werden Links ausgelassen |
| Hintergrundvorgänge | Teilweise | Verwaltungsfenster mit Einzelstatus, Vormerken, Umordnen/Entfernen und als Nächstes starten; Kopien mit Byte-Fortschritt, Pause und Abbruch während der Übertragung. Verschieben nur an System-Prüfpunkten |
| Aufträge nach Neustart | Teilweise | Privates lokales Journal für Kopier-/Verschiebeabsichten, Regeln, Reihenfolge und letzten gemeldeten Fortschritt. Wiederanlauf nur mit neuem Dateiplan und erneuten Einzelentscheidungen. Bis zu 200 Aufträge/16 MiB und 200 Fortschrittszeilen pro Auftrag. Kein Fortsetzen an Bytepositionen, kein dauerhaftes Rückgängig; andere Hintergrundvorgänge bleiben sitzungsbezogen |
| Rückgängig | Teilweise | Unveränderte Einzeldateien und letzte Mehrfachumbenennung in der Sitzung; Umbenennungen mit Versionsprüfung als Hintergrundauftrag; keine automatische Ordner-Rücksetzung |
| Mehrfachumbenennen | Vorhanden | Nativer Arbeitsbereich mit Livevorschau und Zeilenfehlern, Auswahl/Reihenfolge, Teilnamen, getrennten Endungen, Schrittzählern je Ordner, gezieltem RegEx-/Textersetzen und Schreibweise, Datumsformat, 50 lokalen Profilen; Hintergrundausführung/Abbruch/Rücknahme, Schutz vor veränderten Quellen/Zielen, Namenszyklen und reine Schreibweise |
| Dateisuche | Teilweise | Eigenes Fenster mit laufenden Treffern, Abbruch mit Teilergebnissen, Namens-/Ordnerausschlüssen, Rekursion, Größen-/Datums-/Altersregeln, Textfundstellen und Kodierungswahl bis 32 MiB, Office-XML, 50 lokalen Suchprofilen; Öffnen/Vorschau, Markieren im Dateifenster, Kopieren und Sammlung aus Ergebnissen. Keine PDF-Inhalte oder alten DOC-/XLS-Formate |
| Archivsuche | Teilweise | Namen und Größen mit Ausschlüssen, eigenständigen Trefferzeilen und begrenzter Eintragsprüfung; Öffnen des Containers, keine Textsuche oder direkte Dateiaktionen auf Mitgliedspfaden |
| Duplikate | Vorhanden | Gruppierung nach Größe und SHA-256; keine automatische Löschung |
| Prüfsummen | Vorhanden | SHA-256, SHA-512, SHA-1, MD5; Listen erstellen und prüfen |
| Ordnergrößen | Vorhanden | Rekursive Größen-/Dateizählung; tatsächlicher belegter Speicher wird nicht berechnet |
| Vergleich | Vorhanden | Eigener Arbeitsbereich mit SHA-256, Größe/Zeit oder Größe, Toleranz, Namens-/Ordnerfiltern, Gegenüberstellung, Listenfilter und Sortierung, Entscheidungen je Zeile, 50 lokalen Profilen; Links, Spezialdateien, Typ-/Schreibweisenkonflikte und betroffene Nachfahren gesperrt |
| Synchronisation | Teilweise | Gemischte Richtungen pro Datei, Vorschläge nach Seite/Alter/Fehlen, vollständige Planprüfung, neue Elternordner, Byte-Fortschritt, Pause, eigener Abbruch, Sitzungsvormerkung, Sicherungen und Datei-Rücknahme; Prüfungen vor Ausführung und Veröffentlichung. Keine Löschung zusätzlicher Dateien, dauerhafte Zweiwege-Beziehung oder automatische Gesamtrücksetzung |
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
| Kommandozeile | Vorhanden | Untere Eingabezeile mit getrennten Modi für Ordnerpfad und zsh-Befehl, Ausgabefenster und Terminal im aktuellen Ordner; kein gespeicherter Befehlsverlauf |
| Netzwerkvolumes | Vorhanden | macOS-gemountete Volumes, vom System verwaltete Anmeldung |
| FTP / FTPS / SFTP | Teilweise | Eigenes Fenster für Navigation/Einzeldateitransfers; SFTP per Schlüssel/Agent; erweiterte SFTP-Nutzung im Terminal |
| Tastenkürzel / Erscheinungsbild | Teilweise | Sichtbare Hover-Zustände und erklärende Tooltips mit zugewiesenen Tastenkürzeln; konfigurierbare Menübefehle; vollständige Hell-/Dunkel-/Systemfarben, passende Importfarben und Kontrastkorrektur, kompakte/größere Zeilen, Listenschrift, Werkzeugbeschriftungen; vorhandene Werkzeugleistenbefehle ein-/ausblenden und umordnen, Menü bei Platzmangel; keine frei programmierbare Themen-/Toolbar-Engine |
| INI-Einstellungsimport | Teilweise | INI-/SHC-Import unterstützter Farben, Spalten, Sortierung, Tasten, Such-/Archiv-/Zählervorgaben; Rücksetzung; Favoriten und Laufwerkspfade bewusst ausgelassen |
| Dateistruktur-Vorschau | Teilweise | PE-/Mach-O-Köpfe, Architektur, PE-Sektionen und Versionsfelder; keine komplette Ressourcen-/Symboloberfläche |
| Dokumentvorschau | Teilweise | System-Quick-Look und Office-XML-Textextraktion; zusätzliche Formate hängen von Vorschauanbietern ab |
| Windows-Shell / DOS / Registry | Plattformabhängig | Finder, Programme, macOS-Dateisystem und zsh als Entsprechungen |
| Windows-Plug-ins | Offen | Keine Windows-DLL-/WCX-/WLX-Kompatibilität |
| Mobile Geräte | Offen | Gemountete Volumes funktionieren; keine eigene MTP-/iOS-Protokollanbindung |
| Metadaten | Teilweise | Bildabmessungen und EXIF-Originalaufnahmedatum in Umbenennungsmustern; keine ID3-Regeln oder frei programmierbaren Metadaten-Spalten |
| Automatische Ordneransichten | Vorhanden | Darstellung, Sortierung, Ordner zuerst, Baum und Spalten pro Pfad; optional Unterordner, speziellste passende Regel hat Vorrang; Verwaltung zum Entfernen und Ändern des Geltungsbereichs |
| Sicheres Überschreiben | Nicht angeboten | Kein Secure-Wipe-Versprechen für APFS, SSDs oder Snapshots |
| Bildschirmfoto | Offen | Keine eigene Aufnahmefunktion |
| Vollständige Lokalisierung | Offen | Oberfläche deutsch; macOS-Fehlermeldungen folgen der Systemsprache |

## Prüfung

203 Dateikern- und Integrationstests prüfen unter anderem Ordnerregeln, Favoriten und strukturierte Programmaufrufe, das lokale Auftragsjournal, Wiederanlauf ohne automatische Ausführung, Speichergrenzen und Dateirechte, Kopierfortschritt, Pause/Abbruch, Metadaten, Dateifilter, Zusammenführen, Konfliktentscheidungen, Sicherungen, Rückgängig, veränderte Quellen und Ziele, symbolische Verknüpfungen, Umbenennungszyklen, Suche, Hashwerte, Archive, Pfadmanipulationen und einen lokalen FTP-Server.

Am finalen Release-Build wurden alle 676 nativen Oberflächenprüfungen in 29 Durchläufen erfolgreich abgeschlossen, einschließlich der Prüfungen für aktive Adress-, Such- und Vergleichsfenster. Die Serie lief in zwei Gruppen am identischen Build: 24 Durchläufe mit 529 Prüfungen und fünf Durchläufe mit 147 Prüfungen. Geprüft werden direktes Umbenennen und Rückgängig, Versionskonflikte, Fokus/Mehrfachauswahl, hervorgehobene Ordner- und Tab-Ziele, verzögertes Öffnen, echte Kopien nach Vorschau, asynchrone Bilder sowie Laden/Filtern/Aktualisieren mit 3.000 Dateien; außerdem Hover-Zustände und Hilfe, Ordnervervollständigung mit Maus/Tastatur, Unicode, relative und Datei-URLs, Eingabefehler ohne Modal, verworfene alte Vorschläge, Unterordnerwahl und Pfad-Drop-Annahme sowie die getrennte Griffkante und Funktionsleiste mit nativer Mausverfolgung, normale Cursor in beiden Anordnungen, kompakte Transferdialoge, Konfliktsperren, Richtungsanzeigen, Filter- und Leerzustände, Hintergrundaktualisierung, Leistenanpassung samt Neustart sowie vollständige Hell-/Dunkelflächen und Spaltentitel, Kontrastkorrektur, kompakte Navigation, Tabs und Darstellung nach Neustart, Ordnervergleich, gemischte Synchronisation und Vergleichsprofile, Suche und lokale Suchprofile, laufende/abgebrochene Treffer und Aktionen aus Ergebnissen, Mehrfachumbenennen und Profile, Dateifenster und Import, Symbolansicht und Dateikopie, Tabs, Favoriten und Ordnerregeln, Warteschlange, Kopierfilter, Zusammenführen, Kopierprofile, relative Altersregeln sowie gespeicherte und unterbrochene Dateiübertragungen über getrennte App-Prozesse. Sie bedienen die tatsächlichen Auswahlfelder und Konfliktmenüs und vergleichen das Ergebnis mit dem geplanten Bestand. Details stehen in [PRUEFBERICHT.txt](PRUEFBERICHT.txt).

FTPS und SFTP sind bisher nicht Ende zu Ende gegen einen Server geprüft. Wesentlich größere Bestände als die geprüften 3.000 Dateien, langsame oder nicht antwortende Netzwerkfreigaben, Cloud-Platzhalter, ACL-Sonderfälle, externe Datenträger, lange Alltagssitzungen sowie Apple Silicon und ältere macOS-Versionen benötigen weitere Laufzeitprüfungen.

## Weitere Entwicklung

1. Fortsetzen großer Dateien an geprüften Bytepositionen, erweiterte Auftrags-/Sicherungsverwaltung und gefiltertes Verschieben.
2. Remote-Profile mit Keychain, rekursive Übertragungen, Fortsetzen und Remote-Umbenennen/Löschen.
3. Archivbearbeitung, weitere Codec-Prüfungen sowie zusätzliche Metadaten- und EXIF-/ID3-Regeln.
4. Eigene Werkzeugleistenaktionen, weitergehende Ansichtsregeln und weitere Lokalisierung.
5. Geräteprotokolle, weitere Plattformtests und signierte, notarisierte Auslieferung.
