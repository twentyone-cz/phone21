#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Phone21 — vložení smyčky služby privátní sítě do compose souborů.

Zdroj pravdy je jediný soubor ``docker/ts-sidecar.sh``. Tenhle generátor ho
mechanicky vloží do bloku ``command:`` ve všech třech compose souborech mezi
značky, takže se tři kopie nemůžou rozejít (dřív se rozešly: každý soubor měl
vlastní, jinak starou verzi smyčky).

Co se při vkládání děje se skriptem:

* každý řádek dostane odsazení bloku (značka ``>>>`` určuje, jaké);
* prázdné řádky zůstanou opravdu prázdné (odsazení by v YAML jen dělalo
  neviditelné mezery);
* každý znak ``$`` se zdvojí na ``$$`` — compose do hodnot dosazuje proměnné
  a ``$$`` je jeho zápis pro obyčejný dolar. V kontejneru tedy poběží přesně to,
  co je ve skriptu.

Nic jiného se needituje. Žádný nový obraz nevzniká, do registru se nic nepushuje.

Použití::

    python3 scripts/gen-compose-sidecar.py            # zapíše do všech souborů
    python3 scripts/gen-compose-sidecar.py --check    # jen porovná (rc 1 = rozdíl)
    python3 scripts/gen-compose-sidecar.py --check docker-compose.standalone.yml

Návratové kódy: 0 = vše sedí (nebo zapsáno), 1 = rozdíl v režimu ``--check``,
2 = soubor nebo značky chybí, případně je blok poškozený.
"""

import argparse
import difflib
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SOURCE = os.path.join("docker", "ts-sidecar.sh")

TARGETS = (
    os.path.join("umbrel", "jednadvacet-phone21", "docker-compose.yml"),
    "docker-compose.standalone.yml",
    "docker-compose.tailscale.yml",
)

BEGIN = "# >>> ts-sidecar (generováno scripts/gen-compose-sidecar.py) >>>"
END = "# <<< ts-sidecar <<<"


class BlockError(Exception):
    """Značky v souboru chybí nebo je blok poškozený."""


def read_text(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def split_lines(text):
    """Řádky bez konců řádek + příznak, jestli soubor končí novým řádkem."""
    ends_nl = text.endswith("\n")
    lines = text.split("\n")
    if ends_nl:
        lines.pop()
    return lines, ends_nl


def join_lines(lines, ends_nl):
    return "\n".join(lines) + ("\n" if ends_nl else "")


def escape(line):
    """Compose dosazuje proměnné; obyčejný dolar se v hodnotě píše jako ``$$``."""
    return line.replace("$", "$$")


def render(script_lines, indent):
    """Skript jako řádky bloku ``command:`` včetně obou značek."""
    out = [indent + BEGIN]
    for line in script_lines:
        if line.strip():
            out.append(indent + escape(line))
        else:
            out.append("")
    out.append(indent + END)
    return out


def locate(lines, path):
    """Najde blok mezi značkami a vrátí (první, poslední, odsazení).

    Kontroluje se i to, že blok v YAML opravdu končí značkou ``<<<``: následující
    neprázdný řádek musí být odsazený míň, jinak by pod značkou zůstal starý
    kus skriptu, kterého by si generátor nevšiml.
    """
    begin = end = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped == BEGIN:
            if begin is not None:
                raise BlockError("%s: značka >>> je v souboru víc než jednou" % path)
            begin = i
        elif stripped == END:
            if end is not None:
                raise BlockError("%s: značka <<< je v souboru víc než jednou" % path)
            end = i
    if begin is None or end is None:
        raise BlockError(
            "%s: chybí značky bloku (%s ... %s)" % (path, BEGIN, END)
        )
    if end < begin:
        raise BlockError("%s: značka <<< je před značkou >>>" % path)

    indent = lines[begin][: len(lines[begin]) - len(lines[begin].lstrip())]
    if indent.strip():
        raise BlockError("%s: značka >>> není odsazená mezerami" % path)

    # Značka musí být prvním řádkem doslovného bloku YAML (``- |``), jinak by se
    # skript vložil někam, odkud by ho compose nepřečetl jako jeden příkaz.
    head = None
    for line in reversed(lines[:begin]):
        if line.strip():
            head = line
            break
    if head is None or head.rstrip()[-1:] != "|" \
            or len(head) - len(head.lstrip()) >= len(indent):
        raise BlockError(
            "%s: značka >>> nezačíná doslovný blok (nad ní musí být „- |“)" % path
        )
    if lines[end][: len(indent)] != indent or lines[end].lstrip() != END:
        raise BlockError("%s: značka <<< má jiné odsazení než >>>" % path)

    for line in lines[end + 1:]:
        if not line.strip():
            continue
        cur = len(line) - len(line.lstrip())
        if cur >= len(indent):
            raise BlockError(
                "%s: za značkou <<< pokračuje blok command "
                "(řádek %r je pořád uvnitř)" % (path, line.strip()[:60])
            )
        break

    return begin, end, indent


def process(path, script_lines, check):
    """Jeden soubor. Vrací True, když je (nebo nově bude) shodný se skriptem."""
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        raise BlockError("%s: soubor neexistuje" % path)

    text = read_text(full)
    lines, ends_nl = split_lines(text)
    begin, end, indent = locate(lines, path)

    current = lines[begin:end + 1]
    wanted = render(script_lines, indent)

    if current == wanted:
        return True

    if check:
        diff = difflib.unified_diff(
            current, wanted,
            fromfile="%s (v souboru)" % path,
            tofile="%s (podle %s)" % (path, SOURCE),
            lineterm="", n=1,
        )
        sys.stderr.write("\n".join(diff) + "\n")
        return False

    lines[begin:end + 1] = wanted
    with open(full, "w", encoding="utf-8") as fh:
        fh.write(join_lines(lines, ends_nl))
    return False


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Vloží docker/ts-sidecar.sh do compose souborů mezi značky.",
    )
    ap.add_argument(
        "--check", action="store_true",
        help="jen porovnat, nic nezapisovat (rozdíl = návratový kód 1)",
    )
    ap.add_argument(
        "--quiet", "-q", action="store_true",
        help="mlčet, když je všechno v pořádku",
    )
    ap.add_argument(
        "targets", nargs="*", metavar="SOUBOR",
        help="compose soubory (bez uvedení se projdou všechny tři)",
    )
    args = ap.parse_args(argv)

    source = os.path.join(ROOT, SOURCE)
    if not os.path.exists(source):
        sys.stderr.write("chybí zdrojový skript %s\n" % SOURCE)
        return 2
    script_lines, _ = split_lines(read_text(source))

    # Cesty se hlásí vůči kořeni repa, aby byly hlášky čitelné; co leží mimo
    # něj, zůstane absolutní.
    targets = []
    for t in (args.targets or list(TARGETS)):
        if os.path.isabs(t):
            rel = os.path.relpath(os.path.abspath(t), ROOT)
            t = rel if not rel.startswith(os.pardir) else os.path.abspath(t)
        targets.append(t)

    differs = []
    for path in targets:
        try:
            same = process(path, script_lines, args.check)
        except BlockError as exc:
            sys.stderr.write("%s\n" % exc)
            return 2
        if same:
            if not args.quiet:
                print("beze změny: %s" % path)
        else:
            differs.append(path)
            if args.check:
                print("ROZDÍL: %s" % path)
            else:
                print("zapsáno: %s" % path)

    if args.check and differs:
        sys.stderr.write(
            "compose soubory se rozešly se skriptem %s "
            "(spusť scripts/gen-compose-sidecar.py bez --check)\n" % SOURCE
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
