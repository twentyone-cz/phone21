#!/usr/bin/env python3
"""Phone21 web UI — správa a diagnostika brány.

Čistá stdlib (žádné závislosti). Mluví s Asteriskem přes AMI (localhost),
žurnál/frontu SMS čte z /var/lib/phone21. Basic auth (WEBUI_PASSWORD).
Určeno výhradně pro LAN/privátní síť — nikdy nevystavovat veřejně.
"""

import base64
import hashlib
import html
import json
import os
import re
import fcntl
import hmac
import socket
import struct
import threading
import time
import urllib.error
import urllib.request
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AMI_HOST = os.environ.get("AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("AMI_PORT", "5038"))
AMI_USER = os.environ.get("AMI_USER", "phone21-ui")
AMI_PASSWORD = os.environ.get("AMI_PASSWORD", "")
WEBUI_PASSWORD = os.environ.get("WEBUI_PASSWORD", "")
WEBUI_PORT = int(os.environ.get("WEBUI_PORT", "8090"))
SIP_USER = os.environ.get("SIP_USER", "softphone")
DATA_DIR = os.environ.get("PHONE21_DATA",
                          os.environ.get("GSM2SIP_DATA", "/var/lib/phone21"))
# Stav ovládání (tajemství 2FA, token brány). DATA_DIR je pro ovládání
# READ-ONLY mount — zapisovat jde jedině sem (samostatný rw mount, adresář
# zakládá entrypoint ústředny). Zápis kamkoli jinam v DATA_DIR selže.
STATE_DIR = os.environ.get("WEBUI_STATE", os.path.join(DATA_DIR, "webui"))
LOG_FILE = os.environ.get("ASTERISK_LOG", "/var/log/asterisk/messages.log")
DEVICE = os.environ.get("QUECTEL_DEVICE", "quectel0")
COUNTRY_CODE = os.environ.get("COUNTRY_CODE", "420")
# Umbrel režim: tajemství generuje entrypoint asterisku do sdíleného souboru
# (AMI_PASSWORD env pak není nastavené) a privátní síť se ovládá přes TS_DIR.
AMI_SECRETS_FILE = os.environ.get("AMI_SECRETS_FILE", "")
TS_DIR = os.environ.get("TS_DIR", "")
# --- Kontakty a kalendář (server pro synchronizaci) --------------------------
DAV_URL = os.environ.get("DAV_URL", "")
DAV_DIR = os.environ.get("DAV_DIR", "")
DAV_PORT = os.environ.get("DAV_PORT", "5232")
DAV_ADMIN = "_phone21"
DAV_BOOK = "kontakty"
DAV_CAL = "kalendar"
DAV_USER_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{1,31}$")
DAV_IMPORT_MAX = 20 * 1024 * 1024
try:
    import bcrypt as _bcrypt
except ImportError:
    _bcrypt = None
DAV_ENABLED = bool(DAV_URL and DAV_DIR and _bcrypt)
_dav_lock = threading.Lock()
_dav_import = {"running": False, "done": 0, "skipped": 0, "failed": 0,
               "total": 0, "errors": [], "kind": ""}

# Jméno účtu zobrazené v softphonu (přihlašovací jméno zůstává interní)
ACCOUNT_LABEL = os.environ.get("ACCOUNT_LABEL", "myGSM")
# UI režim: "expert" = technické záložky (Docker/LXC default),
# "gui" = spotřebitelský dashboard (Umbrel appka) s technikou pod Pokročilé.
UI_MODE = os.environ.get("UI_MODE", "expert")
GUI = UI_MODE == "gui"
# Nastavení telefonu: běží na vlastním portu bez hesla, chrání ho
# jednorázový token s krátkou platností.
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

# Poslední stažení konfigurace telefonem — záložka Telefon z něj ukáže,
# jestli si telefon XML vzal a jestli k účtu dostal i klíč do sítě.
_prov_last = {"t": 0.0, "err": "", "key": False}


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
        _prov_tokens[token] = (now + PROV_TTL, 0.0)
    return token


def prov_claim(token):
    """Ověří token. Po prvním stažení zůstává platný ještě 90 s — fotoaparáty
    a prohlížeče si odkaz z QR často „předstáhnou" pro náhled, čímž by čistě
    jednorázový token spálily dřív, než si konfiguraci vezme aplikace."""
    with _prov_lock:
        entry = _prov_tokens.get(token)
        if not entry or entry[0] < time.time():
            return False
        expires, first_claim = entry
        now = time.time()
        if first_claim and now - first_claim > 90:
            return False
        if not first_claim:
            _prov_tokens[token] = (expires, now)
        return True


PARTNER_URL = os.environ.get("COCKSCALE_URL", "https://cockscale.twentyone.cz")


def partner_token_path():
    return os.path.join(STATE_DIR, "partner_token")


def debug_ssh_path():
    return os.path.join(STATE_DIR, "debug_ssh")


def debug_ssh_on():
    """Je zapnuté ladění (vzdálená správa z privátní sítě)?"""
    try:
        with open(debug_ssh_path()) as f:
            return f.read().strip() == "1"
    except OSError:
        return False


def firewall_state():
    """Stav filtru z privátní sítě, jak ho zapisuje ústředna."""
    try:
        with open(os.path.join(DATA_DIR, "firewall")) as f:
            return f.read().strip()
    except OSError:
        return ""


def write_state(path, data):
    """Atomický zápis stavu (0600, tmp+rename). Volající chytá OSError —
    na instalaci bez rw mountu STATE_DIR zápis selže a uživatel musí dostat
    čitelnou chybu, ne přerušené spojení."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(data)
    os.replace(tmp, path)


def audit(msg):
    """Bezpečnostní události do stdout (docker logs) — přihlášení, 2FA,
    servisní příkazy."""
    print("[audit] %s %s" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg),
          flush=True)


def read_partner_token():
    try:
        with open(partner_token_path()) as f:
            return f.read().strip()
    except OSError:
        return ""


def save_partner_token(token):
    write_state(partner_token_path(), token)


PARTNER_ERRORS = {
    "bad_token": "Token brány neplatí — vydej si nový v účtu sítě.",
    "no_credits": "Síť je pozastavená — v účtu chybí kredit.",
    "device_limit": "Vyčerpaný limit zařízení na účtu sítě.",
    "coordinator": "Koordinátor sítě teď neodpovídá, zkus to za chvíli.",
}


def request_network_key():
    """Vyžádá jednorázový klíč do privátní sítě pro telefon.
    Vrací (klíč, adresa_koordinátora, chyba_pro_uživatele)."""
    token = read_partner_token()
    if not token:
        return "", "", ""      # bez tokenu se prostě QR omezí na účet
    req = urllib.request.Request(
        PARTNER_URL.rstrip("/") + "/partner/preauthkeys", method="POST",
        headers={"Authorization": "Bearer " + token, "Content-Length": "0"})
    try:
        # telefon na konfiguraci čeká jen krátce — radši QR bez sítě
        # (a viditelná chyba) než aby to telefon vzdal dřív než my
        with urllib.request.urlopen(req, timeout=4) as resp:
            data = json.loads(resp.read())
        return data.get("key", ""), data.get("login_server", PARTNER_URL), ""
    except urllib.error.HTTPError as e:
        try:
            reason = json.loads(e.read()).get("error", "")
        except Exception:
            reason = ""
        if e.code == 429:
            return "", "", "Moc pokusů po sobě — zkus QR za minutu."
        return "", "", PARTNER_ERRORS.get(
            reason, "Klíč do sítě se nepodařilo získat (%d)." % e.code)
    except (urllib.error.URLError, OSError, ValueError) as e:
        return "", "", "Koordinátor sítě je nedostupný: %s" % e


def prov_xml(domain, ts_url="", ts_key=""):
    """Konfigurace účtu pro aplikaci v telefonu."""
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
  </section>%(network)s
</config>
""" % {"domain": html.escape(domain), "ident": ident,
       "label": html.escape(ACCOUNT_LABEL),
       "user": html.escape(user), "passwd": html.escape(password),
       "network": network_section(ts_url, ts_key)}


def network_section(ts_url, ts_key):
    """Přihlášení do privátní sítě přibalené k účtu — aplikace si podle něj
    postaví tunel dřív, než se pokusí o registraci. Klíč je jednorázový
    a platí hodinu."""
    if not (ts_url and ts_key):
        return ""
    return """
  <section name="twentyone">
    <entry name="ts_control_url">%s</entry>
    <entry name="ts_authkey">%s</entry>
  </section>""" % (html.escape(ts_url), html.escape(ts_key))


MISSED_MODES = ("ring", "announce")


def get_missed_mode():
    """Aktuální chování k volajícímu při offline telefonu (AstDB přes AMI).
    Prázdný/nečitelný klíč = default ring."""
    out = cli("database get phone21 missed_mode")
    for ln in out.splitlines():
        if ln.startswith("Value:"):
            val = ln.split(":", 1)[1].strip()
            if val in MISSED_MODES:
                return val
    return "ring"


def get_island_mode():
    """Ostrovní režim: při výpadku primární linky vezme krabička internet
    z mobilních dat modemu. Default vypnuto (data se účtují)."""
    out = cli("database get phone21 island_mode")
    for ln in out.splitlines():
        if ln.startswith("Value:"):
            return "on" if ln.split(":", 1)[1].strip() == "on" else "off"
    return "off"


def volte_state():
    """registered / not-registered / unknown — stav plní kontejner ústředny."""
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



# --- Kontakty a kalendář -----------------------------------------------------

def dav_users_path():
    return os.path.join(DAV_DIR, "users")


def dav_admin_path():
    return os.path.join(DAV_DIR, "admin")


def dav_read_users():
    """{jméno: hash} ze souboru účtů."""
    out = {}
    try:
        with open(dav_users_path()) as f:
            for line in f:
                line = line.strip()
                if not line or ":" not in line:
                    continue
                name, _, h = line.partition(":")
                out[name] = h
    except OSError:
        pass
    return out


def dav_write_users(users):
    data = "".join("%s:%s\n" % (n, h) for n, h in sorted(users.items()))
    write_state(dav_users_path(), data)


def dav_hash(password):
    return _bcrypt.hashpw(password.encode(), _bcrypt.gensalt(10)).decode()


def dav_new_password(groups=4):
    import secrets as _s
    return "-".join(
        "".join(_s.choice(_PROV_ALPHABET) for _ in range(4)) for _ in range(groups)
    )


def dav_admin_password():
    """Heslo interního správce; když chybí nebo neodpovídá, obnoví se."""
    try:
        with open(dav_admin_path()) as f:
            password = f.read().strip()
    except OSError:
        password = ""
    users = dav_read_users()
    if password and DAV_ADMIN in users:
        return password
    password = dav_new_password(6)
    users[DAV_ADMIN] = dav_hash(password)
    dav_write_users(users)
    write_state(dav_admin_path(), password)
    audit("dav admin heslo obnoveno")
    return password


def dav_request(method, path, body=None, ctype=None, headers=None):
    """Dotaz na úložiště jménem interního správce → (status, tělo)."""
    url = DAV_URL.rstrip("/") + path
    req = urllib.request.Request(url, data=body, method=method)
    token = base64.b64encode(
        ("%s:%s" % (DAV_ADMIN, dav_admin_password())).encode()
    ).decode()
    req.add_header("Authorization", "Basic " + token)
    if ctype:
        req.add_header("Content-Type", ctype)
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:
        return 0, str(e).encode()


MKCOL_BOOK = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<mkcol xmlns="DAV:" xmlns:CR="urn:ietf:params:xml:ns:carddav">'
    "<set><prop><resourcetype><collection/><CR:addressbook/></resourcetype>"
    "<displayname>Kontakty</displayname></prop></set></mkcol>"
)
MKCOL_CAL = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<mkcol xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">'
    "<set><prop><resourcetype><collection/><C:calendar/></resourcetype>"
    "<displayname>Kalendář</displayname>"
    "<C:supported-calendar-component-set>"
    '<C:comp name="VEVENT"/><C:comp name="VTODO"/><C:comp name="VJOURNAL"/>'
    "</C:supported-calendar-component-set></prop></set></mkcol>"
)


def dav_ensure_collections(user):
    """Založí adresář uživatele i kolekce; 405 = už existuje."""
    for path, body in (("/%s/" % user, None),
                       ("/%s/%s/" % (user, DAV_BOOK), MKCOL_BOOK),
                       ("/%s/%s/" % (user, DAV_CAL), MKCOL_CAL)):
        status, data = dav_request(
            "MKCOL", path,
            body.encode() if body else None,
            "application/xml; charset=utf-8" if body else None,
        )
        if status not in (201, 405):
            return False, "%s → %s %s" % (path, status, data[:120].decode(errors="replace"))
    return True, ""


def dav_user_add(name):
    users = dav_read_users()
    if name in users:
        return None, "[OVL-E25] Účet %s už existuje." % esc(name)
    password = dav_new_password()
    users[name] = dav_hash(password)
    dav_write_users(users)
    ok, detail = dav_ensure_collections(name)
    if not ok:
        return None, "[OVL-E26] Úložiště účet nepřijalo: %s" % esc(detail)
    audit("dav user ADD %s" % name)
    return password, ""


def dav_user_reset(name):
    users = dav_read_users()
    if name not in users:
        return None, "[OVL-E25] Účet %s neexistuje." % esc(name)
    password = dav_new_password()
    users[name] = dav_hash(password)
    dav_write_users(users)
    audit("dav user RESET %s" % name)
    return password, ""


def dav_user_del(name, drop_data=False):
    users = dav_read_users()
    if name not in users:
        return "[OVL-E25] Účet %s neexistuje." % esc(name)
    del users[name]
    dav_write_users(users)
    if drop_data:
        dav_request("DELETE", "/%s/" % name)
    audit("dav user DEL %s data=%s" % (name, drop_data))
    return ""


def split_vcards(text):
    """Rozdělí .vcf na jednotlivé vizitky; chybějící UID doplní."""
    out = []
    current = []
    for line in text.splitlines():
        if line.strip().upper().startswith("BEGIN:VCARD"):
            current = [line]
        elif current:
            current.append(line)
            if line.strip().upper().startswith("END:VCARD"):
                card = "\r\n".join(current)
                uid = ""
                for entry in current:
                    if entry.upper().startswith("UID:"):
                        uid = entry.split(":", 1)[1].strip()
                if not uid:
                    uid = "p21-" + hashlib.sha1(card.encode()).hexdigest()[:24]
                    card = card.replace("END:VCARD", "UID:%s\r\nEND:VCARD" % uid)
                out.append((uid, card))
                current = []
    return out


def split_ics(text):
    """Rozdělí .ics na položky podle UID (opakování sdílí UID)."""
    lines = text.splitlines()
    header = []
    timezones = []
    comps = {}
    order = []
    block = None
    kind = ""
    in_tz = False
    tz_block = []
    for line in lines:
        upper = line.strip().upper()
        if upper.startswith("BEGIN:VTIMEZONE"):
            in_tz = True
            tz_block = [line]
            continue
        if in_tz:
            tz_block.append(line)
            if upper.startswith("END:VTIMEZONE"):
                timezones.append("\r\n".join(tz_block))
                in_tz = False
            continue
        if upper.startswith("BEGIN:V") and not upper.startswith("BEGIN:VCALENDAR"):
            block = [line]
            kind = upper[len("BEGIN:"):]
            continue
        if block is not None:
            block.append(line)
            if upper.startswith("END:" + kind):
                uid = ""
                for entry in block:
                    if entry.upper().startswith("UID:"):
                        uid = entry.split(":", 1)[1].strip()
                if not uid:
                    uid = "p21-" + hashlib.sha1(
                        "\n".join(block).encode()).hexdigest()[:24]
                    block.insert(1, "UID:" + uid)
                if uid not in comps:
                    comps[uid] = []
                    order.append(uid)
                comps[uid].append("\r\n".join(block))
            continue
        if upper.startswith("BEGIN:VCALENDAR") or upper.startswith("VERSION:") \
                or upper.startswith("PRODID:") or upper.startswith("CALSCALE:"):
            header.append(line)
    if not header:
        header = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Phone21//import//CS"]
    out = []
    for uid in order:
        parts = list(header) + timezones + comps[uid] + ["END:VCALENDAR"]
        out.append((uid, "\r\n".join(parts)))
    return out


def dav_href(uid, suffix):
    safe = re.sub(r"[^A-Za-z0-9._-]", "-", uid)
    if len(safe) > 80:
        safe = hashlib.sha1(uid.encode()).hexdigest()
    return safe + suffix


def dav_import_run(user, kind, items):
    """Položky se ukládají po jedné; existující UID se přeskočí."""
    collection = DAV_BOOK if kind == "vcard" else DAV_CAL
    ctype = "text/vcard; charset=utf-8" if kind == "vcard" \
        else "text/calendar; charset=utf-8"
    suffix = ".vcf" if kind == "vcard" else ".ics"
    for uid, body in items:
        path = "/%s/%s/%s" % (user, collection, dav_href(uid, suffix))
        status, data = dav_request(
            "PUT", path, body.encode("utf-8"), ctype,
            {"If-None-Match": "*"},
        )
        with _dav_lock:
            if status in (201, 204):
                _dav_import["done"] += 1
            elif status == 412:
                _dav_import["skipped"] += 1
            else:
                _dav_import["failed"] += 1
                detail = data[:120].decode("utf-8", "replace").replace("\n", " ") \
                    if isinstance(data, bytes) else ""
                if len(_dav_import["errors"]) < 20:
                    _dav_import["errors"].append(
                        "%s → %s %s" % (uid[:40], status, detail))
                audit("dav import chyba %s status=%s %s" % (uid[:40], status, detail))
    with _dav_lock:
        _dav_import["running"] = False
    audit("dav import %s hotovo done=%d skip=%d fail=%d" % (
        kind, _dav_import["done"], _dav_import["skipped"], _dav_import["failed"]))


def dav_import_start(user, raw):
    """Rozpozná druh souboru a spustí import na pozadí."""
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        try:
            text = raw.decode("cp1250")
        except UnicodeDecodeError:
            return "[OVL-E27] Soubor není v čitelném kódování."
    upper = text.upper()
    if "BEGIN:VCARD" in upper:
        kind, items = "vcard", split_vcards(text)
    elif "BEGIN:VCALENDAR" in upper:
        kind, items = "ical", split_ics(text)
    else:
        return "[OVL-E27] Tohle není soubor s kontakty ani s kalendářem."
    if not items:
        return "[OVL-E27] V souboru není žádná položka."
    with _dav_lock:
        if _dav_import["running"]:
            return "[OVL-E29] Import už běží."
        _dav_import.update({"running": True, "done": 0, "skipped": 0,
                            "failed": 0, "total": len(items), "errors": [],
                            "kind": kind})
    audit("dav import start %s %d položek → %s" % (kind, len(items), user))
    threading.Thread(target=dav_import_run, args=(user, kind, items),
                     daemon=True).start()
    return ""


def dav_urls():
    """Adresy, na kterých je úložiště vidět (domácí síť, privátní síť)."""
    out = []
    lan = lan_ip()
    if lan:
        out.append(("domácí síť", "http://%s:%s/" % (lan, DAV_PORT)))
    tun = ts_ip()
    if tun:
        out.append(("privátní síť", "http://%s:%s/" % (tun, DAV_PORT)))
    return out

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
<footer>jen LAN / privátní síť · {now} · obrazovka {screen} · <a href="{twofa}">dvoufázové ověření</a> · <a href="{logout}">odhlásit</a></footer>
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
        if DAV_ENABLED:
            tabs.append((u("/dav"), "dav", "Kontakty a kalendář", True))
        tabs.append((u("/stav"), "status", "Pokročilé", True))
        brand = "<b>Phone21</b>"
    else:
        tabs = [(u("/"), "status", "Stav", True), (u("/sms"), "sms", "SMS", True),
                (u("/telefon"), "phone", "Telefon", ready)]
        if TS_DIR:
            tabs.append((u("/net"), "net", "Síť", True))
        if DAV_ENABLED:
            tabs.append((u("/dav"), "dav", "Kontakty a kalendář", True))
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
                     ("{screen}", "OVL-" + active.upper()),
                     ("{logout}", u("/logout")),
                     ("{twofa}", u("/2fa")),
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


def _iface_ipv4(name):
    """IPv4 adresa rozhraní (SIOCGIFADDR) — bez cizích knihoven."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        packed = fcntl.ioctl(sock.fileno(), 0x8915,
                             struct.pack("256s", name[:15].encode()))
        return socket.inet_ntoa(packed[20:24])
    except OSError:
        return ""
    finally:
        sock.close()


def default_route_iface():
    """Rozhraní s výchozí trasou z /proc/net/route. Trik s UDP spojením
    vracel adresu můstku dockeru (u umbrelu 10.21.x), což telefon v domácí
    síti nenajde."""
    try:
        with open("/proc/net/route") as f:
            for line in f.readlines()[1:]:
                cols = line.split()
                if len(cols) > 2 and cols[1] == "00000000":
                    return cols[0]
    except OSError:
        pass
    return ""


def lan_ip():
    """Adresa miniserveru v domácí síti. QR se stahuje DŘÍV, než je telefon
    v privátní síti, takže musí mířit na adresu, na kterou telefon dosáhne
    z běžné wifi.

    Přednost má soubor od kontejneru ústředny: ten běží v síti hostitele
    a vidí skutečná rozhraní. Ovládání je za mostem dockeru, takže samo
    zjistí jen vnitřní adresu (u umbrelu 10.21.x)."""
    try:
        with open(os.path.join(DATA_DIR, "lan_ip")) as f:
            addr = f.read().strip()
        if addr and not addr.startswith(("127.", "100.", "10.21.")):
            return addr
    except OSError:
        pass
    iface = default_route_iface()
    if iface and iface != "tailscale0":
        addr = _iface_ipv4(iface)
        if addr and not addr.startswith(("127.", "100.")):
            return addr
    # záloha: projít rozhraní a vzít první běžnou lokální adresu
    for _idx, name in socket.if_nameindex():
        if name.startswith(("lo", "docker", "br-", "veth", "tailscale")):
            continue
        addr = _iface_ipv4(name)
        if addr and not addr.startswith(("127.", "100.", "169.254.")):
            return addr
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


def signal_percent(rssi):
    """RSSI z modemu je 0–31 (99 = neznámý) — pro lidi převedeno na procenta."""
    try:
        # modem hlásí i tvar „20, -73 dBm" — čárka za číslem musí pryč
        value = int(str(rssi).split()[0].rstrip(","))
    except (TypeError, ValueError):
        return "?"
    if not 0 <= value <= 31:
        return "?"
    return "%d %%" % round(value / 31 * 100)


def read_cdr(limit=30):
    """Historie hovorů z CDR (Master.csv). Sloupce podle cdr_csv:
    accountcode,src,dst,dcontext,clid,channel,dstchannel,lastapp,lastdata,
    start,answer,end,duration,billsec,disposition,amaflags

    Čte se jen KONEC souboru (roste bez rotace — po roce provozu nesmí každé
    načtení dashboardu polykat celý soubor) a parsuje se po řádcích: jeden
    vadný bajt nebo useknutý zápis zahodí řádek, ne celou stránku."""
    path = os.path.join(os.path.dirname(LOG_FILE), "cdr-csv", "Master.csv")
    rows = []
    try:
        import csv as _csv
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 256 * 1024))
            chunk = f.read().decode("utf-8", errors="replace")
        lines = chunk.splitlines()
        if size > 256 * 1024 and lines:
            lines = lines[1:]  # první řádek výseku může být useknutý
        for ln in lines:
            try:
                cols = next(_csv.reader([ln]))
            except (StopIteration, _csv.Error):
                continue
            if len(cols) < 15:
                continue
            # interní kanály (doručování zpráv, potvrzenky, opakované
            # pokusy) nejsou hovory — do historie nepatří
            if cols[5].startswith("Local/"):
                continue
            incoming = cols[5].startswith("Quectel/")
            rows.append({
                "dir": "in" if incoming else "out",
                "num": cols[1] if incoming else cols[2],
                "start": cols[9],
                "billsec": cols[13],
                "disposition": cols[14],
            })
    except Exception:
        return []  # nečitelná historie nesmí shodit dashboard
    return list(reversed(rows))[:limit]


def _fmt_call(c):
    arrow = "\u2199" if c["dir"] == "in" else "\u2197"
    state = {"ANSWERED": "%s s" % c["billsec"], "NO ANSWER": "nezvednuto",
             "BUSY": "obsazeno", "FAILED": "nespojeno"}.get(
        c["disposition"], c["disposition"].lower())
    return "%s %s · %s · %s" % (arrow, esc(c["num"] or "?"), state,
                                esc(c["start"][5:16]))


def page_calls():
    rows = read_cdr(limit=50)
    if rows:
        items = "".join("<li class=\"mono\">%s</li>" % _fmt_call(c) for c in rows)
        body = "<h1>Hovory</h1><ul class=\"plain\">%s</ul>" % items
    else:
        body = ("<h1>Hovory</h1><p class=\"muted\">Zatím žádné hovory "
                "(historie se začíná psát od této verze).</p>")
    return render("hovory", body)


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
                                       " + hlas po datové síti" if volte_state() == "registered"
                                       else "",
                                       esc(signal_percent(m.get("RSSI"))))))
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
    waiting = len(read_queue())
    tiles.append(_tile(
        "\U0001F4AC", "Zprávy",
        esc(last["from"]) if last else "—",
        "warn" if waiting else "",
        "%s%s · <a href=\"%s\">všechny zprávy</a>"
        % (esc(last["msg"][:60]) if last else "zatím žádné",
           " · <b>čeká na doručení: %d</b>" % waiting if waiting else "",
           u("/sms"))))

    if debug_ssh_on():
        tiles.append(_tile(
            "\U0001F527", "Ladění", "Zapnuto", "warn",
            "vzdálená správa z privátní sítě je otevřená · "
            '<a href="%s">vypnout</a>' % u("/net")))

    calls = read_cdr(limit=1)
    tiles.append(_tile(
        "\U0001F4DE", "Hovory",
        _fmt_call(calls[0]) if calls else "—", "",
        ("poslední hovor · " if calls else "zatím žádné · ")
        + '<a href="%s">historie</a>' % u("/hovory")))

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
        islandnote = ('<p class="muted"><span class="dot ok"></span>Modem umí '
                      "hlas po datové síti, takže data jedou i během hovoru.</p>")
    elif volte == "not-registered":
        islandnote = ('<p class="muted"><span class="dot warn"></span>Modem '
                      "teď hlas po datové síti nemá. Náhradní připojení proto během hovoru "
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
    m = modem_summary() or {}
    phones = sum(1 for ln in contacts.splitlines() if "Avail" in ln)
    active = ""
    for ln in chans.splitlines():
        if "active channel" in ln:
            active = ln.strip()
    rows = [
        ("Mobilní síť", "%s · %s · signál %s" % (
            esc(m.get("Provider Name", "?")),
            esc(m.get("Access technology", "?")),
            esc(signal_percent(m.get("RSSI"))))),
        ("Stav modemu", esc(m.get("State") or "nezjištěno")),
        ("Hlas po datové síti", esc(volte_state())),
        ("Telefon připojen", "ano (%d)" % phones if phones else "ne"),
        ("Probíhající hovory", esc(active) or "žádné"),
    ]
    summary = "<table>%s</table>" % "".join(
        "<tr><th>%s</th><td>%s</td></tr>" % r for r in rows)
    body = (
        "<h1>%s</h1>"
        "<h2>Přehled</h2>%s"
        "<h2>SMS fronta</h2><p>%s</p>"
        "<h2>Hlídka modemu</h2>%s"
    ) % ("Pokročilé" if GUI else "Stav miniserveru", summary, qbadge, wdblock)
    if not GUI:
        # Technické výpisy jen v expert režimu.
        body += (
            "<h2>Modem</h2><pre>%s</pre>"
            "<h2>Detail zařízení</h2><pre>%s</pre>"
            "<h2>Připojení telefonu</h2><pre>%s</pre>"
            "<h2>Kanály</h2><pre>%s</pre>"
        ) % (esc(cli("quectel show devices")),
             esc(cli("quectel show device state " + DEVICE)),
             esc(contacts), esc(chans))
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
        body += ('<p class="muted">Hlas po datové síti: <b>%s</b>%s</p>' % (
            esc(volte_state()),
            "" if volte_state() == "registered" else
            " — bez něj přepne modem hovor do starší sítě a datové spojení "
            "na tu dobu padá; hlídka ho po hovoru postaví znovu."))
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
            '<p>Miniserver je v síti — teď připoj telefon na záložce '
            '<a href="%s">Telefon</a>.</p>' % u("/telefon"))
    have_partner = bool(read_partner_token())
    blocks.append(
        "<h2>Token pro připojení telefonu</h2>"
        "<p>Aby jeden QR kód nastavil telefonu účet i síť, potřebuje "
        "miniserver token z tvého účtu sítě (vydá se na "
        '<a href="%s" target="_blank">%s</a>, sekce token brány). Bez něj '
        "QR nastaví jen účet a telefon do sítě připojíš ručně.</p>"
        '<p class="small muted">Stav: %s</p>'
        '<form class="inline" method="post" action="%s">'
        '<input name="partner_token" placeholder="cspk_..." size="40" required>'
        "<button>Uložit token</button></form>"
        % (esc(dash), esc(dash),
           "token uložen" if have_partner else "token zatím není",
           u("/net/partner")))
    fw = firewall_state()
    if fw:
        dbg = debug_ssh_on()
        if fw.startswith("active"):
            fw_txt = "zapnutý — z privátní sítě projde jen telefonování a ovládání"
            fw_cls = "ok"
        elif fw.startswith("disabled"):
            fw_txt = "vypnutý souborem firewall.env"
            fw_cls = "warn"
        else:
            fw_txt = "CHYBA — z privátní sítě je miniserver otevřený"
            fw_cls = "bad"
        blocks.append(
            "<h2>Ladění přes privátní síť</h2>"
            '<p class="small muted">Filtr provozu: <span class="%s">%s</span></p>'
            "<p>Otevře vzdálenou správu miniserveru z privátní sítě (bez "
            "omezení na konkrétní zařízení). Projeví se do 15 s a přežije "
            "restart — po skončení práce vypni.</p>"
            '<p>Stav: <b>%s</b></p>'
            '<form class="inline" method="post" action="%s">'
            '<input type="hidden" name="value" value="%s">'
            "<button>%s</button></form>"
            % (fw_cls, esc(fw_txt), "zapnuto" if dbg else "vypnuto",
               u("/net/debug"), "off" if dbg else "on",
               "Vypnout ladění" if dbg else "Povolit ladění"))
    return render("net", "".join(blocks))


def _dav_user_row(name):
    return (
        "<tr><td><b>%s</b></td><td>"
        '<form class="inline" method="post" action="%s">'
        '<input type="hidden" name="user" value="%s">'
        "<button>Nové heslo</button></form> "
        '<form class="inline" method="post" action="%s">'
        '<input type="hidden" name="user" value="%s">'
        '<label class="small"><input type="checkbox" name="drop" value="1"> '
        "smazat i data</label> "
        '<button class="ghost">Smazat</button></form></td></tr>'
    ) % (esc(name), u("/dav/user/pass"), esc(name),
         u("/dav/user/del"), esc(name))


def page_dav(info=""):
    """Kontakty a kalendář: účty pro zařízení, import, návod k nastavení."""
    blocks = [info, "<h1>Kontakty a kalendář</h1>"]
    status, _ = dav_request("PROPFIND", "/", None, None, {"Depth": "0"})
    if status == 0:
        blocks.append('<p class="bad">[OVL-E23] Úložiště zatím neodpovídá — '
                      "zkus to za chvíli.</p>")
    users = [x for x in sorted(dav_read_users()) if x != DAV_ADMIN]
    rows = "".join(_dav_user_row(x) for x in users) or \
        '<tr><td colspan="2" class="muted">zatím žádný účet</td></tr>'
    blocks.append(
        "<h2>Účty</h2>"
        "<p>Každé zařízení dostane vlastní účet. Heslo se ukáže jen jednou — "
        "zapiš si ho, jinak vydej nové.</p>"
        "<table><tr><th>účet</th><th></th></tr>%s</table>"
        '<form class="inline" method="post" action="%s">'
        '<input name="user" placeholder="jmeno" size="20" required>'
        "<button>Založit účet</button></form>"
        '<p class="small muted">Jméno: malá písmena, číslice, tečka, pomlčka '
        "nebo podtržítko, 2–32 znaků.</p>" % (rows, u("/dav/user/add")))

    with _dav_lock:
        imp = dict(_dav_import)
    if imp["running"] or imp["total"]:
        blocks.append(
            '<p class="%s">Import (%s): %s — uloženo %d, přeskočeno %d, '
            "chyb %d z %d.</p>%s"
            % ("warn" if imp["running"] else "ok",
               "kontakty" if imp["kind"] == "vcard" else "kalendář",
               "probíhá" if imp["running"] else "hotovo",
               imp["done"], imp["skipped"], imp["failed"], imp["total"],
               ("<pre>%s</pre>" % esc("\n".join(imp["errors"])))
               if imp["errors"] else ""))
        if imp["running"]:
            blocks.append('<meta http-equiv="refresh" content="3">')
    options = "".join("<option>%s</option>" % esc(x) for x in users) or \
        '<option value="">(nejdřív založ účet)</option>'
    blocks.append(
        "<h2>Import ze starého telefonu</h2>"
        "<p>Nahraj soubor <b>.vcf</b> (kontakty) nebo <b>.ics</b> (kalendář). "
        "Položky, které už na miniserveru jsou, se přeskočí — import jde "
        "opakovat.</p>"
        '<form method="post" action="%s" enctype="multipart/form-data">'
        '<label>Účet: <select name="user">%s</select></label> '
        '<input type="file" name="file" required> '
        "<button>Nahrát</button></form>" % (u("/dav/import"), options))

    url_rows = "".join(
        '<tr><td>%s</td><td class="mono">%s</td></tr>' % (esc(label), esc(url))
        for label, url in dav_urls())
    blocks.append(
        "<h2>Nastavení zařízení</h2>"
        "<table><tr><th>odkud</th><th>adresa</th></tr>%s</table>"
        "<p><b>Android:</b> nainstaluj synchronizační aplikaci (DAVx⁵ "
        "z F-Droidu), přidej účet volbou <i>Přihlásit se pomocí URL a jména</i>, "
        "vlož adresu výše, jméno účtu a heslo. Potvrď nešifrované spojení "
        "v domácí síti a zapni <i>Kontakty</i> i <i>Kalendář</i>. V každém "
        "profilu telefonu zvlášť.</p>"
        "<p><b>iPhone:</b> Nastavení → Aplikace → Kontakty → Účty → Přidat "
        "účet → Jiné → Přidat účet CardDAV; server je adresa výše bez "
        "<i>http://</i>, v Upřesnit vypni SSL a nastav port %s. Kalendář "
        "stejně přes CalDAV.</p>"
        '<p class="small muted">Mimo domov funguje synchronizace jen přes '
        "privátní síť.</p>" % (url_rows, esc(DAV_PORT)))
    return render("dav", "".join(blocks))


def page_phone(info=""):
    """Připojení telefonu: QR kód + ruční údaje."""
    sec = read_secrets()
    ip = ts_ip()
    blocks = [info, "<h1>Telefon</h1>"]
    if not sec.get("SIP_USER"):
        blocks.append('<p class="bad">[OVL-E05] Nejde přečíst přihlašovací údaje '
                      "brány — zkus restartovat aplikaci.</p>")
        return render("phone", "".join(blocks))
    if not ip:
        blocks.append(
            '<p class="warn">Krabička zatím není v privátní síti, takže se '
            "k ní telefon zvenku nedovolá. Připoj ji na záložce "
            '<a href="%s">Síť</a> — pak se sem vrať.</p>' % u("/net"))
    if _prov_last["t"]:
        when = time.strftime("%H:%M", time.localtime(_prov_last["t"]))
        if _prov_last["err"]:
            blocks.append('<p class="warn">Telefon si konfiguraci stáhl '
                          "(naposledy %s), ale bez klíče do sítě: %s</p>"
                          % (when, esc(_prov_last["err"])))
        elif _prov_last["key"]:
            blocks.append('<p><span class="ok">Telefon si konfiguraci stáhl '
                          "(naposledy %s), včetně klíče do sítě.</span></p>" % when)
        else:
            blocks.append('<p class="small muted">Telefon si konfiguraci '
                          "stáhl (naposledy %s) — jen účet, bez tokenu na "
                          "záložce Síť klíč nenese.</p>" % when)
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
    """QR s odkazem na konfiguraci; kód otevře aplikaci rovnou."""
    body = """<h1>Připojení telefonu</h1>
<p>Nejdřív si v telefonu nainstaluj aplikaci <b>Phone21</b>. Pak naskenuj kód —
buď skenerem v aplikaci (Přidat účet → <b>Scan QR code</b>), nebo běžným
fotoaparátem telefonu; obojí appku nastaví samo.</p>
<p><b>Telefon musí být na stejné wifi jako miniserver.</b> Konfiguraci si
stahuje z domácí sítě, protože do privátní sítě se teprve chystá — a kód
platí 10 minut a jen jednou.</p>
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
        "%s<h2>Servisní příkaz modemu</h2>"
        '<form class="inline" method="post" action="' + u("/diag/at") + '">'
        '<input name="cmd" required size="30">'
        "<button>Poslat</button></form>"
        "<small>Odpověď dorazí se zpožděním a objeví se v záznamu níže. "
        "Pozor, některé servisní příkazy modem rozbijí.</small>"
        "<h2>Záznam telefonní části</h2><pre>%s</pre>"
        '<p><button onclick="location.reload()">Obnovit</button></p>'
    ) % (at_info, esc(tail_log())))


# --- přihlášení: formulář + session (Basic auth dialog neuměl spolupracovat
# se správci hesel) a volitelné dvoufázové ověření (TOTP) -----------------------

SESSION_TTL = 12 * 3600
_sessions = {}
_sessions_lock = threading.Lock()
_totp_pending = {}      # návrh tajemství čekající na potvrzení kódem

# Rate-limit přihlášení: bez něj jde heslo zkoušet neomezenou rychlostí
# a nikde po tom nezůstane stopa. Okno je krátké a limity mírné — za
# app_proxy (Umbrel) je vidět jen adresa proxy, takže limit je tam fakticky
# globální a nesmí legitimního uživatele zamknout na dlouho.
LOGIN_WINDOW = 60
LOGIN_MAX_IP = 5
LOGIN_MAX_GLOBAL = 20
_login_attempts = {}    # ip -> [časy pokusů v okně]
_login_lock = threading.Lock()


def login_allowed(ip):
    """Započítá pokus; False = tenhle pokus už se nemá ani vyhodnocovat."""
    now = time.time()
    with _login_lock:
        for k in list(_login_attempts):
            _login_attempts[k] = [t for t in _login_attempts[k]
                                  if now - t < LOGIN_WINDOW]
            if not _login_attempts[k]:
                del _login_attempts[k]
        total = sum(len(v) for v in _login_attempts.values())
        if total >= LOGIN_MAX_GLOBAL \
                or len(_login_attempts.get(ip, [])) >= LOGIN_MAX_IP:
            return False
        _login_attempts.setdefault(ip, []).append(now)
        return True


def login_reset(ip):
    with _login_lock:
        _login_attempts.pop(ip, None)


def totp_secret_path():
    return os.path.join(STATE_DIR, "totp_secret")


def totp_enabled():
    return os.path.isfile(totp_secret_path())


def _b32decode(text):
    pad = "=" * (-len(text) % 8)
    return base64.b32decode(text.upper() + pad)


def totp_code(secret_b32, when=None, step=30, digits=6):
    import hmac as _hmac
    import struct as _struct
    counter = int((when if when is not None else time.time()) // step)
    mac = _hmac.new(_b32decode(secret_b32),
                    _struct.pack(">Q", counter), "sha1").digest()
    offset = mac[-1] & 0x0F
    value = (int.from_bytes(mac[offset:offset + 4], "big") & 0x7FFFFFFF)
    return str(value % (10 ** digits)).zfill(digits)


def totp_verify(secret_b32, code):
    code = (code or "").strip().replace(" ", "")
    now = time.time()
    return any(hmac.compare_digest(totp_code(secret_b32, now + drift), code)
               for drift in (-30, 0, 30))


def session_new():
    token = base64.urlsafe_b64encode(os.urandom(24)).decode().rstrip("=")
    with _sessions_lock:
        now = time.time()
        for old, exp in list(_sessions.items()):
            if exp < now:
                del _sessions[old]
        _sessions[token] = now + SESSION_TTL
    return token


def session_valid(token):
    with _sessions_lock:
        exp = _sessions.get(token or "")
        if not exp:
            return False
        if exp < time.time():
            del _sessions[token]
            return False
        return True


def session_drop(token):
    with _sessions_lock:
        _sessions.pop(token or "", None)


def page_login(msg=""):
    banner = '<p class="bad">%s</p>' % esc(msg) if msg else ""
    totp_field = ("<label>Kód z ověřovací aplikace</label>"
                  '<input type="text" name="totp" inputmode="numeric"'
                  ' autocomplete="one-time-code" placeholder="123 456">'
                  ) if totp_enabled() else ""
    return """<!doctype html><html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Přihlášení — Phone21</title><style>
body { margin:0; font-family:system-ui,sans-serif; background:#f7f4ee;
  color:#1a1714; display:grid; place-items:center; min-height:100vh; }
@media (prefers-color-scheme: dark) { body { background:#0b0b0e; color:#f2f2f3; } }
main { width:min(24rem, 92vw); }
h1 { color:#f7931a; }
label { display:block; margin:.9rem 0 .3rem; font-size:.9rem; opacity:.75; }
input { width:100%%; padding:.6rem .7rem; font-size:1rem; border:1px solid
  #8884; border-radius:8px; background:transparent; color:inherit; }
button { margin-top:1.1rem; padding:.65rem 1.4rem; font-size:1rem;
  border:0; border-radius:8px; background:#f7931a; color:#111; font-weight:700; }
.bad { color:#e03131; }
.muted { opacity:.55; font-size:.8rem; }
</style></head><body><main>
<h1>Phone21</h1>%s
<form method="post" action="%s">
<label>Uživatel</label>
<input type="text" name="user" value="admin" readonly autocomplete="username">
<label>Heslo</label>
<input type="password" name="password" autocomplete="current-password" autofocus>
%s
<p><button type="submit">Přihlásit</button></p>
</form>
<p class="muted">obrazovka OVL-LOGIN</p>
</main></body></html>""" % (banner, u("/login"), totp_field)


def page_2fa(info=""):
    body = [info, "<h1>Dvoufázové ověření</h1>"]
    if totp_enabled():
        body.append(
            '<p><span class="ok">Zapnuto.</span> Přihlášení chce heslo '
            "i kód z ověřovací aplikace.</p>"
            '<form method="post" action="%s">'
            "<label>Kód z aplikace (potvrzení vypnutí)</label>"
            '<input type="text" name="totp" inputmode="numeric" autocomplete="one-time-code">'
            '<p><button class="danger">Vypnout</button></p></form>' % u("/2fa/off"))
    elif "pending" in _totp_pending:
        secret = _totp_pending["pending"]
        uri = ("otpauth://totp/Phone21:minserver?secret=%s&issuer=Phone21"
               % secret)
        body.append(
            "<p>Naskenuj kód ověřovací aplikací (Aegis, Bitwarden, "
            "Google Authenticator…) a potvrď kódem:</p>"
            '<div id="qr" class="qr"></div>'
            '<p class="small mono">%s</p>'
            '<form method="post" action="%s">'
            '<input type="text" name="totp" inputmode="numeric" autocomplete="one-time-code"'
            ' placeholder="123 456">'
            "<p><button>Potvrdit a zapnout</button></p></form>"
            '<script src="%s"></script>'
            "<script>new QRCode(document.getElementById('qr'), "
            "{text: %s, width: 220, height: 220});</script>"
            % (esc(secret), u("/2fa/confirm"), u("/static/qrcode.min.js"),
               json.dumps(uri)))
    else:
        body.append(
            "<p>Přihlášení bude chtít vedle hesla i jednorázový kód "
            "z ověřovací aplikace v telefonu.</p>"
            '<form method="post" action="%s">'
            "<p><button>Zapnout dvoufázové ověření</button></p></form>"
            % u("/2fa/setup"))
    return render("2fa", "".join(body))


class Handler(BaseHTTPRequestHandler):
    server_version = "phone21-ui"

    def _session_token(self):
        raw = self.headers.get("Cookie") or ""
        for part in raw.split(";"):
            name, _, value = part.strip().partition("=")
            if name == "p21_session":
                return value
        return ""

    def _authed(self):
        if not WEBUI_PASSWORD:
            return False  # bez hesla neběžíme
        return session_valid(self._session_token())

    def _deny(self):
        self._html(page_login())

    def _html(self, body, code=200):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _multipart(self, max_bytes):
        """Vrátí (pole, jméno souboru, obsah) z formuláře s přílohou.
        Pole je None, když je tělo větší než limit."""
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype or "boundary=" not in ctype:
            return {}, "", b""
        boundary = ctype.split("boundary=", 1)[1].strip().strip('"')
        length = int(self.headers.get("Content-Length", "0"))
        if length > max_bytes:
            return None, "", b""
        raw = self.rfile.read(length)
        sep = ("--" + boundary).encode()
        fields, filename, content = {}, "", b""
        for part in raw.split(sep):
            if not part or part.strip() in (b"", b"--"):
                continue
            head, _, body = part.partition(b"\r\n\r\n")
            if body.endswith(b"\r\n"):
                body = body[:-2]
            headers = head.decode("utf-8", "replace")
            name = ""
            for token in headers.replace("\r\n", ";").split(";"):
                token = token.strip()
                if token.startswith("name="):
                    name = token[5:].strip('"')
                elif token.startswith("filename="):
                    filename = token[9:].strip('"')
            if not name:
                continue
            if name == "file":
                content = body
            else:
                fields[name] = body.decode("utf-8", "replace").strip()
        return fields, filename, content

    def _form(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(min(length, 65536)).decode()
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def do_GET(self):
        if self.path == "/login":
            return self._html(page_login())
        if self.path == "/logout":
            session_drop(self._session_token())
            return self._html(page_login("Odhlášeno."))
        if self.path.startswith("/static/"):
            return self.get_static(self.path)
        if not self._authed():
            return self._deny()
        if self.path == "/2fa":
            return self._html(page_2fa())
        if self.path == "/hovory":
            return self._html(page_calls())
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
        if self.path.startswith("/dav") and DAV_ENABLED:
            # i po odeslání formuláře zůstává v adrese /dav/... — obnovení
            # stránky (i to automatické během importu) musí ukázat stav
            return self._html(page_dav())
        if self.path == "/diag":
            # technický záznam jen v expert režimu
            return self._html(page_diag() if not GUI else page_status())
        self._html("<p>404</p>", 404)

    def do_POST(self):
        if self.path == "/login":
            ip = self.client_address[0]
            if not login_allowed(ip):
                audit("login LIMIT ip=%s" % ip)
                return self._html(page_login(
                    "[OVL-E22] Moc pokusů po sobě — počkej minutu a zkus to "
                    "znovu."), 429)
            form = self._form()
            if not hmac.compare_digest(form.get("password", "").encode(),
                                       WEBUI_PASSWORD.encode()):
                audit("login FAIL ip=%s" % ip)
                return self._html(page_login("[OVL-E01] Heslo nesedí."))
            if totp_enabled():
                try:
                    secret = open(totp_secret_path()).read().strip()
                except OSError as e:
                    audit("login 2FA-READ-ERROR ip=%s err=%s" % (ip, e))
                    return self._html(page_login(
                        "[OVL-E21] Nejde přečíst nastavení dvoufázového "
                        "ověření — zkus to za chvíli, případně restartuj "
                        "aplikaci."))
                if not totp_verify(secret, form.get("totp", "")):
                    audit("login TOTP-FAIL ip=%s" % ip)
                    return self._html(page_login(
                        "[OVL-E02] Jednorázový kód nesedí (nebo vypršel)."))
            audit("login OK ip=%s" % ip)
            login_reset(ip)
            token = session_new()
            data = b""
            self.send_response(303)
            self.send_header("Location", u("/"))
            self.send_header(
                "Set-Cookie",
                "p21_session=%s; Path=/; HttpOnly; SameSite=Lax; Max-Age=%d"
                % (token, SESSION_TTL))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not self._authed():
            return self._deny()
        if self.path == "/dav/import" and DAV_ENABLED:
            fields, filename, content = self._multipart(DAV_IMPORT_MAX)
            if fields is None:
                return self._html(page_dav(
                    '<p class="bad">[OVL-E28] Soubor je moc velký '
                    "(limit 20 MB).</p>"))
            user = (fields or {}).get("user", "").strip()
            if not DAV_USER_RE.match(user) or user not in dav_read_users():
                return self._html(page_dav(
                    '<p class="bad">[OVL-E24] Vyber existující účet.</p>'))
            if not content:
                return self._html(page_dav(
                    '<p class="bad">[OVL-E27] Soubor je prázdný.</p>'))
            err = dav_import_start(user, content)
            if err:
                return self._html(page_dav('<p class="bad">%s</p>' % err))
            return self._html(page_dav(
                '<p class="ok">Import běží — stránka se sama obnovuje.</p>'))
        form = self._form()
        if self.path == "/2fa/setup":
            secret = base64.b32encode(os.urandom(20)).decode().rstrip("=")
            _totp_pending["pending"] = secret
            return self._html(page_2fa())
        if self.path == "/2fa/confirm":
            secret = _totp_pending.get("pending", "")
            if not secret or not totp_verify(secret, form.get("totp", "")):
                return self._html(page_2fa(
                    '<p class="bad">[OVL-E03] Kód nesedí — zkus to znovu, '
                    "kódy platí 30 sekund.</p>"))
            try:
                write_state(totp_secret_path(), secret)
            except OSError as e:
                audit("2fa ENABLE-WRITE-ERROR err=%s" % e)
                return self._html(page_2fa(
                    '<p class="bad">[OVL-E19] Nastavení teď nejde uložit '
                    "(%s). Zkus to po restartu aplikace; kdyby to trvalo, "
                    "nahlas to i s tímhle kódem.</p>" % esc(e)))
            _totp_pending.clear()
            audit("2fa ENABLED")
            return self._html(page_2fa('<p class="ok">Dvoufázové ověření zapnuto.</p>'))
        if self.path == "/2fa/off":
            secret = ""
            try:
                secret = open(totp_secret_path()).read().strip()
            except OSError:
                pass
            if not secret or not totp_verify(secret, form.get("totp", "")):
                return self._html(page_2fa(
                    '<p class="bad">[OVL-E04] Kód nesedí — vypnutí chce '
                    "platný kód.</p>"))
            try:
                os.unlink(totp_secret_path())
            except FileNotFoundError:
                pass
            except OSError as e:
                audit("2fa DISABLE-WRITE-ERROR err=%s" % e)
                return self._html(page_2fa(
                    '<p class="bad">[OVL-E20] Vypnutí teď nejde uložit '
                    "(%s). Zkus to po restartu aplikace.</p>" % esc(e)))
            audit("2fa DISABLED")
            return self._html(page_2fa('<p class="ok">Dvoufázové ověření vypnuto.</p>'))
        if self.path == "/missed-mode":
            page = page_home if GUI else page_status
            mode = form.get("mode", "")
            if mode not in MISSED_MODES:
                return self._html(page('<p class="bad">[OVL-E06] Neplatný režim.</p>'))
            # Enum konstanta, žádný user input do CLI. Dialplan čte
            # ${DB(phone21/missed_mode)} — AstDB leží na persistentním volume
            # (astdbdir v asterisk.conf), takže volba přežije i recreate.
            cli("database put phone21 missed_mode " + mode)
            saved = get_missed_mode()
            info = ('<p class="ok">Uloženo (%s).</p>' % esc(saved)) if saved == mode \
                else '<p class="bad">[OVL-E16] Zápis se nepotvrdil — zkontroluj spojení s telefonní částí.</p>'
            return self._html(page(info))
        if self.path == "/island-mode":
            page = page_home if GUI else page_status
            want = form.get("island", "")
            if want not in ("on", "off"):
                return self._html(page('<p class="bad">[OVL-E07] Neplatná volba.</p>'))
            # Smyčka wwan.sh watch se na tenhle klíč ptá před každým cyklem,
            # takže přepnutí se projeví do jednoho intervalu bez restartu.
            cli("database put phone21 island_mode " + want)
            saved = get_island_mode()
            info = ('<p class="ok">Ostrovní režim: %s.</p>'
                    % ("zapnuto" if saved == "on" else "vypnuto")) \
                if saved == want else \
                '<p class="bad">[OVL-E17] Zápis se nepotvrdil — zkontroluj spojení s telefonní částí.</p>'
            return self._html(page(info))
        if self.path == "/sms/send":
            to = "".join(c for c in form.get("to", "") if c in "+0123456789")
            to = normalize_msisdn(to)
            text = form.get("text", "")[:459]
            if not to or not text:
                return self._html(page_sms('<p class="bad">[OVL-E08] Chybí číslo nebo text.</p>'))
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
                        if ok else '<p class="bad">[OVL-E09] Odeslání selhalo: %s</p>') \
                    % esc(resp.get("Message", ""))
            except Exception as e:
                info = '<p class="bad">[OVL-E18] Chyba spojení s telefonní částí: %s</p>' % esc(e)
            return self._html(page_sms(info))
        if self.path == "/telefon/qr":
            ip = ts_ip()
            if not ip:
                return self._html(page_phone(
                    '<p class="bad">[OVL-E10] Nejdřív připoj miniserver do privátní sítě '
                    "(záložka Síť).</p>"))
            host = lan_ip() or ip
            url = "http://%s:%d/p/%s" % (host, PROV_PORT, prov_new_token())
            return self._html(page_qr(url))
        if self.path == "/net/authkey" and TS_DIR:
            key = form.get("authkey", "").strip()
            # auth klíče: base64-like tokeny (headscale hskey-auth-…)
            if not re.match(r"^[A-Za-z0-9_-]{20,200}$", key):
                return self._html(page_net('<p class="bad">[OVL-E11] Tohle nevypadá jako auth klíč.</p>'))
            try:
                path = os.path.join(TS_DIR, "authkey")
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "w") as f:
                    f.write(key)
                info = '<p class="ok">Klíč uložen — připojuji do privátní sítě.</p>'
            except OSError as e:
                info = '<p class="bad">[OVL-E12] Nejde uložit klíč: %s</p>' % esc(e)
            return self._html(page_net(info))
        if self.path == "/net/partner":
            token = form.get("partner_token", "").strip()
            if not re.match(r"^cspk_[A-Za-z0-9_-]{10,200}$", token):
                return self._html(page_net(
                    '<p class="bad">[OVL-E13] Tohle nevypadá jako token brány '
                    "(začíná cspk_).</p>"))
            try:
                save_partner_token(token)
                info = '<p class="ok">Token uložen — QR teď nastaví i síť.</p>'
            except OSError as e:
                info = '<p class="bad">[OVL-E14] Nejde uložit token: %s</p>' % esc(e)
            return self._html(page_net(info))
        if self.path.startswith("/dav/user/") and DAV_ENABLED:
            name = form.get("user", "").strip().lower()
            if not DAV_USER_RE.match(name) or name == DAV_ADMIN:
                return self._html(page_dav(
                    '<p class="bad">[OVL-E24] Tohle jméno účtu nejde '
                    "použít.</p>"))
            if self.path == "/dav/user/add":
                password, err = dav_user_add(name)
            elif self.path == "/dav/user/pass":
                password, err = dav_user_reset(name)
            elif self.path == "/dav/user/del":
                err = dav_user_del(name, form.get("drop", "") == "1")
                return self._html(page_dav(
                    ('<p class="bad">%s</p>' % err) if err else
                    '<p class="ok">Účet %s smazán.</p>' % esc(name)))
            else:
                return self._html(page_dav("<p>404</p>"))
            if err:
                return self._html(page_dav('<p class="bad">%s</p>' % err))
            return self._html(page_dav(
                '<p class="ok">Účet <b>%s</b>, heslo <span class="mono">%s'
                "</span> — ukáže se jen teď, zapiš si ho.</p>"
                % (esc(name), esc(password))))
        if self.path == "/net/debug":
            want_on = form.get("value", "") == "on"
            try:
                if want_on:
                    write_state(debug_ssh_path(), "1")
                    info = ('<p class="ok">Ladění zapnuto — vzdálená správa '
                            "z privátní sítě bude otevřená do 15 s.</p>")
                else:
                    try:
                        os.remove(debug_ssh_path())
                    except FileNotFoundError:
                        pass
                    info = ('<p class="ok">Ladění vypnuto — vzdálená správa '
                            "se do 15 s zavře.</p>")
                audit("net/debug ip=%s value=%s" % (self.client_address[0],
                                                    "on" if want_on else "off"))
            except OSError as e:
                info = ('<p class="bad">[OVL-E23] Nejde uložit volbu ladění: '
                        "%s</p>" % esc(e))
            return self._html(page_net(info))
        if self.path == "/diag/at":
            cmd = form.get("cmd", "").strip()
            # Řídicí znaky (CR/LF) by z jednoho příkazu udělaly injekci
            # dalších akcí — příkaz jde do ústředny jako text.
            if (not cmd.upper().startswith("AT")
                    or "CUSBPIDSWITCH" in cmd.upper()
                    or len(cmd) > 128
                    or any(ord(c) < 32 or ord(c) == 127 for c in cmd)):
                return self._html(page_diag('<p class="bad">[OVL-E15] Povolené jsou jen servisní příkazy modemu (max 128 znaků, bez řídicích znaků).</p>'))
            audit("diag/at ip=%s cmd=%r" % (self.client_address[0], cmd))
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
    Běží bez hesla, takže nic jiného neobsluhuje."""
    server_version = "phone21-prov"

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
        # klíč do sítě se bere až teď: platí hodinu a telefon ho použije hned
        ts_key, ts_url, err = request_network_key()
        _prov_last.update(t=time.time(), err=err, key=bool(ts_key))
        if err:
            print("[prov] stažení z %s: účet ano, síť ne — %s"
                  % (self.client_address[0], err), flush=True)
        data = prov_xml(ip, ts_url, ts_key).encode()
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
    print("phone21-ui na :%d" % WEBUI_PORT, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
