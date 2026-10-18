# ZweiCommander

ZweiCommander ist ein nativer Dateimanager für macOS mit zwei Dateifenstern, Tabs und Tastaturbedienung. Er wird in Swift und AppKit entwickelt und verwendet Systembibliotheken für Dateivorgänge, Vorschau und Archive.

**Version 0.5.0 ist eine frühe, ausführbare Version.** Neu sind das Zusammenführen von Ordnern und Entscheidungen für einzelne Dateikonflikte. Der aktuelle Umfang und die Grenzen stehen in [FUNKTIONEN.md](FUNKTIONEN.md), die Prüfung in [PRUEFBERICHT.txt](PRUEFBERICHT.txt).

## Funktionen

- Zwei Dateifenster, Ordnerbaum, Tabs, Schnellfilter und Dateisammlungen.
- Kopieren und Verschieben mit Vorschau, Warteschlange, Pause, Abbruch und Sicherung beim Ersetzen.
- Kopierfilter, reine Ordnerstruktur und Zusammenführen bestehender Ordner mit Einzelentscheidungen.
- Mehrfachumbenennen, Suche einschließlich Office-XML-Text, Duplikate und Prüfsummen.
- Ordnervergleich und Synchronisieren in einer Richtung ohne Löschen zusätzlicher Zieldateien.
- ZIP-, 7z- und TAR-Archive, Quick Look sowie Text-, Hex- und Binärvorschau.
- Eingebundene Netzwerkvolumes und ein Fenster für FTP-, FTPS- und SFTP-Einzeldateitransfers.
- Anpassbare Tastenkürzel und optionaler [INI-Einstellungsimport](IMPORT.md).

## Bauen und starten

Voraussetzung: macOS und Apple Command Line Tools mit Swift 5.9 oder neuer. Für die Tests wird außerdem Python 3 benötigt. Es werden keine Swift-Pakete aus dem Internet geladen.

```bash
./build.sh
open ../ZweiCommander.app
```

Das Buildskript erzeugt eine universelle App für Intel und Apple Silicon; das Buildziel ist macOS 13 oder neuer. `ZWEI_BUILD_DIR` und `ZWEI_OUTPUT_DIR` erlauben andere Build- und Ausgabeordner. `Package.swift` lässt sich auch mit Xcode öffnen.

Die App wird lokal ad-hoc signiert. Developer-ID-Signierung und Notarisierung sind noch offen. Laufzeitprüfungen wurden auf Intel mit macOS 26.7.1 durchgeführt; Apple Silicon und ältere macOS-Versionen sind bisher nur Buildziele.

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
| Cmd+L | Pfad bearbeiten |
| Cmd+F / Cmd+Shift+F | Suche / Schnellfilter |
| Cmd+C / X / V | Dateizwischenablage |
| Cmd+Z | Letzten unterstützten Vorgang zurücknehmen |
| Cmd+Shift+M | Mehrfachumbenennen |
| Cmd+Shift+. | Versteckte Dateien |
| Cmd+Shift+J | Warteschlange |

Auf manchen Tastaturen benötigen F-Tasten zusätzlich `fn`. Tastenkürzel können angepasst werden. F1 öffnet die Hilfe.

## Kopieren und Zusammenführen

F5 öffnet den Auftragsplan. Ziel, Konfliktregel und Auswahl prüfen; unter **Geplante Objekte** erscheinen die enthaltenen Dateien, Ordner und Links. Änderungen an Ziel oder Filtern erfordern einen aktualisierten Plan.

Kopien unterstützen Einschluss- und Ausschlussmuster (`*`, `?`, mehrere Muster mit `;`), reguläre Ausdrücke, ausgeschlossene Unterordner, Rekursion, leere Ordner und reine Ordnerstruktur. Diese Filter gelten pro Auftrag. Verschieben übernimmt die vollständige Auswahl.

**Ordner zusammenführen** erhält vorhandene echte Zielordner und ergänzt ihren Inhalt. Dateikonflikte werden in der Objektliste einzeln entschieden: überspringen, beide behalten oder mit Sicherung ersetzen. Quell- und Zielgröße sowie Änderungsdatum stehen nebeneinander. Der Alternativname wird vorab angezeigt und reserviert. Starten und Vormerken sind gesperrt, solange Entscheidungen fehlen. Typkonflikte zwischen Ordnern und Dateien, Links oder Spezialdateien können nur übersprungen werden.

Ohne Zusammenführen wird jedes Auswahlobjekt als Ganzes veröffentlicht. Beim Ersetzen eines ganzen Ordners entsteht eine Sicherung des bisherigen Zielordners; diese Betriebsart führt dessen Inhalt nicht zusammen.

**Vormerken** hält eine zuvor leere Warteschlange an. **Starten** gibt sie frei. Wartende Aufträge können umgeordnet, entfernt oder als Nächstes gestartet werden. Die Warteschlange und Rückgängig gelten für die laufende Sitzung.

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

Die Dateikern- und Integrationstests verwenden temporäre Dateien. Ein lokaler FTP-Test bindet ausschließlich `127.0.0.1`. Die vier nativen Oberflächenprüfungen verwenden künstliche Verzeichnisbäume und das mitgelieferte künstliche INI-Profil; sie speichern keine Benutzereinstellungen. `--settings /Pfad/Layout.ini` erlaubt eine andere, ausschließlich gelesene Importquelle.

`check-public.py` prüft die im Git-Index enthaltenen Dateien vor einer Veröffentlichung. Erlaubt sind die Projektdateien, Quellcode, Werkzeuge und künstlichen Testdaten. Lokale Protokolle, Buildprodukte und Arbeitsunterlagen gehören nicht ins Repository.

## Projektstruktur

- `Sources/CommanderCore`: Dateisystem, Planung, Suche, Prüfsummen, Vergleich, Archive und Remote-Dienste.
- `Sources/ZweiCommander`: AppKit-Oberfläche, Dialoge, Tastenkürzel und Vorschau.
- `Sources/CFileCopy`: Schnittstelle zu macOS `copyfile` und Fortschrittsrückmeldungen.
- `Sources/CArchive`: ABI-Deklarationen für die in macOS enthaltene libarchive.
- `Tests`: Funktionsprüfungen, künstliche Testdaten und lokaler FTP-Testserver.
- `Resources` und `scripts`: App-Metadaten, Icon-Erzeugung und Buildwerkzeuge.
