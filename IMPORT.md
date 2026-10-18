# INI-Einstellungsimport

Im Hilfe-Menü kann eine unterstützte INI-Hauptdatei ausgewählt werden. Zugehörige Dateien mit demselben Basisnamen und den Endungen `.shc`, `.find.ini`, `.mren.ini` und `.wcx.ini` werden aus demselben Ordner gelesen. Wird ein Ordner ausgewählt, muss er genau eine eindeutig benannte Hauptdatei enthalten; andernfalls die Datei direkt auswählen.

Der Import berücksichtigt unterstützte Spalten, Sortierung, Farben, versteckte Dateien, Fensteranordnung und Tastenkürzel. Hinzu kommen Vorgaben für Office-Textsuche, Umbenennungszähler und Archivkompression. Zeichenbreiten und Windows-Farben werden in native Darstellungswerte umgerechnet.

Vor dem Übernehmen erscheint ein Bericht. Bisherige Einstellungen bleiben für die Wiederherstellung im Hilfe-Menü gespeichert. Frühere Profildaten werden beim Laden anhand ihres Schemas übernommen.

Favoriten, Laufwerkspfade, FTP-/Cloud-Konten, Zugangsdaten und externe Befehle werden nicht in das importierte Profil übernommen. Programme und Plug-in-Binärdateien werden nicht ausgeführt. Erkannte Plug-in-Einträge dienen nur als Hinweise auf konfigurierte Dateiformate; Quick Look, Office-Text und die Binärstruktur-Vorschau arbeiten nativ.

Das Repository enthält ausschließlich künstliche Import-Testdaten. Die Zeichenfolge `SHOULD_NEVER_APPEAR` ist ein absichtlich eingefügter Testwert: Die Tests prüfen, dass solche fremden Inhalte nicht im exportierten Profil landen.
