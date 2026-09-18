#!/usr/bin/env python3
"""Test klienta koordinátora ve webui — bez sítě a bez dockeru.

Pustí lokální http.server s připravenými odpověďmi a projde všechny stavy,
které koordinátor umí vrátit (200, 401, 403 ×3, 409, 429, 5xx, odpověď bez
JSON, HTML od edge, ticho až do timeoutu), plus předání klíče brány sidecaru:
pořadí a atomicitu zápisu metadat a klíče, smazání značky want_key, jednorázovost
(dvojí stisk = jedno volání) a prodlevy mezi pokusy.

Spouští se: python3 scripts/test-webui-partner.py   (návratový kód 0 = vše OK)
"""

import http.server
import json
import os
import shutil
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- podvržený koordinátor ---------------------------------------------------

_script = []        # fronta připravených odpovědí
_seen = []          # co doopravdy dorazilo
_srv_lock = threading.Lock()


class Fake(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _record(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        with _srv_lock:
            _seen.append({
                "method": self.command,
                "path": self.path,
                "auth": self.headers.get("Authorization", ""),
                "length": self.headers.get("Content-Length"),
                "encoding": self.headers.get("Transfer-Encoding", ""),
                "body": body,
            })

    def do_POST(self):
        self._record()
        with _srv_lock:
            rec = _script.pop(0) if _script else {"status": 599, "body": b""}
        if rec.get("delay"):
            time.sleep(rec["delay"])
        body = rec.get("body", b"")
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(rec.get("status", 200))
        ctype = rec.get("ctype", "application/json")
        if ctype:
            self.send_header("Content-Type", ctype)
        for key, value in (rec.get("headers") or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST


def script(*records):
    with _srv_lock:
        _script[:] = list(records)
        _seen[:] = []


def seen():
    with _srv_lock:
        return list(_seen)


# --- pomůcky -----------------------------------------------------------------

FAILURES = []
CHECKS = [0]


def check(name, cond, detail=""):
    CHECKS[0] += 1
    if cond:
        print("  ok   %s" % name)
    else:
        print("  FAIL %s %s" % (name, detail))
        FAILURES.append(name)


def ts(name):
    return os.path.join(app.TS_DIR, name)


def reset(state=None, want_key=False, token="cspk_" + "a" * 20):
    """Čistý sdílený adresář sítě a čistý stav vlákna pro další případ."""
    for name in ("authkey", "key_meta", "want_key", "key_pending", "state",
                 "ip"):
        try:
            os.remove(ts(name))
        except OSError:
            pass
    try:
        os.remove(app.gateway_last_path())
    except OSError:
        pass
    if state:
        app.write_state(ts("state"), state)
    if want_key:
        app.write_state(ts("want_key"), "reason=needs_login\nsince=%d\n"
                        % int(time.time()))
    if token:
        app.save_partner_token(token)
    else:
        try:
            os.remove(app.partner_token_path())
        except OSError:
            pass
    app.gateway_backoff_clear()
    # strop za hodinu je pojistka proti točící se smyčce, ne součást backoffu —
    # nový token ho neruší, takže ho mezi případy shodí test
    app._gw["calls"] = []
    script()


GOOD_KEY = "abcdefghijklmnopqrstuvwx1234"


def ok_body(login, expires="2031-01-01T00:00:00Z", tag="tag:c-abc123"):
    return {"key": GOOD_KEY, "expires": expires, "login_server": login,
            "tag": tag}


# --- start serveru a import app.py -------------------------------------------

srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

TMP = tempfile.mkdtemp(prefix="p21-partner-")
os.environ.update(
    WEBUI_PASSWORD="test",
    PHONE21_DATA=os.path.join(TMP, "data"),
    WEBUI_STATE=os.path.join(TMP, "state"),
    TS_DIR=os.path.join(TMP, "ts"),
    COCKSCALE_URL="http://127.0.0.1:%d" % PORT,
    PARTNER_TIMEOUT_GATEWAY="1",
    PARTNER_TIMEOUT_PHONE="1",
)
os.makedirs(os.environ["TS_DIR"], exist_ok=True)
os.makedirs(os.environ["WEBUI_STATE"], exist_ok=True)
sys.path.insert(0, os.path.join(ROOT, "webui"))
import app                                             # noqa: E402

LOCAL = os.environ["COCKSCALE_URL"]

# zápisy do sdíleného adresáře se sledují: pořadí i to, že se publikují
# přejmenováním (jiný způsob by sidecaru podstrčil rozepsaný soubor)
WRITES = []
_orig_write_state = app.write_state
_orig_replace = os.replace


def spy_write_state(path, data):
    WRITES.append(("write", os.path.basename(path)))
    return _orig_write_state(path, data)


def spy_replace(src, dst):
    WRITES.append(("replace", os.path.basename(str(dst))))
    return _orig_replace(src, dst)


app.write_state = spy_write_state
os.replace = spy_replace


def writes(*names):
    """Zápisy do sdíleného adresáře sítě, ostatní stav se ignoruje.

    Dočasné soubory se nesledují: write_state() je pojmenovává podle vlákna
    (`authkey.tmp140234`), takže výčet `jméno + ".tmp"` by stejně nic nechytil.
    Že po zápisu nezůstal rozepsaný soubor, se kontroluje výpisem adresáře."""
    return [w for w in WRITES if w[1] in names]


# --- 1. tvar požadavku -------------------------------------------------------

print("1. tvar požadavku")
reset()
script({"status": 200, "body": ok_body(LOCAL)})
res = app.partner_post("/partner/gateway-key", 5)
req = seen()[0] if seen() else {}
check("POST na /partner/gateway-key", req.get("path") == "/partner/gateway-key"
      and req.get("method") == "POST", req)
check("hlavička Authorization: Bearer", req.get("auth", "").startswith("Bearer "))
check("Content-Length: 0 a prázdné tělo",
      req.get("length") == "0" and req.get("body") == b"")
check("bez chunked", not req.get("encoding"))
check("200 je úspěch", res["ok"] and res["status"] == 200)

# --- 2. chybové stavy a hlášky ----------------------------------------------

print("2. chybové stavy")
cases = [
    ("401 bad_token", {"status": 401, "body": {"error": "bad_token"}},
     "bad_token", "nov"),
    ("403 no_credits", {"status": 403, "body": {"error": "no_credits"}},
     "no_credits", "kredit"),
    ("403 account_deleting",
     {"status": 403, "body": {"error": "account_deleting"}},
     "account_deleting", "ruší"),
    ("409 gateway_exists", {"status": 409, "body": {"error": "gateway_exists"}},
     "gateway_exists", "odregistruj"),
]
for name, rec, err, needle in cases:
    reset()
    script(rec)
    res = app.partner_post("/partner/gateway-key", 5)
    check(name, (not res["ok"]) and res["error"] == err
          and needle.lower() in res["message"].lower(), res)

reset()
script({"status": 403, "body": {"error": "device_limit", "allowed": 1,
                                "limited_by": "credits"}})
res = app.partner_post("/partner/gateway-key", 5)
check("403 device_limit nese allowed a limited_by",
      res["allowed"] == 1 and res["limited_by"] == "credits")
check("hláška o stropu ukazuje číslo i cestu ven",
      "1" in res["message"] and "obij" in res["message"], res["message"])

reset()
script({"status": 403, "body": {"error": "device_limit", "allowed": 5,
                                "limited_by": "devices"}})
res = app.partner_post("/partner/gateway-key", 5)
check("limited_by=devices vede na uvolnění místa",
      "odregistrov" in res["message"], res["message"])

reset()
script({"status": 429, "body": {"status": "rate_limited", "reason": "burst"},
        "headers": {"Retry-After": "2"}})
res = app.partner_post("/partner/gateway-key", 5)
check("429 s Retry-After 2 s se zvedne na dolní mez 5 s",
      res["retry_after"] == 5, res["retry_after"])
check("429 má vlastní hlášku", "%d s" % 5 in res["message"], res["message"])

reset()
script({"status": 429, "body": {"status": "rate_limited"},
        "headers": {"Retry-After": "Wed, 21 Oct 2099 07:28:00 GMT"}})
res = app.partner_post("/partner/gateway-key", 5)
check("nečíselné Retry-After = 60 s", res["retry_after"] == 60,
      res["retry_after"])

reset()
script({"status": 502, "body": {"error": "coordinator"}})
res = app.partner_post("/partner/gateway-key", 5)
check("5xx není úspěch", (not res["ok"]) and res["status"] == 502)

reset()
script({"status": 200, "ctype": "text/plain", "body": "OK"})
res = app.partner_post("/partner/gateway-key", 5)
check("200 bez JSON se bere jako nesrozumitelná odpověď",
      (not res["ok"]) and res["kind"] == "nojson", res)

reset()
script({"status": 504, "ctype": "text/html",
        "body": "<html><head><title>504 Gateway Time-out</title></head></html>"})
res = app.partner_post("/partner/gateway-key", 5)
check("HTML 504 od edge = bez JSON", res["kind"] == "nojson"
      and res["status"] == 504, res)
check("z HTML se nečte error", res["error"] == "")

reset()
script({"status": 200, "body": ok_body(LOCAL), "delay": 3})
start = time.time()
res = app.partner_post("/partner/gateway-key", 1)
took = time.time() - start
check("ticho do timeoutu končí vlastními hodinami",
      res["kind"] == "timeout" and not res["ok"], res)
check("timeout platí na celé volání (< 2 s)", took < 2, "%.1f s" % took)

reset()
script({"status": 302, "ctype": "", "body": b"",
        "headers": {"Location": "http://127.0.0.1:%d/jinam" % PORT}},
       {"status": 200, "body": ok_body(LOCAL)})
res = app.partner_post("/partner/gateway-key", 5)
check("přesměrování se nenásleduje (token by odešel jinam)",
      len(seen()) == 1 and not res["ok"] and res["status"] == 302,
      (len(seen()), res["status"]))

reset(token="")
res = app.partner_post("/partner/gateway-key", 5)
check("bez tokenu se nikam nevolá", res["kind"] == "no_token" and not seen())

# --- 3. předání klíče brány sidecaru ----------------------------------------

print("3. klíč brány do sdíleného adresáře")
reset(want_key=True)
WRITES[:] = []
script({"status": 200, "body": ok_body(LOCAL)})
res = app.request_gateway_key("test")
check("úspěšné vyžádání klíče", res["ok"], res.get("message"))
check("klíč leží v authkey a končí koncem řádku",
      open(ts("authkey")).read() == GOOD_KEY + "\n")
meta = dict(line.split("=", 1) for line in
            open(ts("key_meta")).read().splitlines() if "=" in line)
check("metadata mají původ gateway", meta.get("origin") == "gateway")
check("metadata nesou adresu z odpovědi", meta.get("login_server") == LOCAL,
      meta)
check("metadata nesou platnost jako unix čas",
      meta.get("expires_epoch", "").isdigit()
      and int(meta["expires_epoch"]) > time.time(), meta)
check("metadata nesou čas vydání", meta.get("issued_epoch", "").isdigit())
check("metadata nesou značku brány", meta.get("tag") == "tag:c-abc123", meta)
check("v metadatech není klíč", GOOD_KEY not in open(ts("key_meta")).read())
order = writes("key_meta", "authkey")
check("metadata se píšou PŘED klíčem",
      order[:1] == [("write", "key_meta")] and ("write", "authkey") in order
      and order.index(("write", "key_meta")) < order.index(("write", "authkey")),
      order)
check("oba soubory se publikují přejmenováním",
      ("replace", "key_meta") in order and ("replace", "authkey") in order,
      order)
check("po zápisu klíče už značka want_key není",
      not os.path.exists(ts("want_key")))
leftovers = [n for n in os.listdir(app.TS_DIR) if ".tmp" in n]
check("po sobě nezůstal rozepsaný soubor", leftovers == [], leftovers)
check("klíč má práva jen pro vlastníka",
      oct(os.stat(ts("authkey")).st_mode & 0o777) == "0o600")

reset(want_key=True)
script({"status": 200, "body": ok_body(LOCAL, expires=None, tag="nesmysl")})
res = app.request_gateway_key("test")
meta = dict(line.split("=", 1) for line in
            open(ts("key_meta")).read().splitlines() if "=" in line)
check("bez platnosti v odpovědi se dopočítá hodina",
      abs(int(meta["expires_epoch"]) - time.time() - 3600) < 60, meta)
check("neznámá značka se zahodí, ne zapíše", meta.get("tag") == "", meta)

reset(want_key=True)
script({"status": 200, "body": {"key": "krátký", "login_server": LOCAL}})
res = app.request_gateway_key("test")
check("klíč v neznámém tvaru se nepřevezme",
      (not res["ok"]) and res["kind"] == "badkey"
      and not os.path.exists(ts("authkey")), res)

reset(want_key=True)
script({"status": 200, "body": ok_body("https://nekdo-jiny.example")})
res = app.request_gateway_key("test")
check("cizí adresa pro přihlášení se odmítne",
      (not res["ok"]) and res["kind"] == "badlogin"
      and not os.path.exists(ts("authkey")), res)

check("zabezpečená adresa téhož koordinátora projde",
      app.partner_login_ok(LOCAL.replace("http://", "https://")))
check("nezabezpečená adresa jinam neprojde",
      not app.partner_login_ok("http://127.0.0.1:1/jinam"))

# --- 4. kdy se volat nesmí ---------------------------------------------------

print("4. kdy se volat nesmí")
reset(state="backend=Running\npeers=3\nupdated=%d\n" % int(time.time()),
      want_key=True)
script({"status": 200, "body": ok_body(LOCAL)})
res = app.request_gateway_key("test")
check("připojená brána klíč nežádá",
      res["kind"] == "running" and not seen(), res)
check("při Running se nic nezapíše", not os.path.exists(ts("authkey")))

reset(state="backend=Running\npeers=0\nupdated=%d\n" % (int(time.time()) - 600),
      want_key=True)
script({"status": 200, "body": ok_body(LOCAL)})
res = app.request_gateway_key("test")
check("zastaralý stav neblokuje (starší než 45 s je neznámo)",
      res["ok"] and len(seen()) == 1, res)

reset(state="backend=NeedsLogin\npeers=-1\nupdated=%d\n" % int(time.time()),
      want_key=True)
script({"status": 200, "body": ok_body(LOCAL)})
res = app.request_gateway_key("test")
check("NeedsLogin klíč vyžádá", res["ok"] and len(seen()) == 1)

# --- 5. vlákno na pozadí: fronta, jednorázovost, prodlevy -------------------

print("5. vlákno na pozadí")
reset(want_key=True)
script({"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("značka want_key spustí právě jedno volání", len(seen()) == 1, seen())
check("klíč se předal", os.path.exists(ts("authkey")))
check("značka key_pending po sobě nezůstala",
      not os.path.exists(ts("key_pending")))
last = app.gateway_last_read()
check("záznam o pokusu nese stav 200", last.get("status") == "200", last)
check("v záznamu o pokusu není klíč ani token",
      GOOD_KEY not in open(app.gateway_last_path()).read()
      and "cspk_" not in open(app.gateway_last_path()).read())

reset()
script({"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("bez want_key a bez stisku se nevolá", not seen())

reset(state="backend=Running\npeers=2\nupdated=%d\n" % int(time.time()),
      want_key=True)
script({"status": 200, "body": ok_body(LOCAL)})
msg = app.gateway_request()
app.gateway_tick()
check("stisk u připojené brány jen vysvětlí, že klíč netřeba",
      "už v síti" in msg and not seen(), (msg, seen()))
check("připojená brána se nepočítá do stropu za hodinu",
      not app._gw["calls"], app._gw["calls"])

reset()
script({"status": 200, "body": ok_body(LOCAL)},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_request()
app.gateway_request()
app.gateway_tick()
app.gateway_tick()
check("dvojí stisk = jedno volání", len(seen()) == 1, seen())

reset(want_key=True)
app.write_state(ts("key_pending"), "%d\n" % int(time.time()))
script({"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("běžící pokus druhý nespustí", not seen())
os.utime(ts("key_pending"), (time.time() - 3600, time.time() - 3600))
app.gateway_tick()
check("osiřelá značka po pádu volání neblokuje navždy", len(seen()) == 1)

reset(want_key=True)
script({"status": 403, "body": {"error": "no_credits"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("chybějící kredit odloží další pokus o minuty",
      280 < app._gw["next_try"] - time.time() <= 300,
      app._gw["next_try"] - time.time())
app.gateway_tick()
check("druhý pokus se do prodlevy nevejde", len(seen()) == 1, seen())
check("záznam nese kód chyby",
      app.gateway_last_read().get("error") == "no_credits")

reset(want_key=True)
script({"status": 502, "body": {"error": "coordinator"}},
       {"status": 502, "body": {"error": "coordinator"}})
app.gateway_tick()
first = app._gw["backoff"]
app._gw["next_try"] = 0.0
app.gateway_tick()
check("dočasná chyba prodlevu zdvojuje",
      first == 30 and app._gw["backoff"] == 60,
      (first, app._gw["backoff"]))

reset(want_key=True)
script({"status": 401, "body": {"error": "bad_token"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("neplatný token vlákno zastaví", app._gw["stop"] == "bad_token")
msg = app.gateway_request()
check("stisk s neplatným tokenem jen poradí", "nov" in msg.lower(), msg)
app.gateway_tick()
check("po neplatném tokenu se dál netočí", len(seen()) == 1, seen())
app.gateway_backoff_clear()
app.gateway_request()
app.gateway_tick()
check("uložení nového tokenu zákaz zruší", len(seen()) == 2, seen())

reset(want_key=True)
script({"status": 409, "body": {"error": "gateway_exists"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("409 odloží pokus o hodinu",
      3500 < app._gw["next_try"] - time.time() <= 3600)
app.gateway_request()
app.gateway_tick()
check("stisk po odregistrování staré brány čekat nenechá", len(seen()) == 2)

reset(want_key=True)
script({"status": 403, "body": {"error": "account_deleting"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
app.gateway_request()
app.gateway_tick()
check("rušení účtu se stiskem uspíšit nedá", len(seen()) == 1, seen())

reset(want_key=True)
script({"status": 403, "body": {"error": "device_limit", "allowed": 1,
                                "limited_by": "credits"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("chybějící kredit u stropu zastaví automatické opakování",
      app._gw["auto_off"] == "credits")
app._gw["next_try"] = 0.0
app.gateway_tick()
check("automaticky se pak už nevolá", len(seen()) == 1, seen())
app.gateway_request()
app.gateway_tick()
check("stisk po dobití volání pustí", len(seen()) == 2)

reset(want_key=True)
script(*[{"status": 502, "body": {"error": "coordinator"}} for _ in range(9)])
for _ in range(8):
    app._gw["next_try"] = 0.0
    app.gateway_tick()
check("strop žádostí za hodinu se uplatní",
      len(seen()) == app.GATEWAY_HOURLY_MAX and app._gw["auto_off"] == "rate",
      len(seen()))
app.gateway_request()
app.gateway_tick()
check("stisk strop obejde", len(seen()) == app.GATEWAY_HOURLY_MAX + 1)

# Strop je klouzavé okno: kdyby se zákaz nerušil sám, vlákno by po šesti
# marných pokusech (~25 min) přestalo hlídat want_key navždy.
reset(want_key=True)
script(*[{"status": 502, "body": {"error": "coordinator"}} for _ in range(9)])
for _ in range(7):
    app._gw["next_try"] = 0.0
    app.gateway_tick()
check("strop zastaví automatiku", app._gw["auto_off"] == "rate"
      and len(seen()) == app.GATEWAY_HOURLY_MAX, len(seen()))
app._gw["calls"] = [t - 3700 for t in app._gw["calls"]]   # hodina uplynula
app._gw["next_try"] = 0.0
app.gateway_tick()
check("po hodině se automatické pokusy zase rozjedou",
      len(seen()) == app.GATEWAY_HOURLY_MAX + 1 and not app._gw["auto_off"],
      (len(seen()), app._gw["auto_off"]))

# Úspěch znamená, že důvod zákazu pominul — jinak by ovládání příští want_key
# od sidecaru (odregistrovaná brána) ignorovalo navždy.
reset(want_key=True)
script({"status": 403, "body": {"error": "device_limit", "allowed": 1,
                                "limited_by": "credits"}},
       {"status": 200, "body": ok_body(LOCAL)},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
check("chybějící kredit u stropu zastaví automatiku",
      app._gw["auto_off"] == "credits")
app.gateway_request()           # uživatel dobil a zmáčkl tlačítko
app.gateway_tick()
check("po úspěchu se auto_off ruší",
      len(seen()) == 2 and not app._gw["auto_off"] and not app._gw["error"],
      (app._gw["auto_off"], app._gw["error"]))
app.write_state(ts("want_key"), "reason=needs_login\nsince=%d\n"
                % int(time.time()))
app._gw["next_try"] = 0.0
app.gateway_tick()
check("po úspěchu vlákno hlídá want_key dál", len(seen()) == 3, seen())

# Prodlevy musí přežít restart ovládání, jinak by se restartem obcházely
reset(want_key=True)
script({"status": 409, "body": {"error": "gateway_exists"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
planned = app._gw["next_try"]
app.gateway_backoff_clear()     # restart ovládání: paměť procesu je prázdná
app._gw["calls"] = []
app.gateway_state_restore()
check("prodleva po 409 přežije restart ovládání",
      abs(app._gw["next_try"] - planned) < 2, (app._gw["next_try"], planned))
app.gateway_tick()
check("po restartu se do prodlevy nevolá", len(seen()) == 1, seen())

reset(want_key=True)
script({"status": 401, "body": {"error": "bad_token"}},
       {"status": 200, "body": ok_body(LOCAL)})
app.gateway_tick()
app.gateway_backoff_clear()
app.gateway_state_restore()
check("zákaz po neplatném tokenu přežije restart",
      app._gw["stop"] == "bad_token")
app.gateway_tick()
check("po restartu se s neplatným tokenem nevolá", len(seen()) == 1, seen())

# Ruční klíč a klíč z vlákna si nesmějí proložit dvojici metadata+klíč
reset()
app._key_lock.acquire()
th = threading.Thread(target=app.hand_key_over,
                      args=(GOOD_KEY, "manual", LOCAL, time.time() + 3600),
                      daemon=True)
th.start()
time.sleep(0.3)
held = not os.path.exists(ts("key_meta")) and not os.path.exists(ts("authkey"))
app._key_lock.release()
th.join(3)
check("ruční klíč čeká, dokud druhá cesta dvojici nedopíše",
      held and os.path.exists(ts("authkey"))
      and os.path.exists(ts("key_meta")), held)

# --- 6. klíč telefonu jde stejnou cestou ------------------------------------

print("6. klíč telefonu")
reset()
script({"status": 200, "body": {"key": GOOD_KEY, "login_server": LOCAL}})
key, login, err = app.request_network_key()
check("klíč telefonu se převezme",
      key == GOOD_KEY and login == LOCAL and not err, (key, login, err))
check("klíč telefonu jde na /partner/preauthkeys",
      seen()[0]["path"] == "/partner/preauthkeys")

reset(token="")
key, login, err = app.request_network_key()
check("bez tokenu se QR omezí na účet a nehlásí chybu",
      key == "" and err == "" and not seen())

# --- 7. co smí stav sítě tvrdit ---------------------------------------------

print("7. co smí stav sítě tvrdit")
NOW = int(time.time())

reset(state="backend=Running\npeers=0\ntags=tag:c-ab12\nupdated=%d\n" % NOW)
app.write_state(ts("ip"), "100.64.0.5\n")
ns = app.net_state()
check("prázdná netmapa bez opory netvrdí chybějící kredit",
      ns["state"] == "paused" and not ns["paused_credits"]
      and "kredit" not in ns["detail"], ns["detail"])
check("čerstvě připojená brána bez telefonu neblokuje párování",
      ns["ready"] and "telefon" in ns["detail"], ns["detail"])

app.gateway_last_write({"kind": "http", "status": 403, "error": "no_credits"},
                       0)
ns = app.net_state()
check("s odpovědí koordinátora se kredit tvrdit smí",
      ns["state"] == "paused" and ns["paused_credits"]
      and "kredit" in ns["detail"], ns["detail"])

reset(state="backend=NeedsLogin\npeers=-1\nupdated=%d\n" % (NOW - 600))
app.hand_key_over(GOOD_KEY, "gateway", LOCAL, NOW + 3600, "tag:c-ab12")
ns = app.net_state()
check("nepřevzatý klíč při mlčící službě sítě se neschovává za „Připojuji“",
      ns["state"] == "connecting" and "nehlásí" in ns["detail"], ns["detail"])

reset(state="backend=NeedsLogin\npeers=-1\nupdated=%d\n" % NOW)
app.hand_key_over(GOOD_KEY, "gateway", LOCAL, NOW - 60, "tag:c-ab12")
ns = app.net_state()
check("prošlý nepřevzatý klíč je chyba, ne průběh",
      ns["state"] == "error" and "propadl" in ns["detail"], ns["detail"])

reset(state="backend=Starting\npeers=-1\nupdated=%d\n" % NOW)
app.hand_key_over(GOOD_KEY, "gateway", LOCAL, NOW + 3600, "tag:c-ab12")
ns = app.net_state()
check("čerstvé hlášení do stavu žádnou výtku nepřidá",
      ns["state"] == "connecting" and "nehlásí" not in ns["detail"],
      ns["detail"])

# --- závěr -------------------------------------------------------------------

os.replace = _orig_replace
app.write_state = _orig_write_state
srv.shutdown()
shutil.rmtree(TMP, ignore_errors=True)

print("\n%d kontrol, %d selhalo" % (CHECKS[0], len(FAILURES)))
if FAILURES:
    for name in FAILURES:
        print("  - %s" % name)
    sys.exit(1)
print("vše OK")
