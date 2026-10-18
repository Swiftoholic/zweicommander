#!/usr/bin/env python3
"""Check the exact staged source snapshot before publishing it."""
from pathlib import PurePosixPath
import re
import subprocess


ROOT_FILES = {".gitignore", "README.md", "FUNKTIONEN.md", "IMPORT.md", "PRUEFBERICHT.txt", "Package.swift", "build.sh"}
SCRIPT_FILES = {"scripts/test.sh", "scripts/icon.swift", "scripts/ui-smoke.py", "scripts/check-public.py"}
FIXTURE_FILES = {"Tests/fixtures/ftp_server.py", "Tests/fixtures/INISettings.sample.ini", "Tests/fixtures/INISettings.sample.shc"}


def allowed(path):
    name = PurePosixPath(path)
    return (path in ROOT_FILES or path in SCRIPT_FILES or path in FIXTURE_FILES
            or path == "Resources/Info.plist"
            or (path.startswith("Sources/") and name.suffix in {".swift", ".c", ".h"})
            or (path.startswith("Tests/CommanderCoreTests/") and name.suffix == ".swift"))


def main():
    top = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    entries = subprocess.check_output(["git", "-C", top, "ls-files", "--stage", "-z"]).split(b"\0")
    errors, count = [], 0
    checks = [
        ("absolute home directory", re.compile(r"/(?:Users|home)/[^/\s\"']+|[A-Z]:\\+(?:Users|Documents and Settings)\\+", re.I)),
        ("private key", re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----")),
        ("access token", re.compile(r"(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}")),
    ]
    email = re.compile(r"[A-Za-z0-9_.+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
    safe_email_domains = {"example.com", "example.org", "example.net", "users.noreply.github.com"}
    for entry in entries:
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, sha, stage = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        count += 1
        if mode not in {"100644", "100755"} or stage != "0" or not allowed(path):
            errors.append(path + ": outside the source allowlist or unsupported file type")
            continue
        data = subprocess.check_output(["git", "-C", top, "cat-file", "blob", sha])
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(path + ": non-text content")
            continue
        if b"\0" in data or len(data) > 2 * 1024 * 1024:
            errors.append(path + ": unexpected binary or oversized content")
        for label, pattern in checks:
            if pattern.search(text):
                errors.append(path + ": " + label)
        for value in email.findall(text):
            domain = value.rsplit("@", 1)[1].lower()
            if domain not in safe_email_domains and not domain.endswith((".invalid", ".test")):
                errors.append(path + ": non-example email address")
    if not count:
        errors.append("No staged project files")
    if errors:
        raise SystemExit("Public source check failed:\n" + "\n".join(errors))
    print(str(count) + " staged text files passed the public source check; manual review is still required.")


if __name__ == "__main__":
    main()
