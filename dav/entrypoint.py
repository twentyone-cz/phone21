#!/usr/bin/env python3
"""Založí adresáře a soubor s účty, pak spustí server pod uživatelem 65534."""
import os
import sys

DATA = "/data"
UID = GID = 65534

def main():
    first = not os.path.isdir(os.path.join(DATA, "collections"))
    for sub in ("collections", "config"):
        os.makedirs(os.path.join(DATA, sub), exist_ok=True)
    users = os.path.join(DATA, "config", "users")
    if not os.path.exists(users):
        fd = os.open(users, os.O_WRONLY | os.O_CREAT, 0o600)
        os.close(fd)
    if os.getuid() == 0:
        # bind-mount zakládá docker jako root — vlastnictví se srovná při
        # prvním startu, potom už jen kořenové adresáře
        targets = [DATA, os.path.join(DATA, "collections"),
                   os.path.join(DATA, "config"), users]
        if first:
            for root, dirs, files in os.walk(DATA):
                targets.append(root)
                targets.extend(os.path.join(root, n) for n in files)
        for path in targets:
            try:
                os.chown(path, UID, GID)
            except OSError:
                pass
        os.setgid(GID)
        os.setuid(UID)
    os.execvp("python3", ["python3", "-m", "radicale",
                          "--config", "/etc/radicale/config"])

if __name__ == "__main__":
    main()
