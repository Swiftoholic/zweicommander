# ZweiCommander

ZweiCommander ist ein nativer Dateimanager für macOS mit zwei Dateifenstern, Tabs und Tastaturbedienung. Er wird in Swift und AppKit entwickelt und verwendet Systembibliotheken für Dateivorgänge, Vorschau und Archive.

**Version 0.14.1 ist eine frühe, ausführbare Version.** Der Mittelstreifen hat jetzt eine eigene Funktionsleiste mit kleinen, verteilten Symbolgruppen und Papierkorb am Ende. Nur die schmale Griffkante verändert die Fensteraufteilung und zeigt den Größenänderungszeiger. Der aktuelle Umfang und die Grenzen stehen in [FUNKTIONEN.md](FUNKTIONEN.md), die Prüfung in [PRUEFBERICHT.txt](PRUEFBERICHT.txt).

## Funktionen

- Zwei Dateifenster mit eigenen Ortsleisten, klickbaren Pfaden, Ordnerbaum, Tabs, Schnellfilter und Dateisammlungen.
- Durchgängige Hell-/Dunkel-/Systemdarstellung, kompakte oder größere Zeilen und wählbare Listenschrift.
- Details, Miniaturbilder und Symbolraster mit gemeinsamer Auswahl und Sortierung.
- Tabs umordnen und duplizieren, ausgewählten Tab und Ansicht wiederherstellen.
- Ordneransichten mit optionaler Vererbung sowie Ordner- und Programmfavoriten.
- Kopieren und Verschieben mit kompaktem Dialog, Vorschau, Warteschlange, Pause, Abbruch und Sicherung beim Ersetzen.
- Sichtbare Filter mit Trefferzahl, Aufheben-Aktion und Hinweisen zu leeren oder nicht lesbaren Ordnern.
- Werkzeugleistenbefehle ein-/ausblenden und ordnen; übrige Befehle bei schmalen Fenstern über ein Menü aufrufen.
- Lokal gespeicherte Dateiübertragungen und letzter gemeldeter Fortschritt; neue Dateiprüfung nach Neustart.
- Gespeicherte Kopierprofile, Namens-/Größen-/Datumsfilter, reine Ordnerstruktur und Zusammenführen mit Einzelentscheidungen.
- Mehrfachumbenennen mit Livevorschau, Reihenfolge, Profilen, Namensausschnitten, Bilddaten und Versionsprüfung.
- Dateisuche mit laufenden Ergebnissen, Office-XML-Text, Archivnamen, lokalen Profilen und Dateiaktionen.
- Duplikate und Prüfsummen.
- Ordnervergleich mit lokalen Profilen und Einzelentscheidungen; Synchronisieren in beide Richtungen ohne Löschen zusätzlicher Dateien.
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
| Cmd+1 / 2 / 3 | Details / Miniaturbilder / Symbole |
| Cmd+L | Pfad bearbeiten |
| Cmd+F / Cmd+Shift+F | Suche / Schnellfilter |
| Cmd+C / X / V | Dateizwischenablage |
| Cmd+Z | Letzten unterstützten Vorgang zurücknehmen |
| Cmd+Shift+M | Mehrfachumbenennen |
| Cmd+Shift+. | Versteckte Dateien |
| Cmd+Shift+J | Warteschlange |

Auf manchen Tastaturen benötigen F-Tasten zusätzlich `fn`. Tastenkürzel können angepasst werden. F1 öffnet die Hilfe.

## Erscheinungsbild und kompakte Oberfläche

Oben rechts stehen **System**, **Hell** und **Dunkel** zur Wahl. Hell zeigt beide Dateilisten hell, Dunkel verwendet abgestufte Grautöne. Die aktive Seite ist zusätzlich an der blauen Pfadzeile erkennbar. Such-, Vergleichs-, Umbenennungs-, Text- und Vorschaufenster folgen der Umschaltung. Bilder und von macOS bereitgestellte Dokumentvorschauen behalten ihre eigenen Inhalte; Systemdialoge und die Menüleiste verwenden macOS-Darstellung.

Importierte Hintergründe gelten nur für das passende Erscheinungsbild. Die Gegenpalette bleibt vollständig hell beziehungsweise dunkel. Zu kontrastarme Schrift- und Dateitypfarben werden angepasst. Unter **Einstellungen** lassen sich importierte Farben abschalten, kompakte oder größere Zeilen, die Listenschriftgröße und Beschriftungen unter den Werkzeug-Symbolen wählen. Die Vorgaben bleiben lokal, getrennt von vorhandenen Importprofilen und Tabs. Beschädigte oder unbekannte Darstellungsdaten werden nicht überschrieben.

Jede Seite hat ihre eigene Ortsleiste. Ein Klick auf einen Pfadbestandteil öffnet diesen Ordner; **…** zeigt die vollständige Hierarchie. **Cmd+L** öffnet den Pfadeditor, **Escape** kehrt zur Pfadzeile zurück. Ungesperrte Tabs haben bei mehreren offenen Tabs einen eigenen Schließen-Knopf. Das Schließen eines inaktiven Tabs erhält den ausgewählten Tab. Die mittlere Funktionsleiste bietet Tausch, Vergleich, gleichen Ordner, verknüpftes Navigieren, Anordnung, Einzelansicht und Papierkorb. Die Gruppen verteilen sich über die Leiste; der Papierkorb steht unten beziehungsweise ganz rechts. Zum Ändern der Aufteilung die schmale Kante neben der Funktionsleiste ziehen. Symbole und freier Leistenplatz verwenden den normalen Mauszeiger und verändern die Aufteilung nicht. Bei schmalen Fenstern enthält das Menü am rechten Ende der Werkzeugleiste die nicht mehr passenden Befehle. Favoriten und Erscheinungsbild bleiben rechts sichtbar.

Die untere Eingabezeile startet mit **Pfad**. Enter öffnet einen absoluten oder zum aktiven Ordner relativen Ordnerpfad. Erst der ausdrücklich gewählte Modus **Befehl** führt zsh mit deinen Benutzerrechten im aktiven Ordner aus und öffnet die Textausgabe. Solche Befehle können Dateien verändern. Der Terminal-Knopf öffnet ein interaktives Terminal. Es wird kein Befehlsverlauf gespeichert.

## Kopieren, Verschieben, Filter und Werkzeugleiste

F5 und F6 zeigen die Zielrichtung abhängig von der aktiven Seite und der Fensteranordnung. Ohne Dateiauswahl sind die Knöpfe deaktiviert. Bei einer Dateisammlung als Ziel heißt die Kopieraktion **Zur Sammlung**: Sie fügt Verweise hinzu und erhält die Originaldateien.

Der Übertragungsdialog zeigt zuerst Quelle, Ziel, Konfliktregel und Vorschau. **Weitere Optionen** blendet Kopierprofile, Dateifilter und Ordnerregeln ein. Aktive Regeln bleiben auch bei geschlossenen Optionen sichtbar. Änderungen an Ziel oder Regeln werden nach kurzer Tippause neu geprüft; währenddessen kann der alte Plan nicht gestartet werden. Offene Einzelentscheidungen sowie **Abbrechen bei Konflikt** mit belegten Zielen sperren Kopieren und Vormerken. **Konflikte zeigen** führt zu den betroffenen Objekten. Erweiterte Optionen bleiben in kleinen Fenstern scrollbar.

Ein aktiver Schnellfilter zeigt Trefferzahl und Gesamtzahl der eingelesenen Objekte. **Filter aufheben** entfernt Muster und RegEx-Modus. Leere Ordner, fehlende Treffer, ungültige Ausdrücke und Ladefehler erhalten eigene Hinweise in der Dateifläche. Bei Ladefehlern steht **Erneut versuchen** bereit. Eine Aktualisierung des gleichen Ordners erhält Auswahl und Dateiaktionen.

**Ansicht → Werkzeugleiste anpassen …** oder das Menü am rechten Leistenende öffnet die Anpassung: vorhandene Befehle ein-/ausblenden, Reihenfolge ändern oder den Standard wiederherstellen. Erst **Übernehmen** speichert; Abbrechen erhält die bisherige Leiste. Die Auswahl bleibt lokal und wird nach Neustart geladen. Beschädigte oder unbekannte Daten werden nicht überschrieben. Die Beschriftungen **Miniaturbilder** und **Schnellansicht** unterscheiden Dateiansicht und Vorschau rechts.

## Ansichten, Tabs und Favoriten

Über der Dateiliste stehen Darstellung, Sortierspalte und Richtung bereit. Das Symbolraster unterstützt Mehrfachauswahl, Pfeiltasten, Öffnen, Schnellfilter, Vorschau, Dateizwischenablage und Kopieren/Verschieben wie die Liste. Kleine Bildvorschauen werden auf höchstens 144 Pixel verkleinert dekodiert; Links erhalten keine Bildvorschau. Die Anordnung folgt der Sortierung, einzelne Symbole lassen sich nicht frei platzieren.

Tabs lassen sich innerhalb eines Dateifensters ziehen oder über Menübefehle verschieben. Ihr Kontextmenü bietet Duplizieren, Benennen, Sperren und Schließen. **Andere Tabs schließen** erhält gesperrte Tabs. Duplikate übernehmen Pfad, Verlauf und Ansicht, bleiben aber entsperrt. Normale Tabs speichern Reihenfolge, Auswahl und manuelle Darstellung einschließlich Sortierung, Ordnerbaum und Spalten. Sammlungen und temporäre Archive werden nicht als dauerhafte Tabs gespeichert.

**Ansicht → Ordneransicht merken …** speichert die aktuelle Ansicht für einen Ordner, auf Wunsch einschließlich Unterordnern. Die speziellste passende Regel hat Vorrang; gleiche Namensanfänge gelten nicht als Unterordner. Ohne passende Regel gilt die manuelle Ansicht des Tabs. Unter **Gespeicherte Ordneransichten …** lassen sich Regeln entfernen und ihr Geltungsbereich ändern. Regeln beziehen sich auf normalisierte vollständige Pfade; symbolische Ordnerverknüpfungen haben eigene Regeln.

**Gehe zu → Favoriten bearbeiten …** oder der letzte Eintrag im Favoritenmenü verwaltet Ordner und vorhandene macOS-Programme. Name und Ziel werden mit **Übernehmen** gespeichert; Reihenfolge und Entfernen wirken sofort. Bei Programmen kann **Ausgewählte Dateien öffnen** aktiviert werden. Der Aufruf benötigt dann eine Auswahl und übergibt deren Datei-URLs über macOS; es wird kein Shell-Befehl zusammengesetzt. Ohne diese Option startet das Programm.

Favoriten und Ordnerregeln bleiben lokal in den macOS-Benutzereinstellungen. Vorhandene Ordnerfavoriten werden übernommen. Vorgesehen sind höchstens 200 Favoriten, 500 Ordnerregeln und zusammen 2 MiB. Unlesbare oder unbekannte Daten sperren Änderungen und werden nicht automatisch ersetzt. Eigene Werkzeugleistenaktionen mit frei gewählten Befehlen gehören noch nicht zum Umfang; die vorhandenen Befehle lassen sich einblenden, ausblenden und ordnen.

## Dateisuche

**Cmd+F** öffnet ein eigenes Fenster für den aktuellen Ordner. Mehrere Namensmuster mit Semikolon trennen, beispielsweise *.txt;*.md. Ohne Platzhalter wird ein Namensteil gesucht; alternativ ist ein regulärer Ausdruck möglich. Ausgeschlossene Dateinamen und ganze Unterordner verwenden * und ?. Unterordner, versteckte Einträge sowie Dateien/Ordner sind getrennt wählbar. **Größe und Datum …** bietet die Größen-, Datums- und Altersregeln des Kopierdialogs; die Bezugszeit für relatives Alter wird bei jeder Suche einmal festgelegt.

Treffer erscheinen während der Arbeit. **Abbrechen** behält die bereits gefundenen Ergebnisse. Das Limit beträgt standardmäßig 10.000 und ist von 1 bis 50.000 einstellbar; ein erreichtes Limit wird ausdrücklich als Teilergebnis markiert. Die Ergebnisliste lässt sich nach Name, Pfad und Fundstelle filtern und über die Spalten sortieren. Die Suchregeln bleiben während des Laufs gesperrt. Escape fordert einen Abbruch an. Das Schließen des Suchfensters fordert einen Abbruch an. Suchen warten nicht hinter Dateiübertragungen.

Die Inhaltssuche verwendet wörtlichen Text mit optionaler Groß-/Kleinschreibung und ganzen Wörtern. UTF-8 und UTF-16 mit BOM werden automatisch erkannt; UTF-16 ohne BOM und Windows-1252 sind ausdrücklich wählbar. Reguläre Textdateien sind auf 32 MiB begrenzt; binäre Daten werden ausgelassen. Die Office-Option liest DOCX, XLSX, PPTX und ODT mit höchstens 32 MiB relevanten XML-Daten. Eine Fundstelle erscheint je Datei. Aktive Größengrenzen schließen Ordner aus; rekursive Ordnergrößen werden nicht berechnet. Die Suche öffnet die letzte Pfadkomponente ohne Linkverfolgung und prüft Dateiidentität und Änderungsstände nach dem Lesen. Symbolische Links werden für Inhalte und Unterordner nicht verfolgt. PDF-Inhalte und alte DOC-/XLS-Formate sind noch offen.

**Im Dateifenster** zeigt den Treffer im ursprünglichen Dateifenster und markiert ihn nach dem Laden des Ordners. **Kopieren …** verwendet die Auswahl der Suchliste und öffnet den regulären Dateiplan mit dem gegenüberliegenden Dateifenster als Ziel. Öffnen, Vorschau, Pfade kopieren und mehrere Treffer als Sammlung stehen ebenfalls bereit. Dateivorgänge prüfen die zum Ausführungszeitpunkt vorhandenen Pfade erneut; Suchergebnisse sind keine festgehaltenen Dateiversionen.

Archivsuche durchsucht Namen und Größen, ohne Inhalte zu entpacken; sie wird getrennt von Inhalts- und Datumssuche verwendet. Rekursion, versteckte Einträge und Ausschlüsse gelten auch für Archiveinträge. Pro Archiv werden höchstens 100.000 Einträge geprüft. Archivtreffer zeigen Container und Mitgliedspfad und können das Archiv öffnen. Sie lassen sich nicht direkt als normale Dateien kopieren oder als Dateisammlung übernehmen. Beschädigte oder während der Prüfung veränderte Archive erzeugen Hinweise. Insgesamt werden höchstens 200 Hinweistexte gespeichert; der Gesamtzähler bleibt erhalten.

**Speichern als …** legt eines von bis zu 50 lokalen Suchprofilen an (zusammen höchstens 1 MiB). Profile speichern Suchregeln, weder Suchordner noch Trefferlisten. Laden, Aktualisieren und Löschen verändern keine offenen ungespeicherten Suchregeln anderer Fenster. Beschädigte oder unbekannte Profildaten werden nicht automatisch ersetzt. Ergebnisse bleiben nur in der Sitzung.

## Ordnervergleich und Synchronisation

**Cmd+Shift+D** vergleicht die beiden normalen Dateifenster. Die Ordner müssen verschieden sein und dürfen nicht ineinander liegen. Die Prüfung verwendet SHA-256-Inhalte, Dateigröße und Änderungszeit oder nur Dateigröße. Bei Größen-/Zeitvergleich gilt eine Zeittoleranz von 0 bis 3600 Sekunden einschließlich der Grenze. Eine Inhaltsprüfung betrachtet gleiche Bytes unabhängig vom Datum als gleich.

Namensmuster und Ausschlüsse verwenden * und ?; mehrere Muster mit Semikolon trennen. Ordnerausschlüsse schneiden ganze Zweige ab und gelten auch in der flachen Ansicht. Unterordner und versteckte Einträge sind wählbar. Ordner bleiben für die Struktur sichtbar. Arbeits- und Sicherungsnamen mit .zweicommander- werden immer ausgelassen. Höchstens 50.000 Einträge je Seite und 50.000 gemeinsame Zeilen werden erfasst; bei größeren Beständen kleinere Wurzeln oder mehr Ordnerausschlüsse wählen. Fehler und Abbruch geben keine teilweise ausführbare Vorschau frei.

Die Gegenüberstellung zeigt Zustand, Größe und Änderungsdatum beider Seiten. Pfad-/Statusfilter und Spaltensortierung verändern keine Entscheidungen. Ein Zeilenmenü wählt **Links → Rechts**, **Rechts → Links** oder **Auslassen**. Die Auswahlknöpfe ändern mehrere Zeilen. Vier Vorschläge stehen bereit: eine Richtung, neuere/fehlende Dateien in beide Richtungen oder ausschließlich fehlende Dateien. Unterschiede mit Zeitstempeln innerhalb der Toleranz bleiben beim Vorschlag für neuere Dateien offen und benötigen eine ausdrückliche Richtung oder Auslassen. Gleiche Dateien bleiben unberührt. Links, Spezialdateien, Typ-/Schreibweisenkonflikte und betroffene Nachfahren werden gesperrt; andere Zeilen können trotzdem synchronisiert werden. Vorschau und Markierung im passenden Dateifenster verwenden die jeweilige linke/rechte Quelle.

**Plan prüfen …** zeigt alle konkreten Schritte einschließlich benötigter Elternordner, neuer Dateien und Ersetzungen mit Sicherung. Übertragen werden die aufgeführten Dateien; keine nicht aufgeführten Inhalte eines Ordners. Neue Ordner erhalten die POSIX-Rechte der Quelle, keine rekursive ACL- oder Ordnerdatumsübernahme. Zusätzliche Dateien werden nicht gelöscht. Erst **Starten** oder **Vormerken** gibt den Plan als Hintergrundauftrag frei. Byte-Fortschritt, Pause und Abbruch stehen in der Warteschlange bereit. Das Vergleichsfenster kann seinen eigenen Auftrag abbrechen. Vorgemerkte Synchronisationen gelten für die Sitzung; sie werden nicht ins dauerhafte Übertragungsjournal aufgenommen und müssen vor dem Beenden ausgeführt oder entfernt werden.

Alle gewählten Quellen und Ziele werden vor der ersten Änderung erneut geprüft. Danach folgen Prüfungen pro Schritt und vor Veröffentlichung. Kopien verwenden geöffnete reguläre Quelldateien und geöffnete Zielordner; die letzte Pfadkomponente und die Ordnerkette werden nicht durch symbolische Links ersetzt. Vorhandene Ziele werden vor Veröffentlichung unter einem versteckten Sicherungsnamen erhalten. Zwischenkopien und Sicherungen werden ohne Überschreiben veröffentlicht. Externe Änderungen können den Lauf anhalten; fertige Schritte bleiben erhalten. Es gibt keine automatische Gesamtrücksetzung, Löschspiegelung oder gespeicherte Zweiwege-Beziehung. Rückgängig verwendet die bestehende Sitzungsfunktion für Dateien; neu angelegte Ordner bleiben erhalten. Nach Ausführung oder Fehler ist ein neuer Vergleich erforderlich.

Bis zu 50 lokale Vergleichsprofile (zusammen höchstens 1 MiB) speichern Prüfung, Toleranz, Namens-/Ordnerfilter, Rekursion, versteckte Einträge und Vorschlagsart. Wurzeln und Einzelentscheidungen bleiben ungespeichert. Profile werden ausdrücklich geladen. Andere offene Fenster behalten ihre ungespeicherten Regeln; beschädigte oder unbekannte Daten werden nicht automatisch ersetzt.

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

Die 200 Dateikern- und Integrationstests verwenden temporäre Dateien. Ein lokaler FTP-Test bindet ausschließlich `127.0.0.1`. Die zweiundzwanzig nativen Oberflächendurchläufe verwenden künstliche Verzeichnisbäume und das mitgelieferte künstliche INI-Profil; sie verändern keine persönlichen Benutzereinstellungen. Vergleichs-, Such-, Profil-, Umbenennungs-, Alters- und Arbeitsbereichsprüfungen verwenden eigene, anschließend entfernte Einstellungsbereiche. Weitere Prozesse prüfen Aufträge nach regulärem Beenden, ein abruptes Prozessende während einer Kopie, den erneuten Start mit neuem Plan und beschädigte oder während der Arbeit geänderte Auftragsdaten. Die Journaltests verwenden ausschließlich eine eigene temporäre Ablage. Zwei Prozesse prüfen relative Altersregeln, Profil-/Auftragsspeicherung, erneute Vorschau und Ausführung nach einem Neustart. Zwei weitere prüfen Symbolauswahl und Dateikopie, Tab-Verwaltung, Favoriten, Ordnerregeln und das Laden nach Neustart. Zwei weitere Prozesse prüfen Livevorschau und Profilspeicherung beim Mehrfachumbenennen, tatsächliche Umbenennung und Rückgängig, veränderte Quellen sowie den Abbruch eines wartenden Auftrags. Zwei Suchprozesse prüfen Profile nach Neustart, laufende Treffer und Teilabbruch, echte Dateikopie aus Suchauswahl, Markierung im Dateifenster, Sammlungen, Office-Text, Archivnamen und beschädigte Profildaten. Zwei Vergleichsprozesse prüfen Gegenüberstellung und Profile nach Neustart, Einzelentscheidungen, echte Ausführung in beide Richtungen, Warteschlange und eigenen Abbruch, Sitzungsrücknahme, veraltete Pläne und beschädigte Profile. Programmaufrufe werden an der macOS-Aufrufschnittstelle abgefangen und lösen keinen externen Programmstart aus. `--settings /Pfad/Layout.ini` erlaubt eine andere, ausschließlich gelesene Importquelle.

`check-public.py` prüft die im Git-Index enthaltenen Dateien vor einer Veröffentlichung. Erlaubt sind die Projektdateien, Quellcode, Werkzeuge und künstlichen Testdaten. Lokale Protokolle, Buildprodukte und Arbeitsunterlagen gehören nicht ins Repository.

## Projektstruktur

- `Sources/CommanderCore`: Dateisystem, Planung, Suche, Prüfsummen, Vergleich, Archive und Remote-Dienste.
- `Sources/ZweiCommander`: AppKit-Oberfläche, Dialoge, Tastenkürzel und Vorschau.
- `Sources/CFileCopy`: Schnittstelle zu macOS `copyfile` und Fortschrittsrückmeldungen.
- `Sources/CArchive`: ABI-Deklarationen für die in macOS enthaltene libarchive.
- `Tests`: Funktionsprüfungen, künstliche Testdaten und lokaler FTP-Testserver.
- `Resources` und `scripts`: App-Metadaten, Icon-Erzeugung und Buildwerkzeuge.
