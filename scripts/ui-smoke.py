#!/usr/bin/env python3
"""Native UI checks using isolated fixtures; never saves the user's app settings."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def write(root, name, contents):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")


def fixtures(base):
    main, operations, filters, merge, profiles = [base / name for name in ("main", "operations", "filters", "merge", "profiles")]
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
    return main, operations, filters, merge, profiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="App-Bundle oder ausführbare Testdatei")
    parser.add_argument("--results", required=True, type=Path, help="Ordner für die sechs Testprotokolle")
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
        ]
        suite = "local.zweicommander.tests." + str(uuid.uuid4())
        try:
            for name, flag, root, image, pass_prefix, marker, expected in cases:
                command = [str(binary), flag, str(root), image]
                if args.settings:
                    command += ["--import-settings", str(args.settings.resolve())]
                if name.startswith("profiles-"):
                    command += ["--profile-test-suite", suite]
                    if name == "profiles-reload":
                        command += ["--reload-profiles"]
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


if __name__ == "__main__":
    main()
