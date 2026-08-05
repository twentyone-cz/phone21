#!/usr/bin/env python3
"""GSM2SIP web UI — správa a diagnostika brány.

Čistá stdlib (žádné závislosti). Mluví s Asteriskem přes AMI (localhost),
žurnál/frontu SMS čte z /var/lib/gsm2sip. Basic auth (WEBUI_PASSWORD).
Určeno výhradně pro LAN/privátní síť — nikdy nevystavovat veřejně.
"""

import base64
import html
import json
import os
import re
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AMI_HOST = os.environ.get("AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("AMI_PORT", "5038"))
AMI_USER = os.environ.get("AMI_USER", "gsm2sip-webui")
AMI_PASSWORD = os.environ.get("AMI_PASSWORD", "")
WEBUI_PASSWORD = os.environ.get("WEBUI_PASSWORD", "")
WEBUI_PORT = int(os.environ.get("WEBUI_PORT", "8090"))
SIP_USER = os.environ.get("SIP_USER", "softphone")
DATA_DIR = os.environ.get("GSM2SIP_DATA", "/var/lib/gsm2sip")
LOG_FILE = os.environ.get("ASTERISK_LOG", "/var/log/asterisk/messages.log")
DEVICE = os.environ.get("QUECTEL_DEVICE", "quectel0")
COUNTRY_CODE = os.environ.get("COUNTRY_CODE", "420")
# Umbrel režim: tajemství generuje entrypoint asterisku do sdíleného souboru
# (AMI_PASSWORD env pak není nastavené) a privátní síť se ovládá přes TS_DIR.
AMI_SECRETS_FILE = os.environ.get("AMI_SECRETS_FILE", "")
TS_DIR = os.environ.get("TS_DIR", "")
# UI režim: "expert" = technické záložky (Docker/LXC default),
# "gui" = spotřebitelský dashboard (Umbrel appka) s technikou pod Pokročilé.
UI_MODE = os.environ.get("UI_MODE", "expert")
GUI = UI_MODE == "gui"


def read_secrets():
    """SIP/AMI tajemství ze sdíleného volume (generuje entrypoint asterisku)."""
    d = {}
    if AMI_SECRETS_FILE:
        try:
            with open(AMI_SECRETS_FILE) as f:
                for ln in f:
                    if "=" in ln:
                        k, v = ln.strip().split("=", 1)
                        d[k] = v
        except OSError:
            pass
    return d


def ami_password():
    return AMI_PASSWORD or read_secrets().get("AMI_PASSWORD", "")

_ami_lock = threading.Lock()


class AmiError(Exception):
    pass


class Ami:
    """Minimální AMI klient: login → akce → logoff, jedno spojení na dotaz."""

    def __init__(self):
        self.sock = socket.create_connection((AMI_HOST, AMI_PORT), timeout=8)
        self.buf = b""
        self._read_until(b"\r\n")  # banner
        resp = self.action("Login", Username=AMI_USER, Secret=ami_password())
        if "Success" not in resp.get("Response", ""):
            raise AmiError("AMI login selhal: %s" % resp.get("Message"))

    def _read_until(self, marker):
        while marker not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise AmiError("AMI spojení ukončeno")
            self.buf += chunk
        data, self.buf = self.buf.split(marker, 1)
        return data

    def action(self, name, **kw):
        lines = ["Action: " + name] + ["%s: %s" % (k, v) for k, v in kw.items()]
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        raw = self._read_until(b"\r\n\r\n").decode(errors="replace")
        resp = {}
        for ln in raw.splitlines():
            if ": " in ln:
                k, v = ln.split(": ", 1)
                resp[k] = v
        resp["_raw"] = raw
        return resp

    def command(self, cli):
        """CLI příkaz; Asterisk 20 vrací výstup v Output: řádcích."""
        resp = self.action("Command", Command=cli)
        out = []
        for ln in resp["_raw"].splitlines():
            if ln.startswith("Output: "):
                out.append(ln[len("Output: "):])
        return "\n".join(out) if out else resp.get("Message", resp["_raw"])

    def close(self):
        try:
            self.action("Logoff")
        except Exception:
            pass
        self.sock.close()


def ami_call(fn):
    """Serializovaný AMI dotaz (jedno spojení, krátce žijící)."""
    with _ami_lock:
        ami = Ami()
        try:
            return fn(ami)
        finally:
            ami.close()


def cli(cmd):
    try:
        return ami_call(lambda a: a.command(cmd))
    except Exception as e:  # UI nesmí spadnout kvůli AMI výpadku
        return "CHYBA AMI: %s" % e


def normalize_msisdn(num, cc=None):
    """Normalizace čísla na E.164 (+420...) — STEJNÁ pravidla jako subrutina
    [number-normalize] v asterisk/extensions.conf; při změně upravit obě
    místa! Krátká čísla a alfanumerická ID vrací beze změny."""
    cc = cc or COUNTRY_CODE
    n = num.strip()
    if not n or n.startswith("+"):
        return n
    if not n.isdigit():
        return num
    if n.startswith("00") and len(n) > 4:
        return "+" + n[2:]
    if n.startswith(cc) and len(n) == len(cc) + 9:
        return "+" + n
    if len(n) == 9:
        return "+" + cc + n
    return num


MISSED_MODES = ("ring", "announce")


def get_missed_mode():
    """Aktuální chování k volajícímu při offline telefonu (AstDB přes AMI).
    Prázdný/nečitelný klíč = default ring."""
    out = cli("database get gsm2sip missed_mode")
    for ln in out.splitlines():
        if ln.startswith("Value:"):
            val = ln.split(":", 1)[1].strip()
            if val in MISSED_MODES:
                return val
    return "ring"


def read_journal(limit=200):
    path = os.path.join(DATA_DIR, "journal.jsonl")
    rows = []
    try:
        with open(path, "rb") as f:
            lines = f.readlines()[-limit:]
        for ln in reversed(lines):
            try:
                rec = json.loads(ln)
                sms = {}
                try:
                    sms = json.loads(base64.b64decode(rec.get("sms_b64", "")))
                except Exception:
                    pass
                rows.append({
                    "t": rec.get("t", ""),
                    "status": rec.get("status", ""),
                    "from": sms.get("from", "?"),
                    "msg": sms.get("msg", ""),
                })
            except Exception:
                continue
    except FileNotFoundError:
        pass
    return rows


def read_queue():
    qdir = os.path.join(DATA_DIR, "queue")
    items = []
    try:
        for name in sorted(os.listdir(qdir)):
            if name.endswith(".b64"):
                p = os.path.join(qdir, name)
                try:
                    sms = json.loads(base64.b64decode(open(p).read()))
                except Exception:
                    sms = {}
                items.append({
                    "qid": name[:-4],
                    "age_min": int((time.time() - os.path.getmtime(p)) / 60),
                    "from": sms.get("from", "?"),
                    "msg": sms.get("msg", ""),
                })
    except FileNotFoundError:
        pass
    return items


def read_watchdog(n=5):
    """Poslední záznamy watchdogu. Restarty brány jsou jinak neviditelné —
    telefon se prostě odregistruje a není poznat proč."""
    try:
        with open(os.path.join(DATA_DIR, "watchdog.log"), "rb") as f:
            return [ln.decode(errors="replace").rstrip()
                    for ln in f.readlines()[-n:]]
    except FileNotFoundError:
        return []


def tail_log(n=120):
    try:
        with open(LOG_FILE, "rb") as f:
            return b"\n".join(f.readlines()[-n:]).decode(errors="replace")
    except FileNotFoundError:
        return "(log %s neexistuje — zkontroluj logger.conf a volume)" % LOG_FILE


# Barvy: expert = zelený terminálový vzhled, gui = jednadvacet oranžová.
ACCENT = "#F7931A" if GUI else "#9c9"
NAVBG = "#1a1409" if GUI else "#1b2a1b"
BTN = "#F7931A" if GUI else "#2a4"
BTNFG = "#111" if GUI else "#fff"

PAGE = """<!doctype html><html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{brand_plain}</title><style>
body{{font-family:system-ui,sans-serif;margin:0;background:#111;color:#ddd}}
nav{{background:%(navbg)s;padding:.6rem 1rem}}
nav .brand{{color:%(acc)s;font-weight:400;margin-right:1.4rem}}
nav .brand b{{font-weight:800}}
nav a{{color:%(acc)s;margin-right:1rem;text-decoration:none;font-weight:600}}
nav a.act{{color:#fff;border-bottom:2px solid %(acc)s}}
main{{padding:1rem;max-width:1100px;margin:auto}}
pre{{background:#000;padding:.8rem;border-radius:6px;overflow-x:auto;font-size:.85rem;line-height:1.35}}
table{{border-collapse:collapse;width:100%%;font-size:.9rem}}
td,th{{border-bottom:1px solid #333;padding:.35rem .5rem;text-align:left;vertical-align:top}}
th{{color:%(acc)s}}tr:hover{{background:#1a1a1a}}
.ok{{color:#7d7}}.bad{{color:#e77}}.warn{{color:#dc8}}
form.inline{{display:flex;gap:.5rem;flex-wrap:wrap;margin:.8rem 0}}
input,textarea,button{{background:#222;color:#ddd;border:1px solid #444;border-radius:4px;padding:.45rem}}
button{{background:%(btn)s;border:0;color:%(btnfg)s;cursor:pointer;font-weight:700}}
small{{color:#888}}
h2{{color:%(acc)s;font-size:1rem;margin:1.2rem 0 .4rem}}
.tiles{{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:1rem;margin:1rem 0}}
.tile{{background:#191919;border:1px solid #2a2a2a;border-radius:10px;padding:1rem 1.1rem}}
.tile h3{{margin:.1rem 0 .4rem;font-size:1.02rem;color:#eee}}
.tile .big{{font-size:1.25rem;font-weight:700}}
details{{margin:.8rem 0}}summary{{cursor:pointer;color:%(acc)s}}
</style></head><body>
<nav><span class="brand">{brand}</span>{nav}</nav>
<main>{body}</main>
<footer style="padding:1rem;text-align:center"><small>jen LAN/privátní síť · {now}</small></footer>
</body></html>""" % {"acc": ACCENT, "navbg": NAVBG, "btn": BTN, "btnfg": BTNFG}
PAGE = PAGE.replace("{brand_plain}", "jednadvacet phone" if GUI else "GSM2SIP")


def render(active, body):
    if GUI:
        tabs = [("/", "home", "Domů"), ("/sms", "sms", "Zprávy")]
        if TS_DIR:
            tabs.append(("/net", "net", "Síť"))
        tabs.append(("/stav", "status", "Pokročilé"))
        nav = "".join('<a href="%s" class="%s">%s</a>' %
                      (h, "act" if active == k else "", t) for h, k, t in tabs)
        return PAGE.format(nav=nav, brand="jednadvacet <b>phone</b>",
                           body=body, now=time.strftime("%Y-%m-%d %H:%M:%S"))
    tabs = [("/", "status", "Stav"), ("/sms", "sms", "SMS")]
    if TS_DIR:
        tabs.append(("/net", "net", "Síť"))
    tabs.append(("/diag", "diag", "Diagnostika"))
    nav = "".join('<a href="%s" class="%s">%s</a>' %
                  (h, "act" if active == k else "", t) for h, k, t in tabs)
    return PAGE.format(nav=nav, brand="GSM2SIP",
                       body=body, now=time.strftime("%Y-%m-%d %H:%M:%S"))


def esc(s):
    return html.escape(str(s), quote=True)


def ts_ip():
    try:
        return open(os.path.join(TS_DIR, "ip")).read().strip()
    except OSError:
        return ""


def modem_summary():
    """Klíčové položky z `quectel show device state` pro dashboard."""
    out = cli("quectel show device state " + DEVICE)
    if out.startswith("CHYBA AMI"):
        return None
    d = {}
    for ln in out.splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            d[k.strip()] = v.strip()
    return d


def page_home(info=""):
    """GUI režim (Umbrel): spotřebitelský dashboard místo technických výpisů."""
    tiles = []
    m = modem_summary()
    if m and m.get("State") == "Free":
        tiles.append(
            '<div class="tile"><h3>📶 Mobilní síť</h3><div class="big ok">Připojeno</div>'
            "<small>%s · %s · signál %s</small></div>"
            % (esc(m.get("Provider Name", "?")),
               esc(m.get("Access technology", "?")), esc(m.get("RSSI", "?"))))
    elif m and m.get("State"):
        tiles.append(
            '<div class="tile"><h3>📶 Mobilní síť</h3><div class="big warn">%s</div>'
            "<small>modem se připojuje — chvíli to trvá; zkontroluj SIM a anténu</small></div>"
            % esc(m.get("State")))
    else:
        tiles.append(
            '<div class="tile"><h3>📶 Mobilní síť</h3><div class="big bad">Nedostupné</div>'
            '<small>ústředna nekomunikuje — detail v <a href="/stav">Pokročilé</a></small></div>')
    ip = ts_ip()
    if ip:
        tiles.append(
            '<div class="tile"><h3>🔒 Privátní síť</h3><div class="big ok">Připojeno</div>'
            "<small>adresa krabičky: <b>%s</b> · <a href=\"/net\">detail</a></small></div>" % esc(ip))
    else:
        tiles.append(
            '<div class="tile"><h3>🔒 Privátní síť</h3><div class="big warn">Nepřipojeno</div>'
            '<small><a href="/net">vlož klíč privátní sítě</a> — telefon se pak dovolá odkudkoli</small></div>')
    sec = read_secrets()
    if ip and sec.get("SIP_USER"):
        tiles.append(
            '<div class="tile"><h3>📱 Telefon</h3><div class="big ok">Připraveno</div>'
            '<small>přihlašovací údaje pro aplikaci najdeš v <a href="/net">Síť</a>; '
            'návod: <a href="https://phone.twentyone.cz/instalace" target="_blank">instalace</a></small></div>')
    else:
        tiles.append(
            '<div class="tile"><h3>📱 Telefon</h3><div class="big warn">Čeká</div>'
            "<small>nejdřív připoj krabičku do privátní sítě</small></div>")
    rows = read_journal(limit=5)
    last = rows[0] if rows else None
    tiles.append(
        '<div class="tile"><h3>💬 Zprávy</h3><div class="big">%s</div>'
        '<small>%s · <a href="/sms">všechny zprávy</a></small></div>'
        % ((esc(last["from"]) if last else "—"),
           (esc(last["msg"][:60]) if last else "zatím žádné")))
    mode = get_missed_mode()
    modeform = (
        '<form class="inline" method="post" action="/missed-mode">'
        '<label><input type="radio" name="mode" value="ring"%s> vyzvánět naprázdno</label>'
        '<label><input type="radio" name="mode" value="announce"%s> hláska nedostupnosti</label>'
        "<button>Uložit</button></form>"
        % (" checked" if mode == "ring" else "", " checked" if mode == "announce" else ""))
    return render("home", (
        '%s<div class="tiles">%s</div>'
        "<h2>Když nejsi k zastižení</h2>"
        "<p><small>Zmeškaný hovor ti vždy přijde jako zpráva. Co má slyšet volající:</small></p>%s"
    ) % (info, "".join(tiles), modeform))


def page_status(mode_info=""):
    dev = cli("quectel show devices")
    state = cli("quectel show device state " + DEVICE)
    contacts = cli("pjsip show contacts")
    chans = cli("core show channels")
    q = read_queue()
    qbadge = ('<span class="warn">%d SMS čeká ve frontě</span>' % len(q)) if q \
        else '<span class="ok">fronta prázdná</span>'
    wd = read_watchdog()
    wdblock = ('<pre>%s</pre>' % esc("\n".join(wd))) if wd else \
        '<p><span class="ok">watchdog zatím nikdy nezasáhl</span></p>'
    mode = get_missed_mode()
    modeblock = (
        '%s<form class="inline" method="post" action="/missed-mode">'
        '<label><input type="radio" name="mode" value="ring"%s> '
        "vyzvánět naprázdno (~30 s, hovor se nepřijme, volajícímu se neúčtuje)</label>"
        '<label><input type="radio" name="mode" value="announce"%s> '
        "hláska nedostupnosti (hovor se přijme — volajícímu se může účtovat)</label>"
        "<button>Uložit</button></form>"
        "<small>Zmeškaný hovor při offline telefonu vždy pošle notifikaci do "
        "chatu (od čísla volajícího), doručí se po znovupřipojení.</small>"
    ) % (mode_info,
         ' checked' if mode == "ring" else '',
         ' checked' if mode == "announce" else '')
    return render("status", (
        "<h2>Modem</h2><pre>%s</pre>"
        "<h2>Detail zařízení</h2><pre>%s</pre>"
        "<h2>SIP registrace softphonu</h2><pre>%s</pre>"
        "<h2>Hovory</h2><pre>%s</pre>"
        "<h2>SMS fronta</h2><p>%s</p>"
        "<h2>Nedostupný telefon — chování k volajícímu</h2>%s"
        "<h2>Watchdog modemu</h2>%s"
        '<p><button onclick="location.reload()">Obnovit</button></p>'
    ) % (esc(dev), esc(state), esc(contacts), esc(chans), qbadge, modeblock,
         wdblock))


def page_sms(sent_info=""):
    rows = read_journal()
    q = read_queue()
    qrows = "".join(
        "<tr><td>%s</td><td>%s min</td><td>%s</td><td>%s</td></tr>" %
        (esc(i["qid"]), i["age_min"], esc(i["from"]), esc(i["msg"])) for i in q) \
        or '<tr><td colspan="4"><small>prázdná</small></td></tr>'
    jrows = "".join(
        '<tr><td><small>%s</small></td><td class="%s">%s</td><td>%s</td><td>%s</td></tr>' % (
            esc(r["t"]),
            "ok" if r["status"].startswith(("recv-SUCCESS", "delivered")) else
            ("bad" if r["status"].startswith("failed") else "warn"),
            esc(r["status"]), esc(r["from"]), esc(r["msg"])) for r in rows) \
        or '<tr><td colspan="4"><small>žurnál je prázdný</small></td></tr>'
    return render("sms", (
        "%s<h2>Poslat SMS</h2>"
        '<form class="inline" method="post" action="/sms/send">'
        '<input name="to" placeholder="+420..." required pattern="[+0-9]{6,16}">'
        '<input name="text" placeholder="text zprávy" required size="40" maxlength="459">'
        "<button>Odeslat</button></form>"
        "<small>Potvrzení o předání do sítě přijde do chatu v softphonu "
        "(exten report) a do žurnálu/logu.</small>"
        "<h2>Fronta (čekající na doručení do softphonu)</h2>"
        "<table><tr><th>qid</th><th>stáří</th><th>od</th><th>text</th></tr>%s</table>"
        "<h2>Žurnál (nejnovější nahoře)</h2>"
        "<table><tr><th>čas</th><th>stav</th><th>od</th><th>text</th></tr>%s</table>"
    ) % (sent_info, qrows, jrows))


def page_net(info=""):
    """Privátní síť (Umbrel): stav připojení, vložení auth klíče, SIP údaje."""
    ip = ""
    try:
        ip = open(os.path.join(TS_DIR, "ip")).read().strip()
    except OSError:
        pass
    pending = os.path.exists(os.path.join(TS_DIR, "authkey"))
    sec = read_secrets()
    dash = os.environ.get("NET_DASHBOARD_URL", "https://cockscale.twentyone.cz")
    blocks = [info, "<h2>Privátní síť</h2>"]
    if ip:
        blocks.append('<p><span class="ok">Brána je připojená — adresa v privátní '
                      "síti: <b>%s</b></span></p>" % esc(ip))
    elif pending:
        blocks.append('<p><span class="warn">Klíč vložen, připojuji…</span> '
                      "<button onclick=\"location.reload()\">Obnovit</button></p>")
    # Formulář je dostupný VŽDY (ne jen při prvním setupu): klíč platí 24 h,
    # zobrazí se jen jednou, a po 90 dnech neplacení je potřeba nový.
    blocks.append(
        "<p>%s auth klíč z <a href=\"%s\" target=\"_blank\">dashboardu "
        "privátní sítě</a> (Přidat zařízení; klíč platí 24 h a zobrazí se "
        "jen jednou):</p>"
        '<form class="inline" method="post" action="/net/authkey">'
        '<input name="authkey" placeholder="hskey-auth-..." size="40" required>'
        "<button>Připojit</button></form>"
        % ("Nové připojení / obnova po expiraci — vlož" if ip else
           "Brána zatím není v privátní síti. Vlož", esc(dash)))
    if ip and sec.get("SIP_USER"):
        blocks.append(
            "<h2>Nastavení softphonu (Linphone)</h2>"
            "<table><tr><th>Uživatel</th><td>%s</td></tr>"
            "<tr><th>Heslo</th><td><code>%s</code></td></tr>"
            "<tr><th>Doména/server</th><td>%s</td></tr>"
            "<tr><th>Transport</th><td>UDP</td></tr></table>"
            "<small>Telefon musí být ve stejné privátní síti "
            "(aplikace privátní sítě + tvůj klíč zařízení).</small>"
            % (esc(sec["SIP_USER"]), esc(sec.get("SIP_PASSWORD", "")), esc(ip)))
    return render("net", "".join(blocks))


def page_diag(at_info=""):
    return render("diag", (
        "%s<h2>AT příkaz</h2>"
        '<form class="inline" method="post" action="/diag/at">'
        '<input name="cmd" placeholder="AT+CSQ" required size="30">'
        "<button>Poslat</button></form>"
        "<small>Odpověď dorazí asynchronně — objeví se v logu níže "
        "(Got Response). Pozor, některé AT příkazy modem rozbijí.</small>"
        "<h2>Log Asterisku (tail)</h2><pre>%s</pre>"
        '<p><button onclick="location.reload()">Obnovit</button></p>'
    ) % (at_info, esc(tail_log())))


class Handler(BaseHTTPRequestHandler):
    server_version = "gsm2sip-webui"

    def _authed(self):
        if not WEBUI_PASSWORD:
            return False  # bez hesla neběžíme
        hdr = self.headers.get("Authorization", "")
        if hdr.startswith("Basic "):
            try:
                _, pwd = base64.b64decode(hdr[6:]).decode().split(":", 1)
                return pwd == WEBUI_PASSWORD
            except Exception:
                return False
        return False

    def _deny(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="GSM2SIP"')
        self.end_headers()
        self.wfile.write(b"auth required (user libovolny, heslo WEBUI_PASSWORD)")

    def _html(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _form(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(min(length, 65536)).decode()
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def do_GET(self):
        if not self._authed():
            return self._deny()
        if self.path == "/":
            return self._html(page_home() if GUI else page_status())
        if self.path == "/stav":
            return self._html(page_status())
        if self.path == "/sms":
            return self._html(page_sms())
        if self.path == "/net" and TS_DIR:
            return self._html(page_net())
        if self.path == "/diag":
            return self._html(page_diag())
        self._html("<p>404</p>", 404)

    def do_POST(self):
        if not self._authed():
            return self._deny()
        form = self._form()
        if self.path == "/missed-mode":
            page = page_home if GUI else page_status
            mode = form.get("mode", "")
            if mode not in MISSED_MODES:
                return self._html(page('<p class="bad">Neplatný režim.</p>'))
            # Enum konstanta, žádný user input do CLI. Dialplan čte
            # ${DB(gsm2sip/missed_mode)} — AstDB leží na persistentním volume
            # (astdbdir v asterisk.conf), takže volba přežije i recreate.
            cli("database put gsm2sip missed_mode " + mode)
            saved = get_missed_mode()
            info = ('<p class="ok">Uloženo (%s).</p>' % esc(saved)) if saved == mode \
                else '<p class="bad">Zápis se nepotvrdil — zkontroluj AMI/AstDB.</p>'
            return self._html(page(info))
        if self.path == "/sms/send":
            to = "".join(c for c in form.get("to", "") if c in "+0123456789")
            to = normalize_msisdn(to)
            text = form.get("text", "")[:459]
            if not to or not text:
                return self._html(page_sms('<p class="bad">Chybí číslo nebo text.</p>'))
            try:
                # Destination = cíl technologie, To = telefonní číslo. Driver si
                # číslo bere z ast_msg_get_to(), tedy z To — ne z Destination
                # a už vůbec ne z Variable. Dřív tu bylo To="mobile:quectel0"
                # a číslo ve Variable MESSAGE(to): driver pak sestavil PDU
                # s nulovou délkou cílového čísla, modem na něj neodpověděl
                # a zatuhl tak, že přestal reagovat i na holé AT.
                resp = ami_call(lambda a: a.action(
                    "MessageSend", Destination="mobile:" + DEVICE, To=to,
                    From=SIP_USER,
                    Base64Body=base64.b64encode(text.encode()).decode()))
                ok = "Success" in resp.get("Response", "")
                info = ('<p class="ok">SMS předána modemu (%s).</p>'
                        if ok else '<p class="bad">Odeslání selhalo: %s</p>') \
                    % esc(resp.get("Message", ""))
            except Exception as e:
                info = '<p class="bad">AMI chyba: %s</p>' % esc(e)
            return self._html(page_sms(info))
        if self.path == "/net/authkey" and TS_DIR:
            key = form.get("authkey", "").strip()
            # auth klíče: base64-like tokeny (headscale hskey-auth-…)
            if not re.match(r"^[A-Za-z0-9_-]{20,200}$", key):
                return self._html(page_net('<p class="bad">Tohle nevypadá jako auth klíč.</p>'))
            try:
                path = os.path.join(TS_DIR, "authkey")
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as f:
                    f.write(key)
                info = '<p class="ok">Klíč uložen — připojuji do privátní sítě.</p>'
            except OSError as e:
                info = '<p class="bad">Nejde uložit klíč: %s</p>' % esc(e)
            return self._html(page_net(info))
        if self.path == "/diag/at":
            cmd = form.get("cmd", "").strip()
            if not cmd.upper().startswith("AT") or "CUSBPIDSWITCH" in cmd.upper():
                return self._html(page_diag('<p class="bad">Povolené jsou jen AT příkazy (a CUSBPIDSWITCH nikdy).</p>'))
            out = cli("quectel cmd %s %s" % (DEVICE, cmd))
            return self._html(page_diag('<p class="ok">%s</p>' % esc(out)))
        self._html("<p>404</p>", 404)

    def log_message(self, fmt, *args):  # ať nespamuje stdout za každý request
        pass


def main():
    if not WEBUI_PASSWORD:
        raise SystemExit("WEBUI_PASSWORD není nastavené — odmítám startovat bez auth.")
    srv = ThreadingHTTPServer(("0.0.0.0", WEBUI_PORT), Handler)
    print("gsm2sip-webui na :%d" % WEBUI_PORT, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
