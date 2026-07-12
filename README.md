# GSM2SIP — GSM/VoLTE ↔ VoIP brána (Asterisk + chan_quectel)

Raspberry Pi 4 / umbrelOS drží českou SIM v LTE modemu **výrobce modem‑H**
a přemosťuje hlasové hovory mezi mobilní sítí a SIP. Ze zahraničí se přes
tunel zaregistruje softphone (Linphone) a přijímá i vytáčí hovory na českém
čísle za domácí ceny.

**Klíčová technická fakta (ověřená, neměnit):** audio jde přes **sériový PCM
port** modemu (ttyUSB4, 8 kHz/16 bit, kodek `slin`) — žádné USB audio, žádná ALSA,
žádný `/dev/snd`. Kontejner nepotřebuje `privileged`, stačí dva `devices:`
a `group_add: ["20"]` (dialout). Jediný host-level zásah je vypnutí
ModemManageru (`host-setup.sh`). Nikdy nespouštět `zakázaný AT příkaz`.

---

## Architektura (výsledek Fáze 0.5 — analýza zdrojáků umbreldu)

Ověřeno ve zdrojácích umbrelOS 1.7.4 (beze změny od 1.0): **umbreld compose
soubory appek nijak nefiltruje.** Jediná mutace je `patchComposeFile()`
(doplní `container_name`, zmigruje staré cesty volumes, volitelně přidá GPU
device) a pak legacy `app-script` pouští `docker compose` s vrstvením
souborů, kde **compose appky je poslední a vyhrává**. Síť se nevnucuje —
`docker-compose.common.yml` jen přesměrovává *default* network; služba s
`network_mode: host` se defaultu neúčastní.

`devices:` i `network_mode: host` tedy **projdou beze změny**. Precedenty
přímo v oficiálním storu: `tailscale` (`devices:` + host net),
`home-assistant`, `adguard-home`, `openthread-border-router`; community
Big Bear `zigbee2mqtt` mapuje přesně náš vzor `devices:
/dev/serial/by-id/...`.

**Rozhodnutí:** brána půjde jako regulérní Umbrel appka **GSM2SIP**
(id `eddie-gsm2sip` — ID musí mít prefix storu). Potvrzující test na zařízení
je připravený v `eddie-passthrough-test/` (viz níže). Do potvrzení běží vývoj
Fází 1–5 jako **samostatný compose stack** (mimo umbreld) — funguje v obou
architekturách beze změny, liší se jen místo, kam se generuje konfigurace.

**Community store žije v samostatném repu**
[`Eddie/umbrel-store`](https://it-one.cz/git/Eddie/umbrel-store) (id `eddie`,
stejný vzor jako med-O-mat): tam patří jen `umbrel-app-store.yml` + adresáře
appek. Zdrojová podoba appek žije tady v projektovém repu a do storu se
kopíruje při publikaci. Store repo musí zůstat veřejné — umbreld ho klonuje
anonymně přes HTTPS.

### Fáze 0.5 — potvrzující test na zařízení

1. Zkopírovat `eddie-passthrough-test/` z tohoto repa do kořene
   `Eddie/umbrel-store` a pushnout.
2. Umbrel UI → App Store → menu (⋮) → **Community App Stores** →
   `https://it-one.cz/git/Eddie/umbrel-store` (pokud tam z med-O-matu už je,
   jen Update) → Open → nainstalovat **Passthrough Test (Fáze 0.5)**.
3. Přečíst výsledek (předpoklad: modem připojen — `host-setup.sh` krok 2 OK):
   ```bash
   sudo docker logs eddie-passthrough-test_test_1
   ```
   - `DEVICES: OK` + `crw-rw---- ... 188, 2 ... /dev/ttyUSB2` → devices prošly.
   - V `ip -4 addr` je vidět LAN IP hosta (ne 10.21.x.x docker síť) → host net prošel.
   - `No such container` → kontejner nevznikl, protože na hostu chybí by-id
     device (modem odpojen / jiná kompozice) — chyba hardwaru, **ne** umbreldu.
4. Appku odinstalovat. Výsledek rozhoduje: OK → cílová distribuce je Umbrel
   appka; FAIL (nečekané) → zůstává samostatný stack a chybu reportovat.

---

## Instalace (samostatný stack na umbrelOS)

Předpoklad: repo nakopírované na Pi (např. `~/GSM2SIP`), modem připojený
přes externě napájený hub, uživatel `umbrel` používá `sudo docker`.

```bash
cd ~/GSM2SIP

# 1) Host: vypnout ModemManager, ověřit porty a ATI (idempotentní)
sudo ./host-setup.sh

# 2) Parametry
cp .env.example .env && chmod 600 .env
$EDITOR .env            # SIP_USER, silné SIP_PASSWORD (openssl rand -base64 24)

# 3) Vygenerovat runtime konfiguraci (jednou; přegenerování jen --force)
./configure.sh

# 4) Start
sudo docker compose up -d
```

> **Proč generovaná konfigurace:** umbreld při updatu appky přepisuje obsah
> adresáře appky a hesla nesmí do gitu. Šablony v `asterisk/` jsou v repu,
> `configure.sh` je s dosazeným uživatelem/heslem jednorázově vyrenderuje do
> `runtime/asterisk/` (mimo git; u Umbrel appky později do `app-data`) a dál
> se nechávají být. Ruční změny se dělají v šablonách + `--force`, nebo přímo
> v runtime souborech (přežijí update repa, nepřežijí `--force`).

## Ověření — brány jednotlivých fází

### Fáze 1 — Asterisk vidí modem
```bash
sudo docker exec -it asterisk asterisk -rx 'module show like quectel'
sudo docker exec -it asterisk asterisk -rx 'quectel show devices'
```
**Gate:** `Voice: Yes`, zařízení inicializované. Bez SIM je „not registered" —
to je v pořádku.

### Fáze 2 — SIM a VoLTE
modem **nedetekuje SIM za běhu** — po vložení SIM restartovat napájení
modulu. Pak z hosta (kontejner stopnout, ať nedrží port) nebo přes
`asterisk -rx 'quectel cmd quectel0 AT+...'`:

```
AT+CMEE=2      ; verbózní chyby
AT+CPIN?       ; READY (PIN raději úplně vypnout: AT+CLCK="SC",0,"<pin>")
AT+CFUN?       ; 1
AT+CSQ         ; 99,99 = žádný signál -> zkontroluj MAIN anténu
AT+CNMP?       ; preferovaný režim sítě
AT+CVOLTE?     ; VoLTE — u firmwaru 2021 často vypnutá, bez ní LTE hovor nenaskočí
AT+COPS?       ; operátor
AT+CEREG?      ; 0,1 nebo 0,5 = registrován
```
**Gate:** registrace v LTE + aktivní VoLTE. Přesné příkazy zapnutí VoLTE pro
daného operátora zdokumentovat sem, až budou ověřené na místě.

### Fáze 3 — SIP endpoint
```bash
sudo docker exec -it asterisk asterisk -rx 'pjsip show endpoints'
```
Linphone nejdřív **na domácí LAN**: SIP účet `SIP_USER@<IP-Pi>`, transport
**TCP** (UDP je v pjsip.conf záměrně vypnutý), heslo z `.env`.
**Gate:** endpoint ukazuje registrovaný kontakt.

Rychlý test zvuku SIP větve bez SIM: zavolat **600** (echo test).

### Fáze 4 — hovory oběma směry (na LAN)
Odchozí: vytočit číslo ze softphonu (národní i `+420...` formát projde).
Příchozí: zavolat na číslo SIM → zvoní softphone. Testovat: zvuk oběma směry,
DTMF, korektní zavěšení z obou stran, hlasitost/echo (doladit `rxgain`/`txgain`
v `quectel.conf`, případně `AT+CPCMFRM`).

> **Známý problém — hangup detection:** modem nemá spolehlivý URC o ukončení
> hovoru; bez `ccinfo`/`dsci` (RoEdAl fork chan_quectel) zůstávají viset
> kanály. Pokud to image `starší image` neumí,
> bude potřeba postavit vlastní image z `github.com/RoEdAl/asterisk-chan-quectel`
> — řešit ve Fázi 4, až se to projeví.

### Fáze 5 — vzdálený přístup

**Režim A (default, implementovaný): tunel + Linphone.**
1. Tunel — na Pi už běží **Nostr VPN** (Umbrel appka, mesh nad WireGuardem,
   rozhraní utun100, IP 10.44.170.108): první volba je připojit telefon
   invitem do téhle mesh sítě. Ověřit klienta na GrapheneOS a spolehlivost
   na pozadí; fallback je **Tailscale** z Umbrel storu (nebo WireGuard).
2. Linphone: SIP účet na **tailscale IP Pi**, transport **TCP** (ne UDP —
   delší NAT keepalive, méně probouzení rádia), registration expiry např.
   3600 s, zapnout background mode / foreground service + výjimka
   z optimalizace baterie. Na GrapheneOS spolehlivé, cena je baterie.
3. **Na veřejné IP není otevřený žádný SIP port** — žádný port forward.
   Push notifikace v tomto režimu **nefungují a fungovat nemůžou** (SIPIS
   potřebuje veřejně dosažitelný server) — nezkoušet.

**Gate:** registrace + hovor oběma směry přes tunel; scan veřejné IP
neukazuje 5060/5061.

**Režim B (upgrade cesta — jen dokumentace, neimplementováno):**
Acrobits **Groundwire/Softphone** s push infrastrukturou SIPIS (baterie ~0):
- Podmínka: SIP server **veřejně dosažitelný** — SIPIS drží registraci místo
  telefonu.
- Zabezpečení: výhradně **TLS** transport, silné heslo, **IP allowlist**:
  rozsah tunelu + IP adresy SIPIS (dohledatelné přes DNS
  `all.sipis.acrobits.cz`). Všechno ostatní zahodit.
- **Stejný seznam SIPIS IP dát do ignorelistu fail2ban** — jinak SIPIS
  dostane ban a hovory tiše přestanou zvonit (nejčastější příčina „nezvoní
  to" u Groundwire).
- Čistší varianta: SIP registrar na okrajovém VPS; domácí Asterisk se k němu
  registruje **odchozím** spojením — doma se nic neforwarduje. (Jen popis,
  neimplementovat.)

---

## Postup po updatu umbrelOS

Update umbrelOS může znovu povolit ModemManager a restartovat Docker:

```bash
cd ~/GSM2SIP
sudo ./host-setup.sh            # obnoví vypnutí ModemManageru, ověří porty + ATI
sudo docker compose up -d       # kdyby stack nenaběhl sám
sudo docker exec -it asterisk asterisk -rx 'quectel show devices'   # Voice: Yes
```

Konfigurace v `runtime/asterisk/` (resp. `app-data`) update přežívá —
`configure.sh` se znovu NEspouští (a bez `--force` by stejně nic nepřepsal).

## Bezpečnost

- **SIP (5060/5061) nikdy na veřejnou IP.** Default je tunel (Tailscale/
  WireGuard); jediná výjimka je režim B s TLS + IP allowlistem. Nespoléhat
  na SIP ALG routeru (spíš škodí — na routeru vypnout).
- Hesla jen v `.env` (chmod 600) a ve vygenerovaném `runtime/asterisk/`
  (640 + chown na UID asteriska v kontejneru; když UID nejde zjistit, fallback
  644 — viz configure.sh) — nikdy v gitu.
- SIP heslo min. 16 znaků: `openssl rand -base64 24`.
- SIM bez PINu = kdo ukradne SIM, volá. Kompromis: PIN vypnutý, ale SIM je
  fyzicky doma; zvážit limit u operátora.

## Zálohování

Stačí zálohovat dvě věci (obě mimo git):
- `.env`
- `runtime/asterisk/` (vygenerovaná konfigurace, případné ruční doladění)

Obnova = nakopírovat repo + tyto dva kusy, `sudo ./host-setup.sh`,
`sudo docker compose up -d`.

## Struktura repa

```
docker-compose.yml          # stack (network host, devices by-id, group_add 20)
.env.example                # parametry -> .env (negitované)
configure.sh                # šablony + .env -> runtime konfigurace (jednorázově)
host-setup.sh               # jediný host zásah: ModemManager + ověření modemu
asterisk/                   # ŠABLONY konfigurace (tokeny ${SIP_USER}/${SIP_PASSWORD})
  quectel.conf              #   modem: data=ttyUSB2, audio=ttyUSB4 (PCM), žádné USB audio
  pjsip.conf                #   transporty UDP/TCP (+TLS připraveno), 1 endpoint
  extensions.conf           #   dialplan oba směry + echo test 600 + SMS stub (F6)
  modules.conf, rtp.conf, logger.conf
eddie-passthrough-test/     # Fáze 0.5 — test devices + host net (zdroj; publikuje
                            # se kopií do repa Eddie/umbrel-store)
```

## Známá omezení

- Docker rozbalí `by-id` symlink při vytvoření kontejneru — po odpojení/
  zapojení modemu `sudo docker restart asterisk`. (Robustní varianta
  `device_cgroup_rules: ['c 188:* rmw']` + mount `/dev` — vzor oficiální
  appky `ee-gateway` — zatím neřešit.)
- Sériové číslo v by-id cestě je u výrobce placeholder (`0123456789ABCDEF`,
  stejné na všech kusech) — u jednoho modemu nevadí.
- Diakritika v SMS = UCS‑2, 70 znaků/segment (Fáze 6).

## Fáze 6 (zatím neimplementováno)

SMS ↔ Signal přes OneGW (paralelní projekt, drží celou Signal stranu).
Na bráně vznikne: dialplan SMS hook → HTTP POST na OneGW (fronta + retry,
2FA kódy nesmí zapadnout), HTTP shim pro odchozí SMS, ošetření
alfanumerických odesílatelů a vícedílných SMS. Prostudovat existující API
OneGW, nevymýšlet nový kontrakt. Plus zabalení jako Umbrel appka **GSM2SIP**
(id `eddie-gsm2sip`) do tohoto storu.
