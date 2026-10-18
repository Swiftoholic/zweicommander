#!/usr/bin/env python3
"""Native UI checks using isolated fixtures; never saves the user's app settings."""
import argparse
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
    main, operations, filters, merge, profiles, journal, damaged, age, workspace = [base / name for name in ("main", "operations", "filters", "merge", "profiles", "journal", "damaged", "age", "workspace")]
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
    return main, operations, filters, merge, profiles, journal, damaged, age, workspace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="App-Bundle oder ausführbare Testdatei")
    parser.add_argument("--results", required=True, type=Path, help="Ordner für native Testprotokolle")
    parser.add_argument("--screenshots", required=True, type=Path, help="Ordner für native Fensteransichten")
    parser.add_argument("--settings", type=Path, default=Path(__file__).resolve().parents[1] / "Tests/fixtures/INISettings.sample.ini", help="Nur gelesene INI-Datei oder Settings-Ordner; Standard: künstliches Testprofil")
    args = parser.parse_args()
    binary = args.app.resolve()
    if binary.suffix == ".app":
        binary /= "Contents/MacOS/ZweiCommander"
    if not binary.is_file():
        parser.error("Ausführbare ZweiCommander-Datei nicht gefunden")
    args.results.mkdir(parents=True, exist_ok=True)
    args.screenshots.mkdir(parents=True, exist_ok=True)
    prefix = args.screenshots.resolve() / "ZweiCommander"
    with tempfile.TemporaryDirectory(prefix="ZweiCommander-ui-") as temporary:
        roots = fixtures(Path(temporary))
        cases = [
            ("main", "--smoke-test", roots[0], str(prefix) + "-Import-Vorschau.png", "UI PASS ", "SMOKE PASS", 20),
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
        ]
        suite = "local.zweicommander.tests." + str(uuid.uuid4())
        age_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        workspace_suite = "local.zweicommander.tests." + str(uuid.uuid4())
        try:
            for name, flag, root, image, pass_prefix, marker, expected in cases:
                command = [str(binary), flag, str(root), image]
                if name.startswith("journal-"):
                    command += [name.removeprefix("journal-")]
                if args.settings:
                    command += ["--import-settings", str(args.settings.resolve())]
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
                with (args.results / (name + ".log")).open("w", encoding="utf-8") as log:
                    try:
                        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=45)
                    except subprocess.TimeoutExpired:
                        raise SystemExit(name + ": Zeitlimit überschritten; Testprozess beendet")
                output = (args.results / (name + ".log")).read_text(encoding="utf-8")
                count = sum(line.startswith(pass_prefix) for line in output.splitlines())
                if result.returncode or marker not in output or count != expected or " FAIL " in output:
                    raise SystemExit(name + ": fehlgeschlagen; Protokoll in " + str(args.results / (name + ".log")))
                print(name + ": " + str(count) + " native UI-Prüfungen bestanden", flush=True)
        finally:
            subprocess.run(["defaults", "delete", suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", age_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["defaults", "delete", workspace_suite], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
