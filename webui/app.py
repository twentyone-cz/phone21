#!/usr/bin/env python3
"""GSM2SIP web UI — správa a diagnostika brány.

Čistá stdlib (žádné závislosti). Mluví s Asteriskem přes AMI (localhost),
žurnál/frontu SMS čte z /var/lib/gsm2sip. Basic auth (WEBUI_PASSWORD).
Určeno výhradně pro LAN/WireGuard — nikdy nevystavovat veřejně.
"""

import base64
import html
import json
import os
import re
import socket
import subprocess
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
WG_PEER_CONF = os.environ.get("WG_PEER_CONF", "/etc/wireguard-peer/phone-wg.conf")
WG_ENDPOINT = os.environ.get("WG_ENDPOINT", "")  # předvyplnění, dá se přepsat v UI

_ami_lock = threading.Lock()


class AmiError(Exception):
    pass


class Ami:
    """Minimální AMI klient: login → akce → logoff, jedno spojení na dotaz."""

    def __init__(self):
        self.sock = socket.create_connection((AMI_HOST, AMI_PORT), timeout=8)
        self.buf = b""
        self._read_until(b"\r\n")  # banner
        resp = self.action("Login", Username=AMI_USER, Secret=AMI_PASSWORD)
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


ENDPOINT_RE = re.compile(r"^[A-Za-z0-9.:\[\]-]{3,80}$")


def wg_peer_config(endpoint=""):
    """Config telefonu s dosazeným Endpointem. Vrací (text, chyba).

    Endpoint se nedrží v souboru: veřejná IP se mění a port se může lišit od
    ListenPortu (na routeru je forward z jiného portu). Zadá se v UI nebo
    předvyplní přes WG_ENDPOINT.
    """
    try:
        with open(WG_PEER_CONF) as f:
            conf = f.read()
    except OSError as e:
        return "", "Config telefonu nejde přečíst (%s): %s" % (WG_PEER_CONF, e)
    ep = (endpoint or WG_ENDPOINT).strip()
    if not ep:
        return conf, "Chybí endpoint — QR by vedl na placeholder a tunel by nenavázal."
    if not ENDPOINT_RE.match(ep):
        return conf, "Endpoint smí být jen host:port (písmena, číslice, . : [] -)."
    if ":" not in ep.rsplit("]", 1)[-1]:
        return conf, "Endpoint musí obsahovat i port, např. 203.0.113.10:443."
    out, seen = [], False
    for ln in conf.splitlines():
        if ln.strip().lower().startswith("endpoint"):
            out.append("Endpoint = " + ep)
            seen = True
        else:
            out.append(ln)
    if not seen:
        return conf, "V configu chybí řádek Endpoint — doplň ho do %s." % WG_PEER_CONF
    return "\n".join(out) + "\n", ""


def wg_qr_svg(text):
    """QR jako inline SVG (qrencode). Vrací (svg, chyba)."""
    try:
        p = subprocess.run(
            ["qrencode", "-t", "SVG", "-o", "-", "-m", "2", "-s", "5"],
            input=text.encode(), capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        return "", "qrencode selhal: %s" % e
    if p.returncode != 0:
        return "", "qrencode skončil s chybou: %s" % p.stderr.decode(errors="replace")
    # XML prolog a DOCTYPE se do HTML nevkládají — inline SVG začíná až <svg>.
    svg = p.stdout.decode(errors="replace")
    i = svg.find("<svg")
    return (svg[i:], "") if i >= 0 else ("", "qrencode nevrátil SVG")


PAGE = """<!doctype html><html lang="cs"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>GSM2SIP</title><style>
body{{font-family:system-ui,sans-serif;margin:0;background:#111;color:#ddd}}
nav{{background:#1b2a1b;padding:.6rem 1rem}}nav a{{color:#9c9;margin-right:1rem;text-decoration:none;font-weight:600}}
nav a.act{{color:#fff;border-bottom:2px solid #6b6}}
main{{padding:1rem;max-width:1100px;margin:auto}}
pre{{background:#000;padding:.8rem;border-radius:6px;overflow-x:auto;font-size:.85rem;line-height:1.35}}
table{{border-collapse:collapse;width:100%;font-size:.9rem}}
td,th{{border-bottom:1px solid #333;padding:.35rem .5rem;text-align:left;vertical-align:top}}
th{{color:#9c9}}tr:hover{{background:#1a1a1a}}
.ok{{color:#7d7}}.bad{{color:#e77}}.warn{{color:#dc8}}
form.inline{{display:flex;gap:.5rem;flex-wrap:wrap;margin:.8rem 0}}
input,textarea,button{{background:#222;color:#ddd;border:1px solid #444;border-radius:4px;padding:.45rem}}
button{{background:#2a4;border:0;color:#fff;cursor:pointer;font-weight:600}}
small{{color:#888}}
h2{{color:#9c9;font-size:1rem;margin:1.2rem 0 .4rem}}
.qr{{background:#fff;padding:12px;border-radius:8px;display:inline-block;
     max-width:320px;line-height:0}}
.qr svg{{display:block;width:100%;height:auto}}
details{{margin:.8rem 0}}summary{{cursor:pointer;color:#9c9}}
</style></head><body>
<nav><a href="/" class="{act_status}">Stav</a><a href="/sms" class="{act_sms}">SMS</a>
<a href="/phone" class="{act_phone}">Telefon</a>
<a href="/diag" class="{act_diag}">Diagnostika</a></nav>
<main>{body}</main>
<footer style="padding:1rem;text-align:center"><small>GSM2SIP · jen LAN/WG · {now}</small></footer>
</body></html>"""


def render(active, body):
    return PAGE.format(
        act_status="act" if active == "status" else "",
        act_sms="act" if active == "sms" else "",
        act_phone="act" if active == "phone" else "",
        act_diag="act" if active == "diag" else "",
        body=body, now=time.strftime("%Y-%m-%d %H:%M:%S"))


def esc(s):
    return html.escape(str(s), quote=True)


def page_status():
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
    return render("status", (
        "<h2>Modem</h2><pre>%s</pre>"
        "<h2>Detail zařízení</h2><pre>%s</pre>"
        "<h2>SIP registrace softphonu</h2><pre>%s</pre>"
        "<h2>Hovory</h2><pre>%s</pre>"
        "<h2>SMS fronta</h2><p>%s</p>"
        "<h2>Watchdog modemu</h2>%s"
        '<p><button onclick="location.reload()">Obnovit</button></p>'
    ) % (esc(dev), esc(state), esc(contacts), esc(chans), qbadge, wdblock))


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


def page_phone(endpoint=""):
    conf, err = wg_peer_config(endpoint)
    shown_ep = esc(endpoint or WG_ENDPOINT)
    blocks = [
        "<h2>WireGuard config pro telefon</h2>",
        '<form class="inline" method="post" action="/phone">'
        '<input name="endpoint" placeholder="verejna-ip:443" size="28" value="%s">'
        "<button>Zobrazit QR</button></form>"
        "<small>Endpoint = veřejná IP a port, na kterém je na routeru forward "
        "na UDP 51820 brány.</small>" % shown_ep,
    ]
    if err:
        blocks.append('<p class="bad">%s</p>' % esc(err))
    else:
        svg, qerr = wg_qr_svg(conf)
        if qerr:
            blocks.append('<p class="bad">%s</p>' % esc(qerr))
        else:
            blocks.append('<div class="qr">%s</div>' % svg)
            blocks.append(
                "<p><small>V appce WireGuard: <b>+</b> → <b>Skenovat z QR kódu</b>. "
                "Pak Linphone: účet <b>%s@%s</b>, transport TCP.</small></p>"
                % (esc(SIP_USER), esc(os.environ.get("SIP_DOMAIN", "10.6.0.1"))))
    blocks.append(
        '<p class="warn">QR i text níž obsahují <b>privátní klíč telefonu</b> — '
        "kdo je zachytí, dostane se do tunelu. Stránka je za heslem a jen na "
        "LAN/WG; po naskenování ji zavři a nesdílej screenshot.</p>")
    if conf:
        blocks.append(
            "<details><summary>Zobrazit config textem (ruční import)</summary>"
            "<pre>%s</pre></details>" % esc(conf))
    return render("phone", "".join(blocks))


def page_diag(at_info=""):
    return render("diag", (
        "%s<h2>AT příkaz</h2>"
        '<form class="inline" method="post" action="/diag/at">'
        '<input name="cmd" placeholder="AT+CSQ" required size="30">'
        "<button>Poslat</button></form>"
        "<small>Odpověď dorazí asynchronně — objeví se v logu níže "
        "(Got Response). Neposílej zakázaný AT příkaz!</small>"
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
            return self._html(page_status())
        if self.path == "/sms":
            return self._html(page_sms())
        if self.path == "/phone":
            return self._html(page_phone())
        if self.path == "/diag":
            return self._html(page_diag())
        self._html("<p>404</p>", 404)

    def do_POST(self):
        if not self._authed():
            return self._deny()
        form = self._form()
        if self.path == "/sms/send":
            to = "".join(c for c in form.get("to", "") if c in "+0123456789")
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
        if self.path == "/phone":
            # POST, ať se endpoint (a tím i QR s klíčem) neukládá do historie
            # prohlížeče ani do logu jako query string.
            return self._html(page_phone(form.get("endpoint", "")))
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
