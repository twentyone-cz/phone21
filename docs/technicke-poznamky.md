# Technické poznámky

Věci, které stály nejvíc času a nejsou nikde pohromadě popsané. Platí pro
výrobce modem (Qualcomm MDM9x07) + Asterisk 20 + chan_quectel.

## Audio jde přes sériový PCM port, ne přes zvukovku

Modem vystavuje hlas na druhém sériovém portu (`ttyUSB4`) jako 8 kHz/16 bit
PCM — v Asterisku kodek `slin`. Žádné USB audio, žádná ALSA, žádný
`/dev/snd`. Kontejner proto nepotřebuje `privileged`; stačí dva `devices:`
(AT port + audio port) a `group_add: ["20"]` kvůli skupině `dialout`.

Důsledek pro kvalitu: cesta je pevně 8 kHz, takže i když hovor v mobilní
síti běží jako HD (VoLTE/AMR-WB), do SIP vrstvy se propíše jen úzkopásmově.

## `-Wl,-Bsymbolic` při buildu chan_quectel je povinné

Modul má interní funkce jako globální symboly (`channel_new`, `cpvt_alloc`…)
a volá je přes PLT. V procesu Asterisku bývá i `cizí knihovna`, která exportuje
vlastní globální `channel_new`. Bez `-Bsymbolic` dynamický linker naváže
volání na cizí knihovna, ta vrátí NULL a **všechny odchozí hovory padají** na
„Unable to allocate channel structure" (cause 44) — bez jediného užitečného
logu. Stejná třída kolize je pravděpodobně i za historickými pády při DTMF.

Diagnostika, kdyby se to opakovalo: `objdump -d --disassemble=channel_request`
(volání přes `@plt`) a hledání druhého `T channel_new` napříč knihovnami
z `/proc/<pid>/maps`.

## VoLTE: rozhodují carrier profily (MBN), ne AT příkazy

`AT+VOLTESETTING?` vracející 1 neznamená nic — Qualcomm platforma vybírá
**carrier profil (MBN)** podle SIM při každém startu modemu, a když pro
operátora nemá shodu, spadne na generický profil, se kterým IMS registrace
neproběhne. U výrobceu na to není AT příkaz (na rozdíl od Quectelu
`AT+QMBNCFG`); profily se spravují přes Qualcomm PDC rozhraní, což jde
i z Linuxu:

```bash
qmicli -d /dev/cdc-wdm0 --pdc-list-configs=software      # co firmware nabízí
qmicli -d /dev/cdc-wdm0 --pdc-deactivate-config="software,<ID>"
qmicli -d /dev/cdc-wdm0 --pdc-activate-config="software,<ID>"
qmicli -d /dev/cdc-wdm0 --imsa-get-ims-registration-status   # kontrola
```

Přepnutí funguje za horka, ale autoselect ho po resetu modemu vrací — proto
je v repu `scripts/mbn-profile.sh` (tabulka operátor→profil) a služba, která
volbu po startu obnoví.

Aby VoLTE naskočilo, musí sednout **tři věci najednou**: vhodný MBN profil,
přístup k QMI rozhraní, a **aktivované VoLTE na lince u operátora** — to
poslední se u některých operátorů zapíná až po prvním připojení běžného
telefonu, takže novou SIM je někdy potřeba jednou vložit do mobilu.

Ověření: `qmicli --imsa-get-ims-registration-status` musí hlásit
`registered`, a `AT+CPSI?` během hovoru musí zůstat na LTE (jinak hovor
spadl CSFB do 2G/3G).

## Dialplan: odmítnutí hovoru vypadá jako nedosažitelnost

`app_dial` mapuje SIP 603 Decline i 486 Busy do `DIALSTATUS=CHANUNAVAIL`,
tedy stejně jako skutečnou nedosažitelnost. Když se podle toho rozhoduje
o „zmeškaném hovoru", je nutné testovat i `HANGUPCAUSE` (21 = odmítnuto,
17 = obsazeno) — jinak po odmítnutí volajícímu dál vyzvání a odejde falešná
notifikace.

## Call files: `pbx_spool` odpaluje soubor podle mtime, ale hlídá i vznik

Naplánovaná akce se dělá call filem s budoucím `mtime`. Pozor: `pbx_spool`
sleduje adresář přes inotify včetně `inotify`/`inotify` a dotfiles
nefiltruje — soubor psaný **přímo do spool adresáře** má v okamžiku zavření
mtime „teď" a provede se okamžitě, bez ohledu na pozdější `touch`. Řešení:
psát do podadresáře (watch není rekurzivní) a hotový soubor `mv`nout — pak
přijde `inotify` s už správným mtime. Rozumné je mít i pojistku v
dialplanu (`Wait` do plánovaného času), protože předčasné spuštění
naplánované smyčky umí utopit celý stroj.

## Doručování zpráv do liblinphone

Klient řadí konverzace podle hlavičky `To`; když v ní není identita účtu
(user@doména, jak je registrovaný), zpráva se sice uloží s „200 OK", ale
konverzace se nemusí vůbec zobrazit. Doména v `From` musí být rozložitelná,
jinak klient neumí odpovědět. A pozor na `Call-ID`: retry musí být nový
`MessageSend`, ne replay téhož requestu — duplicitní Call-ID klient zahodí.

## Formát čísel

Klient páruje kontakty na E.164. Když brána jednou pošle `606…` a podruhé
`+420606…`, vzniknou dvě konverzace pro tentýž protějšek. Řešení je
normalizovat **všechno, co jde k telefonu** (CallerID, odesílatel SMS,
potvrzenky) na `+<předvolba><číslo>` a nechat být jen to, co číslo není:
krátká čísla (112, dárcovské SMS) a alfanumerické odesílatele bank.

## Provozní drobnosti

- modem **nedetekuje SIM za běhu** — po výměně je potřeba odpojit a znovu
  připojit napájení modemu, restart softwaru nestačí.
- Po re-enumeraci USB (reset modemu, `AT+CRESET`) drží kontejner mrtvé
  odkazy na `/dev/ttyUSB*`; driver to typicky odnese pádem a je potřeba
  kontejner (u LXC celý hostitel) restartovat.
- `AT+CNMP` (změna preferovaného režimu sítě) vyhodí chan_quectel.
- **Nikdy** neposílat `zakázaný AT příkaz` — mění USB kompozici zařízení.
