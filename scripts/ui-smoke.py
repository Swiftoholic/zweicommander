#!/usr/bin/env python3
"""Native UI checks using isolated fixtures; never saves the user's app settings."""
import argparse
import shutil
import os
from pathlib import Path
import subprocess
import struct
import tempfile
import time
import uuid
import zlib


def write(root, name, contents):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")


def preview_png(color):
    """A synthetic landscape-shaped image to exercise real thumbnail decoding."""
    width, height = 288, 168
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = bytearray()
    for y in range(height):
        pixels.append(0)
        for x in range(width):
            shade = 0.65 + 0.35 * ((x + y) / (width + height))
            pixels.extend(int(component * shade) for component in color)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(pixels))) + chunk(b"IEND", b""))


def fixtures(base):
    main, operations, filters, merge, profiles, journal, damaged, age, workspace, rename, search, compare = [base / name for name in ("main", "operations", "filters", "merge", "profiles", "journal", "damaged", "age", "workspace", "rename", "search", "compare")]
    for name in ("Archiv", "Dokumente", "Fotos", "Projekte"):
        (main / "Links" / name).mkdir(parents=True)
    for name, text in (("Besprechung.txt", "Besprechung\n"), ("Grüße aus Wien.txt", "Hallo Wien\n"),
                       ("Rechnung 2026.txt", "Rechnung\n"), ("Planung.csv", "Name;Status\nTest;offen\n"),
                       ("Willkommen.md", "# Willkommen\n")):
        write(main, "Links/" + name, text)
    for name in ("Freigabe", "Sicherung"):
        (main / "Rechts" / name).mkdir(parents=True)
    write(main, "Rechts/Lesen.txt", "Beispieldatei\n")
    for name in ("Links", "Rechts", "Sicherung", "Entwurf"):
        (operations / name).mkdir(parents=True)
    (operations / "Links/Testdaten.bin").write_bytes(b"c" * (32 * 1024 * 1024))
    write(operations, "Links/Projektinfo.txt", "Native Kopierprüfung mit Dateiplan.\n")
    write(operations, "Links/Nicht kopieren.txt", "Diese Datei wird abgewählt.\n")
    for name in ("Rechts", "Sicherung", "Links/Projekt/Leer"):
        (filters / name).mkdir(parents=True)
    for name, text in (("Projekt/Notizen.md", "# Projekt\n"), ("Projekt/Quellen/Hallo.txt", "Hallo Wien\n"),
                       ("Projekt/Quellen/Tief/Notiz.MD", "Tiefe Notiz\n"), ("Projekt/Quellen/datei.bin", "auslassen\n"),
                       ("Projekt/Nicht übernehmen.txt", "bleibt\n"), ("Projekt/.git/geheim.txt", "synthetisch\n"),
                       ("Projekt/Cache42/bleibt.md", "Cache bleibt\n"), ("Privat/privat.txt", "außerhalb der Auswahl\n"),
                       ("README.md", "# Anleitung\n"), ("Weglassen.tmp", "nicht kopieren\n")):
        write(filters, "Links/" + name, text)
    (filters / "Links/Projekt/Alias.txt").symlink_to("../Privat")
    for name in ("Rechts", "Sicherung", "Links/Projekt/LeererOrdner"):
        (merge / name).mkdir(parents=True)
    for name, text in (("neu.txt", "neu\n"), ("ersetzen.txt", "neu ersetzen\n"),
                       ("beide.txt", "neu beide\n"), ("lassen.txt", "neu lassen\n"),
                       ("Unterordner/neu.md", "# neu\n"), ("Typkonflikt/gesperrt.txt", "gesperrt\n"),
                       ("ausgelassen.bin", "auslassen\n")):
        write(merge, "Links/Projekt/" + name, text)
        os.utime(merge / "Links/Projekt" / name, (1700000000, 1700000000))
    for name, text in (("ersetzen.txt", "alt ersetzen\n"), ("beide.txt", "alt beide\n"),
                       ("lassen.txt", "alt lassen\n"), ("nur-im-Ziel.txt", "extra\n")):
        write(merge, "Rechts/Projekt/" + name, text)
        os.utime(merge / "Rechts/Projekt" / name, (946684800, 946684800))
    write(merge, "Privat/bestehend.txt", "privat\n")
    (merge / "Rechts/Projekt/Typkonflikt").symlink_to(merge / "Privat")
    for name in ("Rechts", "Sicherung", "Links/Projekt/Leer"):
        (profiles / name).mkdir(parents=True)
    for name, text, second in (("mittel.txt", "abcd", 60), ("klein.txt", "x", 90),
                               ("gross.txt", "123456789012", 90), ("alt.txt", "altalt", 0),
                               ("ende.txt", "ende!!", 180), ("Unterordner/neu.md", "# neu", 120),
                               ("Cache/off.txt", "cache", 90)):
        write(profiles, "Links/Projekt/" + name, text)
        os.utime(profiles / "Links/Projekt" / name, (1700006400 + second, 1700006400 + second))
    write(profiles, "Privat/privat.txt", "synthetisch")
    (profiles / "Links/Projekt/alias.txt").symlink_to(profiles / "Privat")
    write(profiles, "Rechts/Projekt/mittel.txt", "alt")
    write(profiles, "Rechts/Projekt/extra.txt", "extra")
    for name in ("Rechts", "Sicherung", "AbbruchLinks", "AbbruchRechts", "FehlerRechts", "FehlerDanach"):
        (journal / name).mkdir(parents=True)
    for name, text in (("Projekt/a.txt", "new text"), ("Projekt/b.txt", "second text"),
                       ("Projekt/Cache/off.txt", "cache"), ("Projekt/ignored.bin", "bin"),
                       ("Weglassen.txt", "not selected"), ("Umzug.txt", "move me")):
        write(journal, "Links/" + name, text)
    write(journal, "Rechts/Projekt/a.txt", "old")
    write(journal, "AbbruchLinks/A-Fertig.txt", "finished before interruption")
    (journal / "AbbruchLinks/Z-Daten.bin").write_bytes(b"j" * (32 * 1024 * 1024))
    write(damaged, "Links/Umzug.txt", "keep source")
    (damaged / "Rechts").mkdir(parents=True)
    write(damaged, "Auftragsablage/journal.json", "{broken")
    for name in ("Rechts", "Sicherung", "Links/Projekt/Leer"):
        (age / name).mkdir(parents=True)
    now = time.time()
    for name, text, days in (("passend.txt", "match", 3), ("alt.txt", "older", 12),
                             ("jung.txt", "young", 0.5), ("zukunft.txt", "future", -2),
                             ("klein.txt", "x", 3), ("auslassen.bin", "data", 3),
                             ("Unterordner/kind.txt", "kind", 5), ("Cache/bleibt.txt", "cache", 3)):
        write(age, "Links/Projekt/" + name, text)
        os.utime(age / "Links/Projekt" / name, (now - days * 86400, now - days * 86400))
    for name in ("Rechts", "Links/Fotos/Unterordner", "Links/Fotos-Extra", "ArchivRoot"):
        (workspace / name).mkdir(parents=True)
    write(workspace, "Links/Notizen.txt", "Grüße aus Wien\n")
    write(workspace, "Links/Plan.md", "# Ein Arbeitsbereich\n")
    png = preview_png((80, 160, 220))
    (workspace / "Links/Vorschau.png").write_bytes(png)
    for name, color in (("Berge.png", (130, 150, 180)), ("Wald.png", (60, 160, 100)), ("Wasser.png", (60, 160, 220))):
        (workspace / "Links/Fotos" / name).write_bytes(preview_png(color))
    write(workspace, "Links/Fotos/Aufnahme.txt", "Bildnotizen\n")
    for name in ("Rechts", "Links/Bilder"):
        (rename / name).mkdir(parents=True)
    for name, contents in (("Äpfel.TXT", "fruit-A"), ("Birne.txt", "fruit-B"), ("Kirsche.txt", "fruit-C")):
        write(rename, "Links/" + name, contents)
    (rename / "Links/Bilder/Bild.png").write_bytes(preview_png((80, 160, 220)))
    (rename / "Links/Bilder/Bild-Link.png").symlink_to("Bild.png")
    for folder in ("Rechts", "Archive", "Links/Office/word", "Viele"):
        (search / folder).mkdir(parents=True)
    for name, text in (("Notizen.txt", "Projekt Wiese\nGrüße aus Wien\n"), ("Bericht.md", "# Projekt\n"),
                       ("Unterordner/Plan.TXT", "Projektplan\n"), ("Nicht.txt", "Projekt auslassen"),
                       ("Cache42/off.txt", "Projekt Cache"), (".secret.txt", "Projekt versteckt")):
        write(search, "Links/Projekt/" + name, text)
    for index in range(400):
        write(search, "Viele/" + str(index) + ".txt", "synthetischer Suchtest")
    import zipfile
    with zipfile.ZipFile(search / "Archive/Paket.zip", "w") as archive:
        archive.writestr("Dokumente/eins.txt", "eins")
        archive.writestr("Dokumente/zwei.txt", "zwei")
    write(search, "Archive/kaputt.zip", "synthetischer Archivfehler")
    with zipfile.ZipFile(search / "Links/Office/Termin.docx", "w") as archive:
        archive.writestr("word/document.xml", "<document><p>Finanzplanung im Herbst</p></document>")
    for name, text in (("Bericht.txt", "neu"), ("Gleich.txt", "gleich"), ("Neu.txt", "neu links"),
                       ("Unterordner/Kind.txt", "Kind"), ("Konflikt.txt", "Datei"),
                       ("Cache42/off.txt", "Cache"), ("Weglassen.txt", "ausgelassen"), (".notiz.txt", "verborgen")):
        write(compare, "Links/" + name, text)
    for name, text in (("Bericht.txt", "alt"), ("Gleich.txt", "gleich"), ("Nur rechts.txt", "rechts"), ("Konflikt.txt/Kind.txt", "behalten")):
        write(compare, "Rechts/" + name, text)
    os.utime(compare / "Links/Bericht.txt", (1700000200, 1700000200))
    os.utime(compare / "Rechts/Bericht.txt", (1700000000, 1700000000))
    ux = base / "ux"
    for name in ("Links/Leer", "Links/Projekte", "Rechts/Sicherung"):
        (ux / name).mkdir(parents=True)
    write(ux, "Links/Notizen.txt", "Neue Notizen\n")
    write(ux, "Links/Budget.csv", "Posten;Betrag\nPlan;42\n")
    write(ux, "Rechts/Notizen.txt", "Vorhandene Notizen\n")
    (ux / "Links/Bild.png").write_bytes(preview_png((60, 150, 200)))
    navigation = base / "navigation"
    for name in ("Links/Dokumente", "Links/Dokumente und Bilder", "Links/Grüße aus Wien", "Links/Projekte", "Links/.Versteckt", "Rechts/Sicherung"):
        (navigation / name).mkdir(parents=True)
    write(navigation, "Links/Dokumente.txt", "Adressprüfung\n")
    files = base / "files"
    for name in ("Links/Ziel/Unterordner", "Links/Ordner.mit.Punkt", "Rechts/TabZiel", "Archiv", "Groß"):
        (files / name).mkdir(parents=True)
    write(files, "Links/Bericht.txt", "Original\n")
    write(files, "Links/Konflikt.txt", "Erhalten\n")
    write(files, "Außen/Eingang.txt", "Drop-Inhalt\n")
    (files / "Links/Bild.png").write_bytes(preview_png((60, 150, 200)))
    (files / "Abbruch.png").write_bytes(preview_png((180, 100, 80)))
    for index in range(3000):
        write(files, "Groß/Datei " + str(index) + ".txt", "Eintrag\n")
    recovery = base / "recovery"
    write(recovery, "Links/Projekt/a.txt", "Alpha\n")
    write(recovery, "Links/Projekt/Unterordner/b.txt", "Beta\n")
    write(recovery, "Links/Projekt/unberührt.tmp", "TMP\n")
    write(recovery, "Links/Projekt/Cache/c.txt", "Cache\n")
    write(recovery, "Links/Kopie.txt", "Neu\n")
    write(recovery, "Rechts/Kopie.txt", "Alt\n")
    write(recovery, "Links/Warten.txt", "Warten\n")
    (recovery / "Rechts/PauseZiel").mkdir(parents=True)
    (recovery / "Links/Groß.bin").write_bytes(bytes(range(256)) * (128 * 1024))
    remote = base / "remote"
    for name in ["Links/Projekt/Unterordner", "Links/Projekt/Leer", "Rechts", "Downloads", "Server/Eingang/Infos", "Server/Eingang/Leer"]:
        (remote / name).mkdir(parents=True, exist_ok=True)
    (remote / "Links/Projekt/Unterordner/Grüße.txt").write_text("Upload content ✔\n", encoding="utf-8")
    (remote / "Links/Projekt/Daten.txt").write_text("Upload file\n", encoding="utf-8")
    (remote / "Links/Projekt/Null.bin").write_bytes(b"")
    (remote / "Server/Eingang/Infos/Grüße.txt").write_text("Remote content ✔\n", encoding="utf-8")
    (remote / "Server/Eingang/Null.bin").write_bytes(b"")
    server_pane = base / "server-pane"
    shutil.copytree(remote, server_pane)
    shutil.copytree(remote / "Links/Projekt", server_pane / "Rechts/Projekt")
    write(server_pane, "Server/Alpha.txt", "Alpha content\n")
    write(server_pane, "Server/Zulu.bin", "Z" * 128)
    selection = base / "selection"
    for name in ("Links/Ordner", "Links/Plan.backup", "Rechts", "Server/Auswahl/Ordner", "Masse"):
        (selection / name).mkdir(parents=True)
    for name in ("Plan.txt", "Plan.md", "Other.TXT", "README", "Grüße.pdf", "it's $file.txt", "line\nbreak.txt"):
        write(selection, "Links/" + name, "synthetic selection content\n")
    for name in ("Plan.txt", "Plan.md", "Other.TXT"):
        write(selection, "Server/Auswahl/" + name, "synthetic remote content\n")
    for index in range(3000):
        write(selection, f"Masse/Datei-{index:04d}.txt", "bulk\n")
    tabs = base / "tabs"
    for name in ("Links/A", "Links/B", "Rechts"):
        (tabs / name).mkdir(parents=True)
    write(tabs, "Links/notiz.txt", "synthetic tab fixture\n")
    layout = base / "layout"
    for name in ("Links/A", "Links/B", "Rechts"):
        (layout / name).mkdir(parents=True)
    for name, contents in [("Links/A/Plan.txt", "text\n"), ("Links/A/Plan.md", "markdown\n"), ("Links/B/Notes.md", "note\n"), ("Links/B/skip.bin", "skip\n"), ("Rechts/Lesen.txt", "right\n")]:
        write(layout, name, contents)
    return main, operations, filters, merge, profiles, journal, damaged, age, workspace, rename, search, compare, ux, navigation, files, recovery, remote, server_pane, selection, tabs, layout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="App-Bundle oder ausführbare Testdatei")
    parser.add_argument("--results", required=True, type=Path, help="Ordner für native Testprotokolle")
    parser.add_argument("--screenshots", required=True, type=Path, help="Ordner für native Fensteransichten")
    parser.add_argument("--settings", type=Path, default=Path(__file__).resolve().parents[1] / "Tests/fixtures/INISettings.sample.ini", help="Nur gelesene INI-Datei oder Settings-Ordner; Standard: künstliches Testprofil")
    parser.add_argument("--interactive", action="store_true", help="Bei verweigerter Hintergrundaktivierung auf einen Klick in das Adressleisten-Prüffenster warten")
    parser.add_argument("--skip-foreground", action="store_true", help="Vordergrundprüfungen ausdrücklich auslassen, etwa bei gesperrtem Bildschirm")
    args = parser.parse_args()
    binary = args.app.resolve()
    if binary.suffix == ".app":
        binary /= "Contents/MacOS/ZweiCommander"
    if not binary.is_file():
        parser.error("Ausführbare ZweiCommander-Datei nicht gefunden")
    if not args.skip_foreground:
        probe = subprocess.run(["swift", "-e", 'import Foundation; import CoreGraphics; if let s = CGSessionCopyCurrentDictionary() as? [String:Any] { print(s["CGSSessionScreenIsLocked"] as? Bool == true ? "locked" : "available") } else { print("unavailable") }'], capture_output=True, text=True, timeout=10)
        if probe.returncode:
            parser.error("Der Status der GUI-Sitzung konnte nicht geprüft werden.")
        if probe.stdout.strip() != "available":
            parser.error("Die vollständige Serie benötigt eine entsperrte GUI-Sitzung. --skip-foreground führt die übrigen Prüfungen aus und kennzeichnet die ausgelassenen Fälle.")
    args.results.mkdir(parents=True, exist_ok=True)
    args.screenshots.mkdir(parents=True, exist_ok=True)
    prefix = args.screenshots.resolve() / "ZweiCommander"
    with tempfile.TemporaryDirectory(prefix="ZweiCommander-ui-") as temporary:
        roots = fixtures(Path(temporary))
        cases = [
            ("main", "--smoke-test", roots[0], str(prefix) + "-Import-Vorschau.png", "UI PASS ", "SMOKE PASS", 20),
            ("appearance-save", "--appearance-smoke", roots[0], str(prefix), "APPEARANCE UI PASS ", "APPEARANCE SMOKE PASS 47 checks", 47),
            ("appearance-reload", "--appearance-smoke", roots[0], str(prefix), "APPEARANCE UI PASS ", "APPEARANCE SMOKE PASS 9 checks", 9),
            ("rail", "--rail-smoke", roots[0], str(prefix), "RAIL UI PASS ", "RAIL SMOKE PASS 26 checks", 26),
            ("navigation", "--navigation-smoke", roots[13], str(prefix), "NAV UI PASS ", "NAV SMOKE PASS 46 checks", 46),
            ("files", "--file-ux-smoke", roots[14], str(prefix), "FILE UX PASS ", "FILE UX SMOKE PASS 62 checks", 62),
            ("ux-save", "--ux-smoke", roots[12], str(prefix), "UX UI PASS ", "UX SMOKE PASS 55 checks", 55),
            ("ux-reload", "--ux-smoke", roots[12], str(prefix), "UX UI PASS ", "UX SMOKE PASS 6 checks", 6),
            ("operations", "--operations-smoke", roots[1], str(prefix), "OPS UI PASS ", "OPS SMOKE PASS 14 checks", 14),
            ("filters", "--filters-smoke", roots[2], str(prefix), "FILTER UI PASS ", "FILTER SMOKE PASS 22 checks", 22),
            ("merge", "--merge-smoke", roots[3], str(prefix), "MERGE UI PASS ", "MERGE SMOKE PASS 29 checks", 29),
            ("profiles-save", "--profiles-smoke", roots[4], str(prefix), "PROFILE UI PASS ", "PROFILE SMOKE PASS 19 checks", 19),
            ("profiles-reload", "--profiles-smoke", roots[4], str(prefix), "PROFILE UI PASS ", "PROFILE SMOKE PASS 16 checks", 16),
            ("journal-save", "--journal-smoke", roots[5], str(prefix), "JOURNAL UI PASS ", "JOURNAL SMOKE PASS 8 checks", 8),
            ("journal-reload", "--journal-smoke", roots[5], str(prefix), "JOURNAL UI PASS ", "JOURNAL SMOKE PASS 23 checks", 23),
            ("journal-crash", "--journal-smoke", roots[5], str(prefix), "JOURNAL UI PASS ", "JOURNAL SMOKE PASS 7 checks", 7),
            ("journal-recover", "--journal-smoke", roots[5], str(prefix), "JOURNAL UI PASS ", "JOURNAL SMOKE PASS 13 checks", 13),
            ("journal-write-failure", "--journal-smoke", roots[5], str(prefix), "JOURNAL UI PASS ", "JOURNAL SMOKE PASS 10 checks", 10),
            ("journal-damaged", "--journal-smoke", roots[6], str(prefix), "JOURNAL UI PASS ", "JOURNAL SMOKE PASS 5 checks", 5),
            ("age-save", "--age-smoke", roots[7], str(prefix), "AGE UI PASS ", "AGE SMOKE PASS 12 checks", 12),
            ("age-reload", "--age-smoke", roots[7], str(prefix), "AGE UI PASS ", "AGE SMOKE PASS 19 checks", 19),
            ("workspace-save", "--workspace-smoke", roots[8], str(prefix), "WORKSPACE UI PASS ", "WORKSPACE SMOKE PASS 44 checks", 44),
            ("workspace-reload", "--workspace-smoke", roots[8], str(prefix), "WORKSPACE UI PASS ", "WORKSPACE SMOKE PASS 16 checks", 16),
            ("rename-save", "--rename-smoke", roots[9], str(prefix), "RENAME UI PASS ", "RENAME SMOKE PASS 20 checks", 20),
            ("rename-reload", "--rename-smoke", roots[9], str(prefix), "RENAME UI PASS ", "RENAME SMOKE PASS 27 checks", 27),
            ("search-save", "--search-smoke", roots[10], str(prefix), "SEARCH UI PASS ", "SEARCH SMOKE PASS 22 checks", 22),
            ("search-reload", "--search-smoke", roots[10], str(prefix), "SEARCH UI PASS ", "SEARCH SMOKE PASS 25 checks", 25),
            ("compare-save", "--compare-smoke", roots[11], str(prefix), "COMPARE UI PASS ", "COMPARE SMOKE PASS 24 checks", 24),
            ("compare-reload", "--compare-smoke", roots[11], str(prefix), "COMPARE UI PASS ", "COMPARE SMOKE PASS 30 checks", 30),
            ("recovery-save", "--recovery-smoke", roots[15], str(prefix), "RECOVERY UI PASS ", "RECOVERY SMOKE PASS 40 checks", 40),
            ("recovery-reload", "--recovery-smoke", roots[15], str(prefix), "RECOVERY UI PASS ", "RECOVERY SMOKE PASS 15 checks", 15),
            ("remote-save", "--remote-smoke", roots[16], str(prefix), "REMOTE UI PASS ", "REMOTE SMOKE PASS 31 checks", 31),
            ("remote-reload", "--remote-smoke", roots[16], str(prefix), "REMOTE UI PASS ", "REMOTE SMOKE PASS 14 checks", 14),
            ("server-pane", "--server-pane-smoke", roots[17], str(prefix), "SERVER PANE PASS ", "SERVER PANE SMOKE PASS 47 checks", 47),
            ("selection", "--selection-smoke", roots[18], str(prefix), "SELECTION UI PASS ", "SELECTION SMOKE PASS 90 checks", 90),
            ("tabs-save", "--tabs-smoke", roots[19], str(prefix), "TABS UI PASS ", "TABS SMOKE PASS 56 checks", 56),
            ("tabs-reload", "--tabs-smoke", roots[19], str(prefix), "TABS UI PASS ", "TABS SMOKE PASS 9 checks", 9),
            ("layout-save", "--layout-smoke", roots[20], str(prefix), "LAYOUT UI PASS ", "LAYOUT SMOKE PASS 62 checks", 62),
            ("layout-reload", "--layout-smoke", roots[20], str(prefix), "LAYOUT UI PASS ", "LAYOUT SMOKE PASS 15 checks", 15),
        ]
        if args.skip_foreground:
            foreground = {"navigation", "search-save", "search-reload", "compare-save", "compare-reload", "recovery-save", "recovery-reload", "remote-save", "remote-reload", "server-pane", "selection", "tabs-save", "tabs-reload", "layout-save", "layout-reload"}
            skipped = [case for case in cases if case[0] in foreground]
            cases = [case for case in cases if case[0] not in foreground]
            print("Ausgelassen: " + ", ".join(case[0] for case in skipped) + " · " + str(sum(case[-1] for case in skipped)) + " Vordergrundprüfungen offen", flush=True)
        suite = "local.zweicommander.tests." + str(uuid.uuid4())
        age_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        workspace_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        rename_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        search_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        compare_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        appearance_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        ux_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        remote_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        tabs_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        layout_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        remote_server = None
        pane_server = None
        try:
            for name, flag, root, image, pass_prefix, marker, expected in cases:
                command = [str(binary), flag, str(root), image]
                if name in {"server-pane", "selection"}:
                    fixture = Path(__file__).resolve().parents[1] / "Tests/fixtures/ftp_server.py"
                    pane_server = subprocess.Popen(["/usr/bin/python3", str(fixture), str(root / "Server"), "--delay", "0.001"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    deadline = time.monotonic() + 5
                    while not (root / "Server/port.txt").is_file() and time.monotonic() < deadline and pane_server.poll() is None:
                        time.sleep(0.02)
                    if not (root / "Server/port.txt").is_file():
                        raise SystemExit("Server-Tab-Testserver konnte nicht gestartet werden")
                if name.startswith("remote-"):
                    if remote_server is None:
                        fixture = Path(__file__).resolve().parents[1] / "Tests/fixtures/ftp_server.py"
                        remote_server = subprocess.Popen(["/usr/bin/python3", str(fixture), str(root / "Server"), "--delay", "0.001"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        deadline = time.monotonic() + 5
                        while not (root / "Server/port.txt").is_file() and time.monotonic() < deadline and remote_server.poll() is None:
                            time.sleep(0.02)
                        if not (root / "Server/port.txt").is_file():
                            raise SystemExit("Lokaler Remote-Testserver konnte nicht gestartet werden")
                    command += [name.removeprefix("remote-"), "--remote-test-suite", remote_suite]
                if name.startswith("layout-"):
                    command += ["--layout-test-suite", layout_suite]
                    if name == "layout-reload":
                        command += ["--reload-layout"]
                if name.startswith("tabs-"):
                    command += ["--tabs-test-suite", tabs_suite]
                    if name == "tabs-reload":
                        command += ["--reload-tabs"]
                if name.startswith("journal-"):
                    command += [name.removeprefix("journal-")]
                if name.startswith("recovery-"):
                    command += [name.removeprefix("recovery-")]
                if args.settings:
                    command += ["--import-settings", str(args.settings.resolve())]
                if name.startswith("appearance-"):
                    command += ["--appearance-test-suite", appearance_suite]
                    if name == "appearance-reload":
                        command += ["--reload-appearance"]
                if name.startswith("ux-"):
                    command += ["--ux-test-suite", ux_suite]
                    if name == "ux-reload":
                        command += ["--reload-ux"]
                if name.startswith("profiles-"):
                    command += ["--profile-test-suite", suite]
                    if name == "profiles-reload":
                        command += ["--reload-profiles"]
                if name.startswith("age-"):
                    command += ["--profile-test-suite", age_suite]
                    if name == "age-reload":
                        command += ["--reload-age"]
                if name.startswith("workspace-"):
                    command += ["--workspace-test-suite", workspace_suite]
                    if name == "workspace-reload":
                        command += ["--reload-workspace"]
                if name.startswith("rename-"):
                    command += ["--rename-test-suite", rename_suite]
                    if name == "rename-reload":
                        command += ["--reload-rename"]
                if name.startswith("search-"):
                    command += ["--search-test-suite", search_suite]
                    if name == "search-reload":
                        command += ["--reload-search"]
                if name.startswith("compare-"):
                    command += ["--compare-test-suite", compare_suite]
                    if name == "compare-reload":
                        command += ["--reload-compare"]
                if name == "navigation" and args.interactive:
                    command += ["--wait-for-foreground"]
                with (args.results / (name + ".log")).open("w", encoding="utf-8") as log:
                    try:
                        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180 if name == "navigation" and args.interactive else 120 if name in {"layout-save", "layout-reload"} else 90 if name in {"server-pane", "selection", "tabs-save", "tabs-reload"} else 45)
                    except subprocess.TimeoutExpired:
                        raise SystemExit(name + ": Zeitlimit überschritten; Testprozess beendet")
                output = (args.results / (name + ".log")).read_text(encoding="utf-8")
                count = sum(line.startswith(pass_prefix) for line in output.splitlines())
                if result.returncode or marker not in output or count != expected or " FAIL " in output:
                    raise SystemExit(name + ": fehlgeschlagen; Protokoll in " + str(args.results / (name + ".log")))
                if pane_server is not None:
                    pane_server.terminate()
                    try:
                        pane_server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        pane_server.kill()
                        pane_server.wait()
                    pane_server = None
                print(name + ": " + str(count) + " native UI-Prüfungen bestanden", flush=True)
        finally:
            if pane_server is not None:
                pane_server.terminate()
                try:
                    pane_server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pane_server.kill()
                    pane_server.wait()
            if remote_server is not None:
                remote_server.terminate()
                try:
                    remote_server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    remote_server.kill()
                    remote_server.wait()
            subprocess.run(["defaults", "delete", layout_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", tabs_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", remote_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", age_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", workspace_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", rename_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", search_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", compare_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", appearance_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", ux_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
