# ZweiCommander

ZweiCommander ist ein nativer Dateimanager für macOS mit zwei Dateifenstern, Tabs und Tastaturbedienung. Er wird in Swift und AppKit entwickelt und verwendet Systembibliotheken für Dateivorgänge, Vorschau und Archive.

**Version 0.10.0 ist eine frühe, ausführbare Version.** Neu ist ein vollständiger Arbeitsbereich fürs Mehrfachumbenennen mit Livevorschau, lokalen Profilen, erweiterten Namensregeln, Bilddaten sowie geprüfter Ausführung und Rücknahme im Hintergrund. Der aktuelle Umfang und die Grenzen stehen in [FUNKTIONEN.md](FUNKTIONEN.md), die Prüfung in [PRUEFBERICHT.txt](PRUEFBERICHT.txt).

## Funktionen

- Zwei Dateifenster, Ordnerbaum, Tabs, Schnellfilter und Dateisammlungen.
- Details, Vorschauliste und Symbolraster mit gemeinsamer Auswahl und Sortierung.
- Tabs umordnen und duplizieren, ausgewählten Tab und Ansicht wiederherstellen.
- Ordneransichten mit optionaler Vererbung sowie Ordner- und Programmfavoriten.
- Kopieren und Verschieben mit Vorschau, Warteschlange, Pause, Abbruch und Sicherung beim Ersetzen.
- Lokal gespeicherte Dateiübertragungen und letzter gemeldeter Fortschritt; neue Dateiprüfung nach Neustart.
- Gespeicherte Kopierprofile, Namens-/Größen-/Datumsfilter, reine Ordnerstruktur und Zusammenführen mit Einzelentscheidungen.
- Mehrfachumbenennen mit Livevorschau, Reihenfolge, Profilen, Namensausschnitten, Bilddaten und Versionsprüfung.
- Suche einschließlich Office-XML-Text, Duplikate und Prüfsummen.
- Ordnervergleich und Synchronisieren in einer Richtung ohne Löschen zusätzlicher Zieldateien.
- ZIP-, 7z- und TAR-Archive, Quick Look sowie Text-, Hex- und Binärvorschau.
- Eingebundene Netzwerkvolumes und ein Fenster für FTP-, FTPS- und SFTP-Einzeldateitransfers.
- Anpassbare Tastenkürzel und optionaler [INI-Einstellungsimport](IMPORT.md).

## Bauen und starten

Voraussetzung: macOS und Apple Command Line Tools mit Swift 5.9 oder neuer. Für die Tests wird außerdem Python 3 benötigt. Es werden keine Swift-Pakete aus dem Internet geladen.

```bash
./build.sh
```

Die erzeugte App liegt im Ausgabeordner. Für die Verwendung in den Programme-Ordner kopieren (systemweit oder im Benutzerordner unter ~/Applications) und von dort starten.

Das Buildskript erzeugt eine universelle App für Intel und Apple Silicon; das Buildziel ist macOS 13 oder neuer. `ZWEI_BUILD_DIR` und `ZWEI_OUTPUT_DIR` erlauben andere Build- und Ausgabeordner. `Package.swift` lässt sich auch mit Xcode öffnen.

Das Buildskript entfernt Debug-Verweise auf lokale Baupfade vor der Signierung. Die App wird lokal ad-hoc signiert. Developer-ID-Signierung und Notarisierung sind noch offen. Laufzeitprüfungen wurden auf Intel mit macOS 26.7.1 durchgeführt; Apple Silicon und ältere macOS-Versionen sind bisher nur Buildziele.

## Bedienung

Das aktive Dateifenster ist blau markiert. Das andere Fenster dient als vorgeschlagenes Ziel für Dateiaktionen.

| Taste | Aktion |
|---|---|
| Tab | Dateifenster wechseln |
| Enter / Rückschritt | Öffnen / übergeordneter Ordner |
| F2 / F3 / F4 | Umbenennen / Vorschau / TextEdit |
| F5 / F6 | Kopieren / Verschieben |
| F7 / F8 | Neuer Ordner / Papierkorb |
| Cmd+T / Cmd+W | Tab öffnen / schließen |
| Cmd+Option+Pfeil rechts / links | Nächster / vorheriger Tab |
| Cmd+1 / 2 / 3 | Details / Vorschauliste / Symbole |
| Cmd+L | Pfad bearbeiten |
| Cmd+F / Cmd+Shift+F | Suche / Schnellfilter |
| Cmd+C / X / V | Dateizwischenablage |
| Cmd+Z | Letzten unterstützten Vorgang zurücknehmen |
| Cmd+Shift+M | Mehrfachumbenennen |
| Cmd+Shift+. | Versteckte Dateien |
| Cmd+Shift+J | Warteschlange |

Auf manchen Tastaturen benötigen F-Tasten zusätzlich `fn`. Tastenkürzel können angepasst werden. F1 öffnet die Hilfe.

## Ansichten, Tabs und Favoriten

Über der Dateiliste stehen Darstellung, Sortierspalte und Richtung bereit. Das Symbolraster unterstützt Mehrfachauswahl, Pfeiltasten, Öffnen, Schnellfilter, Vorschau, Dateizwischenablage und Kopieren/Verschieben wie die Liste. Kleine Bildvorschauen werden auf höchstens 144 Pixel verkleinert dekodiert; Links erhalten keine Bildvorschau. Die Anordnung folgt der Sortierung, einzelne Symbole lassen sich nicht frei platzieren.

Tabs lassen sich innerhalb eines Dateifensters ziehen oder über Menübefehle verschieben. Ihr Kontextmenü bietet Duplizieren, Benennen, Sperren und Schließen. **Andere Tabs schließen** erhält gesperrte Tabs. Duplikate übernehmen Pfad, Verlauf und Ansicht, bleiben aber entsperrt. Normale Tabs speichern Reihenfolge, Auswahl und manuelle Darstellung einschließlich Sortierung, Ordnerbaum und Spalten. Sammlungen und temporäre Archive werden nicht als dauerhafte Tabs gespeichert.

**Ansicht → Ordneransicht merken …** speichert die aktuelle Ansicht für einen Ordner, auf Wunsch einschließlich Unterordnern. Die speziellste passende Regel hat Vorrang; gleiche Namensanfänge gelten nicht als Unterordner. Ohne passende Regel gilt die manuelle Ansicht des Tabs. Unter **Gespeicherte Ordneransichten …** lassen sich Regeln entfernen und ihr Geltungsbereich ändern. Regeln beziehen sich auf normalisierte vollständige Pfade; symbolische Ordnerverknüpfungen haben eigene Regeln.

**Gehe zu → Favoriten bearbeiten …** oder der letzte Eintrag im Favoritenmenü verwaltet Ordner und vorhandene macOS-Programme. Name und Ziel werden mit **Übernehmen** gespeichert; Reihenfolge und Entfernen wirken sofort. Bei Programmen kann **Ausgewählte Dateien öffnen** aktiviert werden. Der Aufruf benötigt dann eine Auswahl und übergibt deren Datei-URLs über macOS; es wird kein Shell-Befehl zusammengesetzt. Ohne diese Option startet das Programm.

Favoriten und Ordnerregeln bleiben lokal in den macOS-Benutzereinstellungen. Vorhandene Ordnerfavoriten werden übernommen. Vorgesehen sind höchstens 200 Favoriten, 500 Ordnerregeln und zusammen 2 MiB. Unlesbare oder unbekannte Daten sperren Änderungen und werden nicht automatisch ersetzt. Eine frei programmierbare Werkzeugleiste gehört noch nicht zum Umfang.

## Mehrfachumbenennen

**Cmd+Shift+M** öffnet den Arbeitsbereich. Nur angehakte Zeilen werden verarbeitet und gezählt. Reihenfolge per Pfeilen, Name/Änderungsdatum oder Umkehren einstellen; die Nummerierung folgt dieser Reihenfolge. Jede Änderung verwirft sofort die ausführbare Vorschau. Die neue Vorschau entsteht im Hintergrund. Zeilenfehler und doppelte oder belegte Ziele sperren die gesamte Ausführung.

| Platzhalter | Bedeutung |
|---|---|
| {name}, {full}, {ext} | Name ohne Endung, vollständiger Name, Endung |
| {name:2:5} | Fünf Zeichen ab Position 2; Unicode-Zeichen bleiben zusammen |
| {n} | Zähler mit Start, positivem/negativem Schritt und 1–20 Stellen |
| {parent} | Tatsächlicher Elternordner |
| {date} | Änderungs- oder Erstellungsdatum im gewählten Format |
| {width}, {height} | Bildabmessungen |
| {taken} | EXIF-Originalaufnahmedatum ohne Zeitzonenumrechnung |
| {{ und }} | Wörtliche Klammern |

Ohne {full}/{ext} bleibt die ursprüngliche Endung erhalten. **Endung separat bearbeiten** erlaubt ein eigenes Muster ohne Punkt; leer entfernt die Endung. Im Namensmuster dann {name} verwenden. Ordner erhalten keine zusätzliche Endung. Eingesetzte Dateinamen werden nicht nochmals als Platzhalter gelesen. Suchen/Ersetzen, reguläre Ausdrücke mit Gruppen wie $1 und Schreibweise lassen sich auf Namen oder Endung beschränken. Der Zähler kann je Ordner neu beginnen.

Das Datumsformat verwendet etwa yyyy-MM-dd oder yyyyMMdd_HHmmss; Dateidaten erscheinen lokal oder in UTC. Bilddaten werden ohne Dekodieren der Bildpixel aus regulären Dateien bis 64 MiB gelesen. Links werden dabei nicht verfolgt. Fehlende Abmessungen oder ein fehlendes EXIF-Originalaufnahmedatum erzeugen einen Zeilenfehler; betroffene Dateien lassen sich abwählen.

Bis zu 50 Profile mit zusammen höchstens 1 MiB bleiben in den lokalen Benutzereinstellungen. Profile speichern Regeln, keine Quellpfade oder Dateiauswahl. Sie werden ausdrücklich geladen. Andere offene Fenster übernehmen Änderungen an der Profilliste, behalten jedoch ihre ungespeicherten Felder. Unlesbare Daten sperren Profiländerungen und werden nicht ersetzt.

Umbenennen und **Cmd+Z** laufen als Hintergrundaufträge. Vor Beginn werden alle ausgewählten Quellen, Elternordner und Zielnamen erneut geprüft; vor jeder Namensänderung erfolgen weitere Prüfungen. Die Prüfung erfasst auch Dateiänderungen mit gleicher Größe und zurückgesetztem Änderungsdatum. Zwischenablagen und Ziele werden ausschließlich mit einer Dateisystemoperation angelegt, die bestehende Namen nicht ersetzt. Namenszyklen und reine Änderungen der Schreibweise werden unterstützt.

Bei kontrolliertem Abbruch oder Fehler werden bereits vorbereitete Namen möglichst zurückgesetzt. Blockieren äußere Änderungen diese Wiederherstellung, bleiben eigene Dateien erhalten; **Bericht** nennt die betroffenen Orte, auch bei einem inzwischen verschobenen Elternordner. Es gibt keine exklusive Sperre gegen fremde Dateischreiber. Gemeinsam ausgewählte Ordner und enthaltene Dateien sowie mehrere Namen desselben Dateiobjekts werden abgewiesen und müssen getrennt verarbeitet werden. Höchstens 10.000 Objekte je Auftrag; Umbenennung und Rückgängig werden nach einem abrupten Prozessende nicht rekonstruiert.

## Kopieren und Zusammenführen

F5 öffnet den Auftragsplan. Ziel, Konfliktregel und Auswahl prüfen; unter **Geplante Objekte** erscheinen die enthaltenen Dateien, Ordner und Links. Änderungen an Ziel oder Filtern erfordern einen aktualisierten Plan.

Kopien unterstützen Einschluss- und Ausschlussmuster (`*`, `?`, mehrere Muster mit `;`), reguläre Ausdrücke, ausgeschlossene Unterordner, Rekursion, leere Ordner und reine Ordnerstruktur. Diese Filter gelten pro Auftrag; benannte Kopierprofile können die Regeln wiederverwenden. Verschieben übernimmt die vollständige Auswahl.

**Ordner zusammenführen** erhält vorhandene echte Zielordner und ergänzt ihren Inhalt. Dateikonflikte werden in der Objektliste einzeln entschieden: überspringen, beide behalten oder mit Sicherung ersetzen. Quell- und Zielgröße sowie Änderungsdatum stehen nebeneinander. Der Alternativname wird vorab angezeigt und reserviert. Starten und Vormerken sind gesperrt, solange Entscheidungen fehlen. Typkonflikte zwischen Ordnern und Dateien, Links oder Spezialdateien können nur übersprungen werden.

Ohne Zusammenführen wird jedes Auswahlobjekt als Ganzes veröffentlicht. Beim Ersetzen eines ganzen Ordners entsteht eine Sicherung des bisherigen Zielordners; diese Betriebsart führt dessen Inhalt nicht zusammen.

**Vormerken** hält eine zuvor leere Warteschlange an. **Starten** gibt sie frei. Wartende Aufträge können umgeordnet, entfernt oder als Nächstes gestartet werden. Rückgängig gilt für die laufende Sitzung.

## Aufträge nach einem Neustart

Kopier- und Verschiebeaufträge speichern ihre ausgewählten Quellen, Zielordner, Regeln, Reihenfolge und den zuletzt gemeldeten Fortschritt lokal. Die Ablage liegt unter `~/Library/Application Support/ZweiCommander/Transfers`, mit Zugriff nur für das eigene Benutzerkonto. Sie gehört nicht zum Quellcode und wird von der App nicht hochgeladen. Bis zu 200 Aufträge und 16 MiB sind vorgesehen; pro Auftrag werden höchstens 200 Objektzeilen als Fortschrittsauszug gespeichert. Erledigte Aufträge lassen sich ausblenden, offene werden nicht automatisch verdrängt.

Nach einem Neustart öffnet sich das Auftragsfenster mit **Erneut prüfen**. Offene Aufträge werden nicht automatisch ausgeführt. Die Angaben zeigen den letzten gemeldeten Stand, keine nachträgliche Prüfung des Dateisystems. **Erneut prüfen …** erstellt einen neuen Plan aus den aktuell vorhandenen Quellen und Zielen. Fehlende Quellen werden ausdrücklich genannt und ausgelassen; sie gelten nicht automatisch als erfolgreich verschoben. Fehlen alle Quellen, bleibt der Auftrag zur späteren Prüfung erhalten. Einzelne Konfliktentscheidungen müssen erneut getroffen werden. Erst Starten oder Vormerken ersetzt den alten Auftrag durch den neu geprüften Plan.

Bereits vorhandene Ziele sind wieder Teil der Konfliktprüfung. Für eine schon fertige Datei kann beispielsweise **Überspringen** gewählt werden. Unvollständige Dateien werden neu kopiert; die App setzt nicht an einer gespeicherten Byteposition fort. Nach einem abrupten Prozessende können versteckte unveröffentlichte Kopien zurückbleiben. Sie werden beim Wiederanlauf nicht automatisch entfernt. Rückgängig und Sicherungsverwaltung werden nicht aus dem Journal rekonstruiert.

Mit ausschließlich gespeicherten wartenden Dateiübertragungen kann die App regulär beendet werden. Laufende Vorgänge und Aufträge aus temporären Archivansichten müssen zuvor abgeschlossen, abgebrochen oder entfernt werden. Andere Hintergrundvorgänge, etwa Archive und Remote-Transfers, bleiben auf die Sitzung beschränkt. Eine beschädigte oder extern geänderte Auftragsdatei wird nicht automatisch überschrieben. Ein Speicherfehler während einer Dateiübertragung fordert deren Abbruch an und hält nachfolgende Aufträge an; fertige Schritte bleiben erhalten. Eine zweite App-Instanz kann dieselbe Ablage nicht gleichzeitig beschreiben.

## Kopierprofile und Größe / Datum

Mit **Speichern als …** werden die aktuellen Kopierregeln unter einem Namen gespeichert. Das Profil umfasst Namens-/Unterordnerfilter, Rekursion, leere Ordner, Strukturkopie, Größen-/Datumsgrenzen, die globale Konfliktvorgabe und Zusammenführen. **Speichern** aktualisiert das ausgewählte Profil. Geänderte Felder werden als ungespeichert markiert. Profile lassen sich nach Bestätigung löschen; andere offene Kopierdialoge aktualisieren ihre Auswahl.

Es werden höchstens 50 Profile lokal in den macOS-Benutzereinstellungen gespeichert. Quelle, Ziel, Auswahl und einzelne Konfliktentscheidungen gehören nicht zum Profil. Neue Aufträge beginnen mit eigenen Einstellungen; ein gespeichertes Profil muss ausdrücklich gewählt werden. Nicht lesbare Profildaten sperren das Speichern, damit vorhandene Daten erhalten bleiben.

**Größe / Datum …** öffnet die zusätzlichen Dateifilter:

- Minimale und maximale Dateigröße zählen die Grenze jeweils mit. Leer bedeutet unbeschränkt; ohne Einheit gilt Byte.
- `KB`, `MB`, `GB` und `TB` verwenden 1000er-Schritte; `KiB`, `MiB`, `GiB` und `TiB` verwenden 1024er-Schritte. Beispiel: `1,5 MB` ergibt 1.500.000 Bytes. Punkt oder Komma ist als Dezimalzeichen erlaubt; Tausendertrennzeichen sind nicht vorgesehen.
- Im Modus **Feste Zeitpunkte** zählt **Geändert ab** den Zeitpunkt mit, **Geändert vor** schließt ihn aus. Die Anzeige folgt der aktuellen Zeitzone.
- **Relatives Alter** wählt Dateien anhand ihres Änderungsdatums: **Mindestens so alt** und **Höchstens so alt**. Beide Grenzen zählen mit; ein leeres Feld bleibt unbeschränkt. Beispiel: höchstens 7 Tage für die letzte Woche; mindestens 1 Tag und höchstens 1 Woche für Dateien dazwischen. Künftige Änderungsdaten werden bei aktiven Altersregeln ausgelassen.
- Altersangaben sind ganze Zahlen in Minuten, Stunden, Tagen oder Wochen. Ein Tag entspricht genau 24 Stunden, eine Woche 7 Tagen; Sommerzeit und Kalendermonate ändern die Dauer nicht. Eine Grenze kann bis zu 36.500 Tage betragen.
- Für einen Dateiplan wird eine gemeinsame Bezugszeit festgehalten. Sie steht im Hinweistext der Filterzusammenfassung. Die Auswahl bleibt auch in der Warteschlange auf diesen Zeitpunkt bezogen. **Plan aktualisieren**, das Laden eines Profils und **Erneut prüfen …** nach einem Neustart berechnen sie neu. Profile und Aufträge speichern die Altersregel, keinen festgeschriebenen Zeitpunkt. Feste Zeitpunkte und relatives Alter werden getrennt verwendet.
- Namen, Größe und Datum müssen gemeinsam passen. Aktive Größen- oder Datumsgrenzen lassen symbolische Links aus; deren Ziele werden nicht verfolgt. Ordner folgen weiterhin den Regeln für Rekursion und leere Ordner.
- **Nur Ordnerstruktur** setzt Dateigrößen und Datumsgrenzen aus. Beim Ausschalten kehrt die vorherige Auswahl für leere Ordner zurück. Verschieben unterstützt diese Filter und Profile noch nicht.

Profile und Aufträge mit Altersregeln verwenden die neue Formatversion 2 und benötigen ZweiCommander 0.8 oder neuer. Ältere App-Versionen lehnen diese Daten ab, damit sie Altersregeln nicht unbemerkt weglassen. Bestehende Daten ohne Altersregeln bleiben lesbar.

## Grenzen von Dateivorgängen

- Ersetzen legt das vorherige Ziel unter `.zweicommander-backup-…` im selben Ordner ab. Diese Sicherungen werden nicht automatisch gelöscht.
- Zusammenführen veröffentlicht Dateien einzeln. Bei Abbruch bleiben abgeschlossene Schritte und neu angelegte Ordner erhalten. Noch nicht fertiggestellte neue Ordner können vorläufig private Zugriffsrechte behalten. Der gesamte Auftrag wird nicht zurückgerollt.
- Ein seit der Vorschau geänderter Quellbestand, eine geänderte Zieldatei oder ein ersetzter Zielordner kann den Auftrag abbrechen. Wird ein Zielordner während der Arbeit umbenannt oder ersetzt, kann in seinem bisherigen Objekt eine versteckte Staging-Datei zurückbleiben. Die App entfernt sie nicht über den veränderten Pfad.
- Rückgängig unterstützt unveränderte Einzeldateien und die letzte Mehrfachumbenennung. Angelegte Verzeichnisse werden nicht automatisch entfernt.
- Kopieren misst Dateidaten in Bytes und unterstützt Pause innerhalb einer Datei. Verschieben nutzt die Systemoperation und pausiert an Prüfpunkten.
- Zusammenführen prüft eingehende Zielnamen vorsorglich ohne Groß-/Kleinschreibung. Dadurch werden auch auf einem Dateisystem mit beachteter Schreibweise manche Namenskombinationen abgewiesen.
- Archive erhalten in dieser Version keine Finder-Tags, Resource Forks oder erweiterten Attribute. Entpacken erfolgt in neue Ordner mit Pfad- und Größenprüfung.
- Der Remote-Dialog unterstützt Einzeldateien. Rekursive Übertragung, Keychain-Profile und dauerhaftes Fortsetzen sind noch offen. Ein abgebrochener Upload kann eine unvollständige Remote-Datei hinterlassen.

## Tests

```bash
./scripts/test.sh
python3 scripts/ui-smoke.py --app ../ZweiCommander.app --results /tmp/ZweiCommander-Tests --screenshots /tmp/ZweiCommander-Bilder
python3 scripts/check-public.py
```

Die 159 Dateikern- und Integrationstests verwenden temporäre Dateien. Ein lokaler FTP-Test bindet ausschließlich `127.0.0.1`. Die achtzehn nativen Oberflächendurchläufe verwenden künstliche Verzeichnisbäume und das mitgelieferte künstliche INI-Profil; sie verändern keine persönlichen Benutzereinstellungen. Profil-, Umbenennungs-, Alters- und Arbeitsbereichsprüfungen verwenden eigene, anschließend entfernte Einstellungsbereiche. Weitere Prozesse prüfen Aufträge nach regulärem Beenden, ein abruptes Prozessende während einer Kopie, den erneuten Start mit neuem Plan und beschädigte oder während der Arbeit geänderte Auftragsdaten. Die Journaltests verwenden ausschließlich eine eigene temporäre Ablage. Zwei Prozesse prüfen relative Altersregeln, Profil-/Auftragsspeicherung, erneute Vorschau und Ausführung nach einem Neustart. Zwei weitere prüfen Symbolauswahl und Dateikopie, Tab-Verwaltung, Favoriten, Ordnerregeln und das Laden nach Neustart. Zwei weitere Prozesse prüfen Livevorschau und Profilspeicherung beim Mehrfachumbenennen, tatsächliche Umbenennung und Rückgängig, veränderte Quellen sowie den Abbruch eines wartenden Auftrags. Programmaufrufe werden an der macOS-Aufrufschnittstelle abgefangen und lösen keinen externen Programmstart aus. `--settings /Pfad/Layout.ini` erlaubt eine andere, ausschließlich gelesene Importquelle.

`check-public.py` prüft die im Git-Index enthaltenen Dateien vor einer Veröffentlichung. Erlaubt sind die Projektdateien, Quellcode, Werkzeuge und künstlichen Testdaten. Lokale Protokolle, Buildprodukte und Arbeitsunterlagen gehören nicht ins Repository.

## Projektstruktur

- `Sources/CommanderCore`: Dateisystem, Planung, Suche, Prüfsummen, Vergleich, Archive und Remote-Dienste.
- `Sources/ZweiCommander`: AppKit-Oberfläche, Dialoge, Tastenkürzel und Vorschau.
- `Sources/CFileCopy`: Schnittstelle zu macOS `copyfile` und Fortschrittsrückmeldungen.
- `Sources/CArchive`: ABI-Deklarationen für die in macOS enthaltene libarchive.
- `Tests`: Funktionsprüfungen, künstliche Testdaten und lokaler FTP-Testserver.
- `Resources` und `scripts`: App-Metadaten, Icon-Erzeugung und Buildwerkzeuge.
