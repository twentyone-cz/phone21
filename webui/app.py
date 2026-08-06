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
# Jméno účtu zobrazené v softphonu (přihlašovací jméno zůstává interní)
ACCOUNT_LABEL = os.environ.get("ACCOUNT_LABEL", "myGSM")
# UI režim: "expert" = technické záložky (Docker/LXC default),
# "gui" = spotřebitelský dashboard (Umbrel appka) s technikou pod Pokročilé.
UI_MODE = os.environ.get("UI_MODE", "expert")
GUI = UI_MODE == "gui"
# Provisioning pro softphone: běží na vlastním portu BEZ hesla (jinak by si
# Linphone konfiguraci nestáhl) — chrání ho jednorázový token s krátkou
# platností. Port se publikuje přímo, ne přes proxy s přihlášením.
PROV_PORT = int(os.environ.get("PROV_PORT", "8091"))
# Prefix pro interní odkazy (kdyby UI běželo za proxy pod cestou)
BASE = os.environ.get("BASE_PATH", "").rstrip("/")


def u(path):
    return BASE + path

PROV_TTL = 600


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
            raise AmiError("přihlášení odmítnuto: %s" % resp.get("Message"))

    def _read_until(self, marker):
        while marker not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise AmiError("spojení ukončeno")
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
        return "Chyba spojení s telefonní částí: %s" % e


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


_prov_tokens = {}          # token -> (expiruje, použito)
_prov_lock = threading.Lock()


_PROV_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # bez záměnitelných znaků


def prov_new_token():
    """Jednorázový token pro stažení konfigurace softphonem. Krátký schválně
    — když skener QR nefunguje, musí jít URL opsat z obrazovky."""
    import secrets as _s
    token = "".join(_s.choice(_PROV_ALPHABET) for _ in range(8))
    with _prov_lock:
        now = time.time()
        for t, (exp, _used) in list(_prov_tokens.items()):
            if exp < now:
                del _prov_tokens[t]
        _prov_tokens[token] = (now + PROV_TTL, False)
    return token


def prov_claim(token):
    """Ověří a spotřebuje token (jedno stažení)."""
    with _prov_lock:
        entry = _prov_tokens.get(token)
        if not entry or entry[0] < time.time() or entry[1]:
            return False
        _prov_tokens[token] = (entry[0], True)
        return True


def prov_xml(domain):
    """Konfigurace účtu pro Linphone (remote provisioning)."""
    sec = read_secrets()
    user = sec.get("SIP_USER", SIP_USER)
    password = sec.get("SIP_PASSWORD", "")
    ident = '&quot;%s&quot; &lt;sip:%s@%s&gt;' % (
        html.escape(ACCOUNT_LABEL), html.escape(user), html.escape(domain))
    return """<?xml version="1.0" encoding="UTF-8"?>
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd">
  <section name="proxy_0">
    <entry name="reg_proxy">&lt;sip:%(domain)s;transport=udp&gt;</entry>
    <entry name="reg_identity">%(ident)s</entry>
    <entry name="reg_display_name">%(label)s</entry>
    <entry name="reg_expires">600</entry>
    <entry name="reg_sendregister">1</entry>
    <entry name="publish">0</entry>
    <entry name="dial_escape_plus">0</entry>
  </section>
  <section name="auth_info_0">
    <entry name="username">%(user)s</entry>
    <entry name="userid">%(user)s</entry>
    <entry name="passwd">%(passwd)s</entry>
    <entry name="domain">%(domain)s</entry>
  </section>
  <section name="video">
    <entry name="capture">0</entry>
    <entry name="display">0</entry>
    <entry name="automatically_initiate">0</entry>
    <entry name="automatically_accept">0</entry>
  </section>
  <section name="sip">
    <entry name="register_only_when_network_is_up">1</entry>
  </section>
</config>
""" % {"domain": html.escape(domain), "ident": ident,
       "label": html.escape(ACCOUNT_LABEL),
       "user": html.escape(user), "passwd": html.escape(password)}


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


def get_island_mode():
    """Ostrovní režim: při výpadku primární linky vezme krabička internet
    z mobilních dat modemu. Default vypnuto (data se účtují)."""
    out = cli("database get gsm2sip island_mode")
    for ln in out.splitlines():
        if ln.startswith("Value:"):
            return "on" if ln.split(":", 1)[1].strip() == "on" else "off"
    return "off"


def volte_state():
    """registered / not-registered / unknown — plní ho asterisk kontejner
    (qmicli --imsa-get-ims-registration-status) každou minutu."""
    try:
        val = open(os.path.join(DATA_DIR, "volte")).read().strip()
    except OSError:
        return "unknown"
    return val if val in ("registered", "not-registered") else "unknown"


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
    except OSError:
        pass  # nečitelná data nesmí shodit stránku
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
    except OSError:
        pass
    return items


def read_watchdog(n=5):
    """Poslední záznamy watchdogu. Restarty brány jsou jinak neviditelné —
    telefon se prostě odregistruje a není poznat proč."""
    try:
        with open(os.path.join(DATA_DIR, "watchdog.log"), "rb") as f:
            return [ln.decode(errors="replace").rstrip()
                    for ln in f.readlines()[-n:]]
    except OSError:
        return []


def tail_log(n=120):
    try:
        with open(LOG_FILE, "rb") as f:
            return b"\n".join(f.readlines()[-n:]).decode(errors="replace")
    except OSError:
        return "(log %s není k dispozici)" % LOG_FILE


# Vzhled: gui = produktový (jednadvacet), expert = utilitární
ACCENT = "#F7931A" if GUI else "#7fb069"

PAGE = """<!doctype html><html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{brand_plain}</title><style>
:root { --acc: ACCENT_COLOR; --bg:#0e1116; --surface:#161b22; --surface2:#1c2230;
  --fg:#e7edf3; --muted:#96a1ae; --line:#242c38; --ok:#3fb950; --warn:#d29922;
  --bad:#f85149; --r:14px; }
@media (prefers-color-scheme: light) {
  :root { --bg:#f7f8fa; --surface:#fff; --surface2:#f0f2f5; --fg:#12161c;
          --muted:#5b6672; --line:#e3e7ec; }
}
* { box-sizing:border-box }
body { margin:0; background:var(--bg); color:var(--fg); line-height:1.6;
  font-family:system-ui,-apple-system,"Segoe UI",sans-serif }
a { color:var(--acc); text-decoration:none } a:hover { text-decoration:underline }
nav { display:flex; align-items:center; gap:.25rem; flex-wrap:wrap;
  padding:.7rem 1rem; background:var(--surface); border-bottom:1px solid var(--line);
  position:sticky; top:0; z-index:10 }
nav .brand { color:var(--fg); margin-right:1rem; font-size:1.05rem }
nav .brand b { font-weight:800; color:var(--acc) }
nav a { color:var(--muted); font-weight:600; font-size:.94rem; padding:.4rem .75rem;
  border-radius:99px }
nav a:hover { background:var(--surface2); color:var(--fg); text-decoration:none }
nav a.act { background:var(--acc); color:#0e1116 }
nav a.off { opacity:.4; pointer-events:none }
main { padding:1.25rem 1rem 3rem; max-width:60rem; margin:auto }
h1 { font-size:1.5rem; letter-spacing:-.02em; margin:.2rem 0 1rem }
h2 { font-size:1.05rem; margin:1.8rem 0 .6rem }
.tiles { display:grid; gap:.9rem; margin:1rem 0;
  grid-template-columns:repeat(auto-fit,minmax(15rem,1fr)) }
.tile,.card { background:var(--surface); border:1px solid var(--line);
  border-radius:var(--r); padding:1rem 1.1rem }
.tile h3 { margin:0 0 .5rem; font-size:.78rem; font-weight:700; color:var(--muted);
  text-transform:uppercase; letter-spacing:.06em }
.tile .big { font-size:1.3rem; font-weight:700; letter-spacing:-.02em }
.tile small,.muted { color:var(--muted); font-size:.87rem }
.ok { color:var(--ok) } .bad { color:var(--bad) } .warn { color:var(--warn) }
.dot { display:inline-block; width:.5rem; height:.5rem; border-radius:50%;
  margin-right:.45rem; vertical-align:.1em; background:var(--muted) }
.dot.ok { background:var(--ok) } .dot.warn { background:var(--warn) }
.dot.bad { background:var(--bad) }
pre { background:var(--surface2); border:1px solid var(--line); border-radius:var(--r);
  padding:.85rem 1rem; overflow-x:auto; font-size:.82rem; line-height:1.45 }
table { border-collapse:collapse; width:100%; font-size:.92rem; margin:.6rem 0 }
td,th { text-align:left; padding:.55rem .6rem; border-bottom:1px solid var(--line);
  vertical-align:top }
th { color:var(--muted); font-size:.75rem; text-transform:uppercase;
  letter-spacing:.05em }
form.inline { display:flex; gap:.6rem; flex-wrap:wrap; align-items:center; margin:.8rem 0 }
input,select,textarea { background:var(--bg); color:var(--fg); border:1px solid var(--line);
  border-radius:10px; padding:.6rem .75rem; font:inherit; font-size:.95rem }
input:focus,select:focus { outline:2px solid var(--acc); outline-offset:1px }
button,.btn { background:var(--acc); color:#0e1116; border:0; border-radius:10px;
  padding:.6rem 1.1rem; font:inherit; font-weight:700; cursor:pointer;
  display:inline-block }
button:hover,.btn:hover { filter:brightness(1.08); text-decoration:none }
button.ghost { background:var(--surface2); color:var(--fg); border:1px solid var(--line) }
.choice { display:flex; gap:.7rem; align-items:flex-start; padding:.75rem .9rem;
  border:1px solid var(--line); border-radius:12px; margin:.45rem 0; cursor:pointer }
.choice:hover { border-color:var(--acc) }
.choice input { accent-color:var(--acc); margin:.3rem 0 0; width:auto }
.choice span { color:var(--muted); font-size:.87rem }
.choice span b { display:block; color:var(--fg); font-size:.95rem; margin-bottom:.1rem }
.qr { background:#fff; padding:14px; border-radius:var(--r); display:inline-block;
  line-height:0 }
.qr img,.qr canvas { display:block; max-width:100%; height:auto }
.badge { display:inline-block; background:var(--surface2); color:var(--muted);
  border:1px solid var(--line); border-radius:99px; padding:.1rem .6rem;
  font-size:.72rem; font-weight:700; text-transform:uppercase }
.mono { font-family:ui-monospace,SFMono-Regular,Menlo,monospace }
details { margin:1rem 0 } summary { cursor:pointer; color:var(--muted); font-weight:600 }
footer { text-align:center; color:var(--muted); font-size:.8rem; padding:1.5rem 1rem }
</style></head><body>
<nav><span class="brand">{brand}</span>{nav}</nav>
<main>{body}</main>
<footer>jen LAN / privátní síť · {now}</footer>
{extra}</body></html>"""
PAGE = PAGE.replace("ACCENT_COLOR", ACCENT)


def render(active, body, extra=""):
    """Telefon je dostupný, až když krabička visí v privátní síti — dřív by
    nastavení stejně nefungovalo."""
    ready = bool(ts_ip()) if TS_DIR else True
    if GUI:
        tabs = [(u("/"), "home", "Domů", True), (u("/sms"), "sms", "Zprávy", True),
                (u("/telefon"), "phone", "Telefon", ready)]
        if TS_DIR:
            tabs.append((u("/net"), "net", "Síť", True))
        tabs.append((u("/stav"), "status", "Pokročilé", True))
        brand = "<b>Phone21</b>"
    else:
        tabs = [(u("/"), "status", "Stav", True), (u("/sms"), "sms", "SMS", True),
                (u("/telefon"), "phone", "Telefon", ready)]
        if TS_DIR:
            tabs.append((u("/net"), "net", "Síť", True))
        tabs.append((u("/diag"), "diag", "Diagnostika", True))
        brand = "<b>Phone21</b>"
    nav = ""
    for href, key, label, enabled in tabs:
        cls = "act" if active == key else ("" if enabled else "off")
        tip = "" if enabled else ' title="nejdřív připoj krabičku do privátní sítě"'
        nav += '<a href="%s" class="%s"%s>%s</a>' % (href, cls, tip, label)
    out = PAGE
    for key, val in (("{nav}", nav), ("{brand}", brand), ("{body}", body),
                     ("{extra}", extra), ("{brand_plain}", "Phone21"),
                     ("{now}", time.strftime("%d.%m. %H:%M"))):
        out = out.replace(key, val)
    return out


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
    if out.startswith("Chyba spojení s telefonní částí"):
        return None
    d = {}
    for ln in out.splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            d[k.strip()] = v.strip()
    return d


def _tile(icon, title, value, cls, note):
    return ('<div class="tile"><h3>%s %s</h3><div class="big %s">%s</div>'
            "<small>%s</small></div>") % (icon, title, cls, value, note)


def _choice(name, value, cur, title, note):
    return ('<label class="choice"><input type="radio" name="%s" value="%s"%s>'
            "<span><b>%s</b>%s</span></label>") % (
        name, value, " checked" if cur == value else "", title, note)


def page_home(info=""):
    """GUI režim (Umbrel): spotřebitelský dashboard místo technických výpisů."""
    tiles = []
    m = modem_summary()
    if m and m.get("State") == "Free":
        tiles.append(_tile(
            "\U0001F4F6", "Mobilní síť", "Připojeno", "ok",
            "%s · %s%s · signál %s" % (esc(m.get("Provider Name", "?")),
                                       esc(m.get("Access technology", "?")),
                                       " + VoLTE" if volte_state() == "registered"
                                       else "",
                                       esc(m.get("RSSI", "?")))))
    elif m and m.get("State"):
        tiles.append(_tile(
            "\U0001F4F6", "Mobilní síť", esc(m.get("State")), "warn",
            "modem se připojuje — chvíli to trvá; zkontroluj SIM a anténu"))
    else:
        tiles.append(_tile(
            "\U0001F4F6", "Mobilní síť", "Neznámý stav", "bad",
            'nelze se zeptat ústředny — detail v <a href="%s">Pokročilé</a>'
            % u("/stav")))
    ip = ts_ip()
    if ip:
        tiles.append(_tile(
            "\U0001F512", "Privátní síť", "Připojeno", "ok",
            'adresa krabičky <span class="mono">%s</span> · '
            '<a href="%s">detail</a>' % (esc(ip), u("/net"))))
    else:
        tiles.append(_tile(
            "\U0001F512", "Privátní síť", "Nepřipojeno", "warn",
            '<a href="%s">vlož klíč privátní sítě</a> — telefon se pak dovolá '
            "odkudkoli" % u("/net")))
    sec = read_secrets()
    if ip and sec.get("SIP_USER"):
        tiles.append(_tile(
            "\U0001F4F1", "Telefon", "Připraveno", "ok",
            '<a href="%s">načti QR do aplikace Phone21</a> · '
            '<a href="https://phone.twentyone.cz/instalace" target="_blank">'
            "návod</a>" % u("/telefon")))
    else:
        tiles.append(_tile(
            "\U0001F4F1", "Telefon", "Čeká", "warn",
            "nejdřív připoj krabičku do privátní sítě"))
    rows = read_journal(limit=5)
    last = rows[0] if rows else None
    tiles.append(_tile(
        "\U0001F4AC", "Poslední zpráva",
        esc(last["from"]) if last else "—", "",
        "%s · <a href=\"%s\">všechny zprávy</a>"
        % (esc(last["msg"][:60]) if last else "zatím žádné", u("/sms"))))

    mode = get_missed_mode()
    missed = (
        '<form method="post" action="%s">'
        "%s%s"
        '<button style="margin-top:.5rem">Uložit</button></form>' % (
            u("/missed-mode"),
            _choice("mode", "ring", mode, "Vyzvánět naprázdno",
                    "Telefon zvoní ~30 s a nikdo to nezvedne. Volajícímu se "
                    "nic neúčtuje."),
            _choice("mode", "announce", mode, "Přehrát hlášku nedostupnosti",
                    "Hovor se přijme a řekne, že jsi nedostupný — volajícímu "
                    "se může účtovat.")))

    island = get_island_mode()
    volte = volte_state()
    if volte == "registered":
        islandnote = ('<p class="muted"><span class="dot ok"></span>Modem má '
                      "VoLTE, takže data jedou i během hovoru.</p>")
    elif volte == "not-registered":
        islandnote = ('<p class="muted"><span class="dot warn"></span>Modem '
                      "teď nemá VoLTE. Náhradní připojení proto během hovoru "
                      "vypadne a naskočí až po jeho skončení — jako záloha "
                      "pro krátké výpadky to stačí, na hovory v ostrovním "
                      "režimu spoléhat nejde.</p>")
    else:
        islandnote = ""
    islandform = (
        '<form method="post" action="%s">'
        "%s%s"
        '<button style="margin-top:.5rem">Uložit</button></form>' % (
            u("/island-mode"),
            _choice("island", "off", island, "Vypnuto (doporučeno)",
                    "Krabička jede jen po domácí lince. Mobilní data se "
                    "nepoužijí."),
            _choice("island", "on", island, "Zapnuto",
                    "Když domácí připojení vypadne, krabička si vezme "
                    "internet z mobilních dat SIM. Data se účtují podle "
                    "tarifu.")))

    return render("home", (
        '%s<h1>Přehled</h1><div class="tiles">%s</div>'
        '<div class="tiles" style="margin-top:1.6rem">'
        '<div class="card"><h2 style="margin-top:0">Když nejsi k zastižení</h2>'
        "<p class=\"muted\">Zmeškaný hovor ti vždycky přijde jako zpráva do "
        "chatu. Tohle určuje, co uslyší volající:</p>%s</div>"
        '<div class="card"><h2 style="margin-top:0">Ostrovní režim</h2>'
        "<p class=\"muted\">Záloha internetu z mobilních dat, když vypadne "
        "linka:</p>%s%s</div></div>"
    ) % (info, "".join(tiles), missed, islandform, islandnote))


def page_status(mode_info=""):
    """Expert režim = domovská stránka, GUI režim = záložka Pokročilé.
    Nastavení (zmeškané hovory, ostrovní režim) žije v GUI na dashboardu,
    tady se v GUI neopakuje."""
    dev = cli("quectel show devices")
    state = cli("quectel show device state " + DEVICE)
    contacts = cli("pjsip show contacts")
    chans = cli("core show channels")
    q = read_queue()
    qbadge = ('<span class="warn"><span class="dot warn"></span>%d SMS čeká ve '
              "frontě</span>" % len(q)) if q else \
        '<span class="ok"><span class="dot ok"></span>fronta prázdná</span>'
    wd = read_watchdog()
    wdblock = ("<pre>%s</pre>" % esc("\n".join(wd))) if wd else \
        '<p><span class="ok"><span class="dot ok"></span>watchdog zatím nikdy ' \
        "nezasáhl</span></p>"
    body = (
        "<h1>%s</h1>"
        "<h2>Modem</h2><pre>%s</pre>"
        "<h2>Detail zařízení</h2><pre>%s</pre>"
        "<h2>Připojení telefonu</h2><pre>%s</pre>"
        "<h2>Hovory</h2><pre>%s</pre>"
        "<h2>SMS fronta</h2><p>%s</p>"
        "<h2>Watchdog modemu</h2>%s"
    ) % ("Pokročilé" if GUI else "Stav brány",
         esc(dev), esc(state), esc(contacts), esc(chans), qbadge, wdblock)
    if not GUI:
        mode = get_missed_mode()
        island = get_island_mode()
        body += (
            "<h2>Nedostupný telefon — chování k volajícímu</h2>%s"
            '<form method="post" action="%s">%s%s'
            '<button style="margin-top:.5rem">Uložit</button></form>'
            '<p class="muted">Zmeškaný hovor při offline telefonu vždy pošle '
            "notifikaci do chatu (od čísla volajícího), doručí se po "
            "znovupřipojení.</p>"
            "<h2>Ostrovní režim</h2>"
            '<form method="post" action="%s">%s%s'
            '<button style="margin-top:.5rem">Uložit</button></form>'
        ) % (mode_info, u("/missed-mode"),
             _choice("mode", "ring", mode, "Vyzvánět naprázdno",
                     "~30 s, hovor se nepřijme, volajícímu se neúčtuje"),
             _choice("mode", "announce", mode, "Hláska nedostupnosti",
                     "hovor se přijme — volajícímu se může účtovat"),
             u("/island-mode"),
             _choice("island", "off", island, "Vypnuto",
                     "jen primární linka, mobilní data se nepoužijí"),
             _choice("island", "on", island, "Zapnuto",
                     "při výpadku linky default route přes datové rozhraní "
                     "modemu (data se účtují)"))
        body += ('<p class="muted">IMS/VoLTE: <b>%s</b>%s</p>' % (
            esc(volte_state()),
            "" if volte_state() == "registered" else
            " — bez VoLTE jde hovor CSFB do 2G a datové spojení na tu dobu "
            "padá; hlídka ho po hovoru postaví znovu."))
    body += '<p><button class="ghost" onclick="location.reload()">Obnovit</button></p>'
    return render("status", body)


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
        "%s<h1>Zprávy</h1><h2>Poslat SMS</h2>"
        '<form class="inline" method="post" action="' + u("/sms/send") + '">'
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
    # zákaznická doména; cockscale.twentyone.cz je jen technická adresa
    # koordinátora (COCKSCALE_URL) a zákazník ji nemá vidět
    dash = os.environ.get("NET_DASHBOARD_URL", "https://phone.twentyone.cz/pay")
    blocks = [info, "<h1>Privátní síť</h1>"]
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
        '<form class="inline" method="post" action="%s">'
        '<input name="authkey" placeholder="hskey-auth-..." size="40" required>'
        "<button>Připojit</button></form>"
        % ("Nové připojení / obnova po expiraci — vlož" if ip else
           "Brána zatím není v privátní síti. Vlož", esc(dash),
           u("/net/authkey")))
    if ip:
        blocks.append(
            '<p>Krabička je v síti — teď připoj telefon na záložce '
            '<a href="%s">Telefon</a>.</p>' % u("/telefon"))
    return render("net", "".join(blocks))


def page_phone(info=""):
    """Připojení softphonu: QR pro Linphone + ruční údaje."""
    sec = read_secrets()
    ip = ts_ip()
    blocks = [info, "<h1>Telefon</h1>"]
    if not sec.get("SIP_USER"):
        blocks.append('<p class="bad">Nejde přečíst přihlašovací údaje '
                      "brány — zkus restartovat aplikaci.</p>")
        return render("phone", "".join(blocks))
    if not ip:
        blocks.append(
            '<p class="warn">Krabička zatím není v privátní síti, takže se '
            "k ní telefon zvenku nedovolá. Připoj ji na záložce "
            '<a href="%s">Síť</a> — pak se sem vrať.</p>' % u("/net"))
    blocks.append(
        "<p>Do telefonu si nainstaluj aplikaci <b>Phone21</b> a naskenuj kód — "
        "účet, heslo i adresa miniserveru se nastaví samy:</p>"
        '<form class="inline" method="post" action="%s">'
        "<button>Zobrazit QR pro Phone21</button></form>"
        "<p class=\"small muted\">Návod krok za krokem: "
        '<a href="https://phone.twentyone.cz/instalace" target="_blank">'
        "phone.twentyone.cz/instalace</a></p>"
        "<details><summary>Nastavit ručně</summary>"
        "<table><tr><th>Uživatel</th><td>%s</td></tr>"
        "<tr><th>Heslo</th><td><code>%s</code></td></tr>"
        "<tr><th>Doména / server</th><td>%s</td></tr>"
        "<tr><th>Transport</th><td>UDP</td></tr></table>"
        "<p class=\"small muted\">V nastavení hovorů vypni video a nech jen "
        "kodeky PCMA/PCMU; aplikaci povol běh na pozadí (baterie: neomezeno), "
        "jinak tě hovor nemusí dozvonit.</p></details>"
        % (u("/telefon/qr"), esc(sec["SIP_USER"]),
           esc(sec.get("SIP_PASSWORD", "")), esc(ip or "—")))
    return render("phone", "".join(blocks))


def page_qr(url):
    """QR s odkazem na konfiguraci. Kód nese schéma linphone-config:, které
    otevře appku rovnou — přečte ho i vestavěný skener Linphonu i systémový
    fotoaparát (ověřeno na GrapheneOS i Samsungu)."""
    body = """<h1>Připojení telefonu</h1>
<p>Nejdřív si v telefonu nainstaluj aplikaci <b>Phone21</b>. Pak naskenuj kód —
buď skenerem v aplikaci (Přidat účet → <b>Scan QR code</b>), nebo běžným
fotoaparátem telefonu; obojí appku nastaví samo.</p>
<div id="qr" class="qr"></div>

<details><summary>Když skener nespolupracuje</summary>
<p>V aplikaci: <b>Nastavení → Pokročilá nastavení → Remote provisioning
URL</b> → vlož tenhle odkaz a dej <b>Download &amp; apply</b>:</p>
<p class="mono" style="font-size:1.15rem;letter-spacing:.02em">%s</p></details>

<p class="muted">Odkaz platí <b>10 minut</b> a jen na jedno použití;
obsahuje heslo k účtu, takže ho nikam nepřeposílej. Když vyprší nebo se
nepovede, vrať se a vygeneruj si nový.</p>
<p><a href="%s">Zpět</a></p>""" % (esc(url), u("/telefon"))
    extra = """<script src="%s"></script><script>
new QRCode(document.getElementById("qr"), {text: %s, width: 280, height: 280,
  correctLevel: QRCode.CorrectLevel.L});
</script>""" % (u("/static/qrcode.min.js"),
                json.dumps("linphone-config:" + url))
    return render("phone", body, extra)


def page_diag(at_info=""):
    return render("diag", (
        "%s<h2>AT příkaz</h2>"
        '<form class="inline" method="post" action="' + u("/diag/at") + '">'
        '<input name="cmd" placeholder="AT+CSQ" required size="30">'
        "<button>Poslat</button></form>"
        "<small>Odpověď dorazí asynchronně — objeví se v logu níže "
        "(Got Response). Pozor, některé AT příkazy modem rozbijí.</small>"
        "<h2>Záznam telefonní části</h2><pre>%s</pre>"
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
        self.send_header("WWW-Authenticate", 'Basic realm="Phone21"')
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
        if self.path == "/telefon":
            return self._html(page_phone())
        if self.path == "/net" and TS_DIR:
            return self._html(page_net())
        if self.path.startswith("/static/"):
            return self.get_static(self.path)
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
                else '<p class="bad">Zápis se nepotvrdil — zkontroluj spojení s telefonní částí.</p>'
            return self._html(page(info))
        if self.path == "/island-mode":
            page = page_home if GUI else page_status
            want = form.get("island", "")
            if want not in ("on", "off"):
                return self._html(page('<p class="bad">Neplatná volba.</p>'))
            # Smyčka wwan.sh watch se na tenhle klíč ptá před každým cyklem,
            # takže přepnutí se projeví do jednoho intervalu bez restartu.
            cli("database put gsm2sip island_mode " + want)
            saved = get_island_mode()
            info = ('<p class="ok">Ostrovní režim: %s.</p>'
                    % ("zapnuto" if saved == "on" else "vypnuto")) \
                if saved == want else \
                '<p class="bad">Zápis se nepotvrdil — zkontroluj spojení s telefonní částí.</p>'
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
                info = '<p class="bad">Chyba spojení s telefonní částí: %s</p>' % esc(e)
            return self._html(page_sms(info))
        if self.path == "/telefon/qr":
            ip = ts_ip()
            if not ip:
                return self._html(page_phone(
                    '<p class="bad">Nejdřív připoj krabičku do privátní sítě '
                    "(záložka Síť).</p>"))
            url = "http://%s:%d/p/%s" % (ip, PROV_PORT, prov_new_token())
            return self._html(page_qr(url))
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

    def get_static(self, path):
        name = os.path.basename(path)
        fpath = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "static", name)
        ctypes = {".css": "text/css", ".js": "application/javascript"}
        ext = os.path.splitext(name)[1]
        if ext not in ctypes or not os.path.isfile(fpath):
            return self._html("<p>404</p>", 404)
        with open(fpath, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", ctypes[ext])
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):  # ať nespamuje stdout za každý request
        pass


class ProvHandler(BaseHTTPRequestHandler):
    """Jediný účel: vydat konfiguraci softphonu na jednorázový token.
    Běží bez hesla (Linphone se neumí přihlásit), takže nic jiného neobsluhuje."""
    server_version = "gsm2sip-prov"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.startswith("/p/"):
            token = path[3:]
        elif path.startswith("/prov/") and path.endswith(".xml"):
            token = path[len("/prov/"):-len(".xml")]
        else:
            token = ""
        ip = ts_ip()
        if not token or not ip or not prov_claim(token):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        data = prov_xml(ip).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/xml; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    if not WEBUI_PASSWORD:
        raise SystemExit("WEBUI_PASSWORD není nastavené — odmítám startovat bez auth.")
    if TS_DIR:
        prov = ThreadingHTTPServer(("0.0.0.0", PROV_PORT), ProvHandler)
        threading.Thread(target=prov.serve_forever, daemon=True).start()
        print("provisioning softphonu na :%d" % PROV_PORT, flush=True)
    srv = ThreadingHTTPServer(("0.0.0.0", WEBUI_PORT), Handler)
    print("gsm2sip-webui na :%d" % WEBUI_PORT, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
