# Phone21 — tvoje číslo, tvůj miniserver

Promění USB LTE modem se SIM kartou v soukromou telefonní ústřednu: hovory
a SMS z tvého čísla dostaneš do aplikace v mobilu, ať jsi kdekoli — přes
privátní šifrovanou síť, bez veřejné IP a bez port forwardu.

Produktové stránky: [phone.twentyone.cz](https://phone.twentyone.cz).

## Co to umí

- **Hovory oběma směry** z tvého čísla, po datové síti operátora (modem si
  sám vybere správný profil — `scripts/mbn-profile.sh`)
- **Zprávy jako konverzace** v aplikaci, s potvrzením odeslání a spolehlivým
  doručením (žurnál + fronta opakování, TTL 48 h)
- **Zmeškané hovory** při nedostupném telefonu dorazí jako zpráva od volajícího;
  chování k volajícímu (vyzvánět / hláska) se přepíná v ovládání
- **Jednotný formát čísel** — vše, co telefon uvidí, je E.164 (`+420…`), takže
  se konverzace a kontakty nerozpadají
- **Ostrovní režim** — při výpadku domácího internetu se miniserver přepne na
  mobilní data z vlastní SIM a zůstane dosažitelný
- **Ovládání** ve dvou režimech: spotřebitelský přehled i technický pohled
- **Hlídka modemu**, která zaseknutý ovladač sama zotaví

## Hardware

Miniserver (Raspberry Pi 4/5 nebo cokoli s Dockerem, x86 i ARM), podporovaný
USB LTE modem a SIM karta. Ne každý modem se pro hlas hodí — výběr, napájení
a nastavení modemu jsou u téhle třídy hardwaru nejotravnější část. Odladěné
sestavy jsou k mání hotové: <https://phone.twentyone.cz/obchod/>.

## Instalace

**umbrelOS** — v App Store přidej community store
`https://github.com/twentyone-cz/umbrel-store` a nainstaluj aplikaci Phone21.

**Docker (jakýkoli Linux):**

```bash
git clone https://github.com/twentyone-cz/phone21 && cd phone21
mkdir -p data/{smsdata,spool,astlog,ts-state}
WEBUI_PASSWORD=silne-heslo docker compose -f docker-compose.standalone.yml up -d
```

Ovládání pak běží na `http://<adresa-serveru>:8090`. Kompletní návod včetně
připojení telefonu: <https://phone.twentyone.cz/instalace>.

## Jak je to postavené

Telefonní ústředna s ovladačem pro LTE modem (vlastní build, viz `docker/`),
ovládání v čisté Python stdlib, konfigurace generovaná ze šablon. Kontejner
neběží privilegovaně — dostane jen sériové porty modemu.

```
asterisk/     šablony konfigurace (tokeny se dosazují z .env / entrypointem)
webui/        ovládání — čistá Python stdlib
scripts/      hlídka modemu, profily modemu, fronta zpráv, firewall, ostrovní režim
docker/       build image ústředny s ovladačem modemu a lokálními patchi
umbrel/       aplikace pro Umbrel a multi-arch build obrazů
web/phone/    produktové stránky
```

Konfigurace se generuje ze šablon: v Dockeru/Umbrelu si ji kontejner vyrobí
sám při startu (`PHONE21_SELFCONFIG=1`), jinak jednorázově `./configure.sh`.

## Dokumentace

- [`docs/telefon.md`](docs/telefon.md) — nastavení telefonu: kontakty,
  spolehlivé doručování, chování v autě
- [`docs/faq.md`](docs/faq.md) — časté otázky a řešené problémy

## Soukromí

Hovory a zprávy jdou z miniserveru do běžné mobilní sítě přes tvého operátora —
ten je vidí stejně jako u obyčejného telefonu. Tenhle projekt chrání cestu mezi
telefonem a miniserverem, ne mobilní síť za ní. Telemetrie je vypnutá, ovládání
ani miniserver nikam nic neposílají.

## Licence

MIT
