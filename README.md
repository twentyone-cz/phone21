# gsm2sip — vlastní GSM/VoLTE brána pro tvoje číslo

Promění USB LTE modem se SIM kartou v soukromou telefonní ústřednu: hovory
a SMS z tvého čísla dostaneš do softphonu na mobilu, ať jsi kdekoli —
přes privátní šifrovanou síť, bez veřejné IP a bez port forwardu.

Součást produktu [jednadvacet phone](https://phone.twentyone.cz).

## Co to umí

- **Hovory oběma směry** z tvého čísla, **VoLTE** (automatická volba carrier
  profilu modemu přes QMI — `scripts/mbn-profile.sh`)
- **SMS jako konverzace** v softphonu, s potvrzením odeslání a spolehlivým
  doručením (žurnál + retry fronta, TTL 48 h)
- **Zmeškané hovory** při nedostupném telefonu dorazí jako zpráva od volajícího;
  chování k volajícímu (vyzvánět / hláska) se přepíná ve web UI
- **Jednotný formát čísel** — vše, co telefon uvidí, je E.164 (`+420…`), takže
  se konverzace a kontakty nerozpadají
- **Ostrovní režim** — při výpadku domácího internetu se brána přepne na
  mobilní data z vlastní SIM a zůstane dosažitelná
- **Web UI** ve dvou režimech: spotřebitelský dashboard i technický pohled
- **Watchdog modemu**, který zaseknutý driver sám zotaví

## Hardware

Mini-server (Raspberry Pi 4/5 nebo cokoli s Dockerem, x86 i ARM), podporovaný
USB LTE modem a SIM karta s aktivovaným VoLTE. Ne každý modem se pro hlas hodí
— výběr, napájení a nastavení modemu jsou u téhle třídy hardwaru nejotravnější
část. Odladěné sestavy prodáváme hotové: <https://phone.twentyone.cz/obchod/>.

## Instalace

**umbrelOS** — v App Store přidej community store
`https://github.com/twentyone-cz/umbrel-store` a nainstaluj appku GSM2SIP.

**Docker (jakýkoli Linux):**

```bash
git clone https://github.com/twentyone-cz/gsm2sip && cd gsm2sip
mkdir -p data/{smsdata,spool,astlog,ts-state}
WEBUI_PASSWORD=silne-heslo docker compose -f docker-compose.standalone.yml up -d
```

Web UI pak běží na `http://<adresa-serveru>:8090`. Kompletní návod včetně
připojení telefonu: <https://phone.twentyone.cz/instalace>.

## Jak je to postavené

Asterisk 20 s ovladačem pro LTE modem (vlastní build, viz `docker/`), web UI
v čisté Python stdlib nad AMI, konfigurace generovaná ze šablon. Kontejner
neběží privilegovaně — dostane jen sériové porty modemu.

```
asterisk/     šablony konfigurace (tokeny se dosazují z .env / entrypointem)
webui/        web UI — čistá Python stdlib, komunikuje přes AMI
scripts/      watchdog modemu, MBN/VoLTE profily, SMS fronta, firewall, ostrovní režim
docker/       build image (Asterisk + chan_quectel + lokální patche)
umbrel/       Umbrel appka a multi-arch build obrazů
web/phone/    produktové stránky
```

Konfigurace se generuje ze šablon: v Dockeru/Umbrelu si ji kontejner vyrobí
sám při startu (`GSM2SIP_SELFCONFIG=1`), jinak jednorázově `./configure.sh`.

## Dokumentace

- [`docs/telefon.md`](docs/telefon.md) — nastavení telefonu: kontakty, klient,
  transport, spolehlivé doručování
- [`docs/faq.md`](docs/faq.md) — časté otázky a řešené problémy

## Soukromí

Hovory a SMS jdou z brány do běžné mobilní sítě přes tvého operátora — ten je
vidí stejně jako u obyčejného telefonu. Tenhle projekt chrání cestu mezi
telefonem a bránou, ne mobilní síť za ní. Telemetrie přibalených klientů je
vypnutá (`TS_NO_LOGS_NO_SUPPORT`), web UI ani brána nikam nic neposílají.

## Licence

MIT
