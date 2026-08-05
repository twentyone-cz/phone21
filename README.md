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
[`Eddie/umbrel-store`](https://github.com/twentyone-cz/umbrel-store) (id `eddie`,
stejný vzor jako med-O-mat): tam patří jen `umbrel-app-store.yml` + adresáře
appek. Zdrojová podoba appek žije tady v projektovém repu a do storu se
kopíruje při publikaci. Store repo musí zůstat veřejné — umbreld ho klonuje
anonymně přes HTTPS.

### Fáze 0.5 — potvrzující test na zařízení

1. Zkopírovat `eddie-passthrough-test/` z tohoto repa do kořene
   `Eddie/umbrel-store` a pushnout.
2. Umbrel UI → App Store → menu (⋮) → **Community App Stores** →
   `https://github.com/twentyone-cz/umbrel-store` (pokud tam z med-O-matu už je,
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

# 3) Build image (Asterisk 20 + RoEdAl chan_quectel; poprvé ~5-10 min)
sudo docker compose build

# 4) Vygenerovat runtime konfiguraci (jednou; přegenerování jen --force)
./configure.sh

# 5) Start
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
**Gate: SPLNĚNA — VoLTE FUNGUJE (2026-08-04).** IMS registrace `registered`,
voice/SMS over IMS `available`, hovor zůstává na LTE (ověřeno `+CPSI?` během
aktivního hovoru). Byly to TŘI zámky najednou a musely povolit všechny:
1. **MBN profil profil** místo autoselectnutého profil —
   automaticky ho vybírá a drží `scripts/mbn-profile.sh` (tabulka
   operátor→profil, `MBN_PROFILE` v `.env`; instalace systemd služby:
   `sudo scripts/install-mbn.sh`);
2. **QMI přístup z LXC** (`/dev/cdc-wdm0` passthrough) pro správu profilů
   a diagnostiku (`--imsa-get-ims-registration-status`);
3. **provisioning linky u operátora** — TMCZ aktivuje VoLTE na lince až po
   prvním připojení známého VoLTE telefonu; testovací SIM nikdy v telefonu
   nebyla → vložit SIM do telefonu, zapnout VoLTE, zavolat, vrátit do
   modemu (pozor: výměna SIM = přepojit USB modemu + reboot LXC).

Zjištění a stav (modem firmware…M22, testovací T-Mobile CZ SIM):
- firmware VoLTE zapnuté (`AT+VOLTESETTING?` → 1), síť IMS PDN přiděluje
  (cid 2 „ims" aktivní s adresou) a buňka hlásí **VoPS „IMS voice support:
  yes"** (`qmicli --nas-get-system-info`); voice domain je `ps-preferred`,
  usage `voice-centric` (`--nas-get-system-selection-preference`),
- přesto **IMS registrace neproběhne**: `qmicli
  --imsa-get-ims-registration-status` → `not-registered`, voice/SMS over
  IMS `unavailable` (zajímavost: „UE to TAS" služba available); v LTE-only
  (`AT+CNMP=38`) se hovor vůbec nesestaví, v auto režimu vše CSFB,
- **MBN carrier profily se spravují z Linuxu přes QMI PDC**: do LXC je
  protažené `/dev/cdc-wdm0` (v `/etc/pve/lxc/<id>.conf`:
  `lxc.cgroup2.devices.allow: c 180:* rwm` + `lxc.mount.entry:
  /dev/cdc-wdm0 …`), `apt install libqmi-utils`, `qmicli -d /dev/cdc-wdm0
  --pdc-list-configs=software`. firmware obsahuje 13 profilů (profil,
  **profil**, Orange, EE, VF_*, TF_Germany, Reliance, Airtel);
  autoselect podle SIM nemá pro TMCZ shodu → bootuje profil
  (mimochodem s AT&T zbytky v UT konfiguraci),
- aktivován **profil** (matka TMCZ) — přepnutí funguje za horka
  (`--pdc-deactivate-config` ROW + `--pdc-activate-config` DT, UTAPNCFG se
  změní); po resetu modemu ho autoselect vrací, drží ho proto systemd
  oneshot **`gsm2sip-mbn.service`** (`scripts/mbn-profile.sh auto` — výběr
  z tabulky operátor→profil dle home network SIM, `MBN_PROFILE` v `.env`),
- `+CIREG`/`+CAVIMS`/`+CVDP` firmware nemá; nedokumentované IMS příkazy:
  `+IMSREGDB`, `+IMSSIPCFG`, `+IMSSMSCFG`, `+UTAPNCFG` (viz `AT+CLAC`).

Otevřené kroky: (1) **provisioning testovací SIM** — ověřit VoLTE v běžném
telefonu (TMCZ aktivuje VoLTE na lince do 24 h po prvním VoLTE-schopném
zařízení); (2) pokud SIM OK a stále nic: plný boot s DT profilem (vypnout
mcfg autoselect — jen přes QPST/EFS), dotaz na Techship/výrobce support,
příp. MBN úpravy (mbn-mcfg-tools). Firmware neupgradovat — firmware je
poslední publikovaný a flash = jediné reálné riziko bricku. Diagnostika:
druhý AT port `/dev/ttyUSB3` z LXC (`./at.sh 'AT+…' /dev/ttyUSB3`), pozor
`AT+CNMP`/`AT+CRESET` vyhodí driver (restart kontejneru; po CRESET nutný
reboot LXC — bind mounty drží staré inody).

### Fáze 3 — SIP endpoint
```bash
sudo docker exec -it asterisk asterisk -rx 'pjsip show endpoints'
```
Linphone nejdřív **na domácí LAN**: SIP účet `SIP_USER@<IP-Pi>`, transport
**UDP** (primární; TCP je fallback pro velké requesty), heslo z `.env`.
**Gate:** endpoint ukazuje registrovaný kontakt.

Rychlý test zvuku SIP větve bez SIM: zavolat **600** (echo test).

### Fáze 4 — hovory oběma směry (na LAN)
Odchozí: vytočit číslo ze softphonu (národní i `+420...` formát projde).
Příchozí: zavolat na číslo SIM → zvoní softphone. Testovat: zvuk oběma směry,
DTMF, korektní zavěšení z obou stran, hlasitost/echo (doladit `rxgain`/`txgain`
v `quectel.conf`, případně `AT+CPCMFRM`).

> **Historie — proč vlastní image:** původní image `starší image`
> (starý chan_quectel) **segfaultoval Asterisk při odesílání DTMF** do modemu
> (reprodukováno: 4 pády v řadě, restart smyčkou) a neuměl `dsci` hangup
> detection. Default je proto vlastní build z RoEdAl forku (`docker/`),
> `quectel.conf` má `dsci=on` (modem neumí Quectel `ccinfo`). Pozor:
> RoEdAl změnil sémantiku `rxgain`/`txgain` (0 = ztlumeno, -1 = default).
>
> **Kritický detail buildu — `-Wl,-Bsymbolic`:** chan_quectel má interní
> funkce jako globální symboly (`channel_new`, `cpvt_alloc`, …) a volá je
> přes PLT. V procesu Asterisku je ale i `cizí knihovna`, která exportuje
> vlastní globální `channel_new` — bez `-Bsymbolic` linker navázal volání
> na cizí knihovna a všechny odchozí hovory padaly na „Unable to allocate channel
> structure" (cause 44), bez jediného užitečného logu. Stejná třída
> problému (kolize globálních symbolů chan_dongle/chan_quectel) je nejspíš
> i příčinou DTMF segfaultu původního image. Diagnostika: `objdump -d
> --disassemble=channel_request` (volání přes `@plt`) + sken `T channel_new`
> přes všechna DSO z `/proc/1/maps` (vyžaduje `docker exec --privileged` —
> proces po setuid není dumpable).

### Fáze 5 — vzdálený přístup

**Režim A (default, implementovaný): tunel + Linphone.**
1. Tunel — na Pi už běží **Nostr VPN** (Umbrel appka, mesh nad WireGuardem,
   rozhraní utun100, IP 10.44.170.108): první volba je připojit telefon
   invitem do téhle mesh sítě. Ověřit klienta na GrapheneOS a spolehlivost
   na pozadí; fallback je **Tailscale** z Umbrel storu (nebo WireGuard).
2. Linphone: SIP účet na **tunelové IP brány**, transport **UDP** — TCP se
   v praxi ukázal křehčí (doze zabíjí socket → flapování registrace, viz
   docs/telefon-gos.md „SIP transport a spolehlivost doručení"), registration
   expiry 600 s, zapnout background mode / foreground service + výjimka
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
- **Firewall** (`scripts/install-firewall.sh`, nftables): z internetu je
  vidět jen WireGuard, SIP/RTP jen z tunelu, SSH a web UI z LAN i tunelu.
  Protože stack běží v `network_mode: host`, bez firewallu poslouchá SIP na
  `0.0.0.0` a je dostupný z celé LAN. Detaily a rollback: `docs/lxc-deploy.md`.
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

## Web UI

`http://<IP-brány>:8090` (Basic auth, heslo `WEBUI_PASSWORD` z `.env`;
uživatel libovolný). Čtyři záložky: **Stav** (modem, RSSI, SIP registrace,
hovory, fronta, přepínač chování k volajícímu při offline telefonu —
vyzvánět naprázdno / hláska; drží se v AstDB na persistentním volume),
**SMS** (dekódovaný žurnál, fronta retry, ruční odeslání),
**Telefon** (QR s WireGuard configem pro telefon — endpoint se zadá v poli,
config se čte z `runtime/wg/phone-wg.conf`), **Diagnostika** (tail logu,
AT příkaz — `CUSBPIDSWITCH` blokován). Běží jako
kontejner `webui` (čistá Python stdlib), s Asteriskem mluví přes AMI na
localhostu. **Nikdy nevystavovat veřejně** — jen LAN/WireGuard.

## Struktura repa

```
docker-compose.yml          # stack (network host, devices by-id, group_add 20)
.env.example                # parametry -> .env (negitované)
configure.sh                # šablony + .env -> runtime konfigurace (jednorázově)
host-setup.sh               # jediný host zásah: ModemManager + ověření modemu
asterisk/                   # ŠABLONY konfigurace (tokeny ${SIP_USER}/${SIP_PASSWORD})
  quectel.conf              #   modem: data=ttyUSB2, audio=ttyUSB4 (PCM), žádné USB audio
  pjsip.conf                #   transporty UDP (primární) + TCP fallback, 1 endpoint
  extensions.conf           #   dialplan oba směry, normalizace na E.164
                            #   (COUNTRY_CODE z .env), zmeškané hovory do chatu;
                            #   testy: 600 echo, *981-983 chat, *984 normalizace,
                            #   *985 zmeškaný hovor, *99<číslo> SMS
  modules.conf, rtp.conf, logger.conf
scripts/                    # pomocné skripty na bráně
  sms-queue.sh              #   žurnál + retry fronta příchozích SMS
  firewall.nft              #   nftables pravidla (vlastní tabulka inet gsm2sip)
  install-firewall.sh       #   nasazení s rollback pojistkou proti odříznutí
  watchdog.sh               #   detekce zaseknutého driveru → restart kontejneru
  install-watchdog.sh       #   systemd timer pro watchdog
  mbn-profile.sh            #   MBN carrier profil dle operátora SIM (VoLTE)
  install-mbn.sh            #   systemd oneshot pro mbn-profile.sh auto
docker/patches/             # lokální patche chan_quectel (upstream archivovaný)
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
- Diakritika v odchozí SMS = UCS‑2, 70 znaků/segment.

## SMS ↔ Linphone

SMS jede přímo do/z vestavěného chatu v Linphone (žádný Signal, žádný externí
gateway). Detaily implementace a stav v `asterisk/extensions.conf`
(`[quectel-incoming]` exten `sms`/`report`, context `[messages]`):
- **Příchozí** (mobil → Linphone chat): SMS přijde jako zpráva od odesílatele.
- **Odchozí** (Linphone chat → mobil): napiš chat na `<číslo>@<brána>`.
- **Potvrzení odeslání do sítě**: po odeslání přijde do chatu „✓ SMS odeslána
  do sítě (ref …)" — message reference od operátora = důkaz, že SMS opustila
  RPi, ne že uvázla mezi telefonem a bránou.
- **Alfanumeričtí odesílatelé** (banky, „AIRBANK"): příchozí projde, odpovědět
  nelze — pokus o odpověď dostane srozumitelnou chybovou zprávu, ne tiché
  zahození.

**Spolehlivost (krok 2):** každá příchozí SMS se zapisuje do žurnálu
`runtime/smsdata/journal.jsonl` (text SMS v base64). Když doručení do
softphonu selže (telefon offline, po restartu brány…), zpráva se zařadí do
fronty a opakuje s backoffem 60 s → strop 10 min. Pokus o doručení se dělá
**jen když je softphone registrovaný** (kontrola `PJSIP_AOR` v každém tiku
— bez SIP provozu), takže po připojení telefonu SMS dorazí do ~10 minut.
Give-up podle stáří zprávy: **TTL 48 h** od přijetí (v žurnálu pak
`failed-ttl`). Retry je vždy nový SIP MESSAGE (nový Call-ID) — replay by
liblinphone tiše zahodil jako duplikát. Naplánované pokusy leží v
`runtime/spool/` (call files) a přežijí restart kontejneru.

Známé omezení / TODO:
- IMDN doručenky (potvrzení, že telefon zprávu zobrazil) nejdou: Asterisk 20
  `res_pjsip_messaging` odmítá `message/cpim` mimo dialog (415). Náhrada:
  žurnál + retry výše.
- `autodeletesms=no` (SMS se podle pozorování na SIM stejně neukládají —
  driver je bere přímou cestou; kdyby se SIM plnila:
  `quectel sms delete all quectel0`).
