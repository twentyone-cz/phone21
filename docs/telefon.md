# Telefon — nastavení klienta

Průvodce stranou telefonu: kontakty, klient, tunel, auto. Brána samotná je
klientně neutrální (SIP/RFC 3428) — tady jde o to, aby telefon plnil roli
„mobilu s českým číslem" pohodlně.

## 1. Přenos kontaktů ze starého telefonu (jednorázově, bez cloudu)

Cíl je vždycky stejný: dostat **jeden `.vcf` (vCard)** a naimportovat ho do
lokálního úložiště telefonu. Liší se jen způsob exportu podle toho, odkud
kontakty berou. Vyber si variantu A1–A3, pak pokračuj sekcí B.

### A1. Android — export přímo z telefonu (doporučeno)

1. Kontakty → **Opravit a spravovat** → **Exportovat do souboru** → `.vcf`.
2. Tahle cesta je lepší než webový export z Googlu kvůli **fotkám**: telefon
   je vloží přímo do souboru (base64), zatímco webový export dá jen URL na
   googleusercontent, které se při offline importu zahodí.

### A2. Android/Google — export z webu

1. Na PC otevři **contacts.google.com**, přihlas se starým účtem.
2. V levém panelu **Fix & manage → Export** (nebo vybrat kontakty → ⋮ →
   Export). Nic nevybírat = exportují se všechny.
3. Formát **vCard (for iOS Contacts)** → Export. Navzdory názvu je to
   standardní **vCard 3.0 v UTF-8**, jeden `contacts.vcf`. (Google CSV neber
   — je pro Outlook, ne pro telefon.)
4. Alternativa **Google Takeout** → jen „Contacts" → vCard. Stejný výsledek,
   jen zdlouhavější.
5. Fotky touhle cestou nepřenese — viz A1.

### A3. iPhone

iOS **nemá v Kontaktech hromadný export do souboru** — přes „Sdílet kontakt"
jde rozumně poslat jen pár kusů. Použij tedy jednu z těchto cest:

1. **Přes iCloud (obvyklá cesta).** Na PC otevři **icloud.com** → **Contacts**
   → v postranním panelu / pod ozubeným kolem **Select All** → znovu nabídka →
   **Export vCard**. Vypadne jeden `.vcf` se všemi kontakty (vCard 3.0, UTF-8).
   Podmínka: kontakty musí být opravdu synchronizované do iCloudu
   (*Nastavení → [jméno] → iCloud → Kontakty* zapnuto).
2. **Když kontakty na iPhonu žijí v Google účtu** (*Nastavení → Kontakty →
   Účty*), nedělej rozbočku přes iCloud a exportuj rovnou podle A2.
3. **Fotky ověř**, nespoléhej na ně: jestli se v exportu octnou, závisí na
   tom, zda se do vCard dostane vlastnost `PHOTO`. Po importu si projdi pár
   kontaktů, u kterých fotku čekáš.

### B. Přenos souboru

1. `.vcf` přenes USB kabelem (MTP) nebo přes **LocalSend** (F-Droid) po Wi-Fi.
   Ne přes cizí cloud — je to celý adresář.

### C. Import do lokálního úložiště

1. **Doporučeno: Fossify Contacts** (F-Droid, `org.fossify.contacts`):
   Settings → **Import contacts** → vybrat `.vcf` → cíl **Phone storage /
   lokální úložiště** (ne účet). Zvládá vCard 3.0/4.0 spolehlivě.
2. AOSP Contacts (předinstalovaná) to umí taky (Fix & manage → Settings →
   Import), ale na GrapheneOS fóru jsou opakovaná hlášení o zaseknutí na 1 %
   / „format isn't supported" u větších moderních vCard. Když se to stane,
   použij Fossify — zapisuje do stejného systémového ContactsProvider,
   výsledek vidí všechny aplikace.
3. Kontakty bez účtu = lokální/Device kontakty — žádný sync, viditelné pro
   každou app s oprávněním Kontakty. Přesně to chceme.

### D. Ověření a přístup pro Linphone

1. V Kontaktech zkontroluj počet, diakritiku (Řehoř, Šťastný…), pár čísel.
2. Přístup pro Linphone na GrapheneOS:
   - **Plné oprávnění Contacts** — vidí celý adresář → caller-ID funguje
     pro všechno. Pro tenhle účel praktická volba.
   - **Contact Scopes** — app si myslí, že oprávnění má, ale vidí jen ručně
     přidané kontakty/skupiny (read-only). Bezpečnostně hezké, pro
     caller-ID celého adresáře nepraktické (volba „vše" neexistuje).
3. Test: zavolej si z čísla, které je v kontaktech — musí se zobrazit jméno.

### Gotchas

- **Diakritika:** export z Googlu i z iCloudu je UTF-8 vCard 3.0 — čeština OK.
- **Fotky:** webový export z Googlu = jen URL → offline importem se ztratí
  (proto A1). U iCloudu to ověř po importu.
- **Štítky/skupiny:** při importu do lokálního úložiště se typicky zahodí;
  kontakty projdou.
- **Duplicity:** import nededuplikuje — před re-importem smazat lokální
  kontakty, nebo Fossify „Merge duplicate contacts".
- **Formát čísel:** drž **+420… (E.164)** — párování volajícího je na E.164
  nejspolehlivější (a sedí na to, co posílá brána). Sjednotit jde hromadně
  v Google Contacts (Merge & fix) ještě před exportem.
- **Profily GrapheneOS:** kontakty jsou per-profil — importuj v profilu, kde
  běží Linphone.

Zdroje: [export Google kontaktů](https://support.google.com/contacts/answer/7199294),
[export vCard z iCloudu](https://support.apple.com/guide/icloud-web-only/mmfba748b2/icloud),
[GrapheneOS Contact Scopes](https://grapheneos.org/features#contact-scopes),
[Fossify Contacts](https://f-droid.org/en/packages/org.fossify.contacts/),
diskuse GrapheneOS fóra k AOSP importu (33874, 32624, 12991, 4365).

## 2. Párování SMS a hovorů na jména

Ověřeno ze zdrojáků linphone-android (master 2026-07) + liblinphone:

- Linphone si při startu načte kontakty přes `ContactsContract` (potřebuje
  **oprávnění Kontakty**; od 6.0 jen čtení) a příchozí hovor/zprávu páruje
  dvoukrokově: přesná shoda SIP URI, pak — když user část začíná `+` nebo
  jsou to jen číslice — normalizované porovnání telefonního čísla (dial
  plan účtu: `+420…`, `00420…` i `123456789` se srovnají na E.164).
- **Brána E.164 garantuje** (od 2026-08): všechno, co Linphone vidí —
  CallerID hovoru, odesílatel SMS, potvrzenky odeslání i notifikace
  zmeškaných hovorů — normalizuje subrutina `[number-normalize]` na
  `+420…` (předvolba `COUNTRY_CODE` v `.env`). Konverzace se tak nerozpadá
  na dvě vlákna (`606…` vs `+420606…`), i když modem vrací jiný tvar, než
  se vytočilo. Krátká čísla (dárcovská 87x, 3030, 112) a alfanumeričtí
  odesílatelé (AIRBANK…) se nechávají být — ti se nepárují z principu
  (nejsou čísla), zobrazí se ID odesílatele. Self-test: vytoč `*984`.
- V Linphone nastav u účtu **International Prefix = Czechia (420)** („Pick
  your country to allow Linphone to match your contacts") — pojistka pro
  národní formáty.
- Jméno spárovaného kontaktu jde i do Telecom vrstvy → **zobrazuje se na
  displeji auta** (viz níže).

## 3. Připojení k bráně

Telefon a brána se najdou přes privátní šifrovanou síť (aplikace
[Tailscale](https://tailscale.com/) s vlastním koordinačním serverem —
postup viz <https://phone.twentyone.cz/instalace>). SIP účet v Linphone pak
míří na adresu brány v téhle síti.

**Účet se nastavuje naskenováním QR kódu**, ne ručně: v ovládání brány
záložka *Telefon* → *Zobrazit QR pro Linphone*. Kód nese jednorázový odkaz
na konfiguraci (platí 10 minut, jedno použití) a přečte ho jak skener
uvnitř Linphonu, tak běžný fotoaparát telefonu. Účet se v telefonu jmenuje
**myGSM** a rovnou má správnou adresu brány, přihlašovací údaje, UDP
transport i vypnuté video. Ruční cesta zůstává jako záloha — pak platí
checklist níž.

### SIP transport a spolehlivost doručení

Doporučený transport je **UDP**. TCP se v praxi ukázalo křehčí: úsporné
režimy Androidu zabíjejí nečinný socket, klient se to nedozví a registrace
padá — brána pak příchozí hovor odmítne jako nedosažitelný. UDP spojení
neudržuje, takže tenhle problém nemá; velké requesty (dlouhé SMS) si PJSIP
přepne na TCP sám. Na bráně k tomu patří tolerantnější `qualify_timeout`
(RTT přes mobilní data mívá vteřinové špičky).

**Checklist na telefonu** (body 1–2 nastaví QR sám, ověřit se ale vyplatí):

1. Linphone → účet → **Transport: UDP**, expirace registrace 600 s
2. Kodeky: vypnout video, nechat jen **PCMA/PCMU** (malé INVITE se nemusí
   fragmentovat)
3. VPN aplikace: **Always-on VPN**
4. Android → Aplikace → Linphone i VPN klient → **Baterie: Neomezeno**
   (nepoužíváme Google push — aplikace musí smět běžet na pozadí)

**Zmeškané hovory:** když je telefon nedostupný, brána pošle do chatu zprávu
„Zmeškaný hovor v HH:MM" od čísla volajícího; doručí se po znovupřipojení.
Chování k volajícímu (vyzvánět naprázdno / hláska) se přepíná ve web UI.

## 4. Handsfree v autě (Bluetooth HFP / Android Auto)

Ověřeno ze zdrojáků linphone-android, AOSP Telecom/Bluetooth a GrapheneOS
dokumentace. Poctivá tabulka:

| Přání | Jde? | Jak / proč ne |
|---|---|---|
| Hovory přes handsfree (klasické **Bluetooth HFP**) | **ANO** | Linphone 6.x má vždy zapnutou Telecom integraci (Jetpack core-telecom, self-managed calls) a AOSP Bluetooth stack self-managed hovory do HFP propouští: **vyzvánění v autě, příjem/zavěšení z volantu, zvuk přes reproduktory auta, jméno kontaktu na displeji** — bez toho, aby byl Linphone „výchozí telefon". |
| Linphone jako **telefonní účet systému** | **NE (volba Linphonu, ne limit Androidu)** | Linphone jede v režimu *self-managed* a záměrně neimplementuje ROLE_DIALER/InCallService („it isn't a phone app", issue #1005). Pro HFP to není potřeba (viz výše). Důsledky: hovory nejsou v systémovém call logu → „poslední hovory" v autě (PBAP) zůstanou prázdné a z UI auta se nevytáčí; historie je v Linphone. Klient, který se registruje jako **call provider** (PhoneAccount s CAPABILITY_CALL_PROVIDER), by obojí odemkl — systémový vytáčeč by nabídl „volat přes…" a hovory by padaly do call logu. Jestli to některý z komerčních klientů (Zoiper, Acrobits) na Androidu opravdu dělá, **neověřeno** — jejich marketing to tvrdí, důkaz chybí; test je hodinová záležitost ve vedlejším profilu. Pozor: tyhle klienty stojí běh na pozadí na vlastním push serveru, který se k naší bráně v privátní síti nedostane — musely by jet bez pushe. |
| **Android Auto** (obrazovka auta) | **NE** | Dva nezávislé blokery: (1) AA klient tvrdě závisí na Google Play — na GrapheneOS jde jen se sandboxed Play, bez něj vůbec; (2) VoIP volání v AA je u Googlu closed beta — Linphone kód má, ale zakomentovaný („Google hasn't granted us access yet", issue #2216). |
| **SMS v autě** (čtení/odpověď) | **NE** (BT), podmíněně (AA) | Bluetooth MAP servíruje jen skutečnou SMS databázi telefonu — SIP MESSAGE chaty do ní nelze podporovaně dostat. AA messaging by fungoval (Linphone má MessagingStyle+reply hotové od 5.0.3), ale AA bez Play neběží — viz výše. |

**Prakticky pro tebe:** spáruj telefon s autem klasicky přes Bluetooth —
hovory přes bránu budou v autě fungovat jako normální telefonování (zvonění,
volant, jméno na displeji). SMS v autě v rámci „bez Google" nejde; zprávy
zůstávají na telefonu v Linphone. Kdyby ses někdy rozhodl pro sandboxed
Play, otevře se AA předčítání/odpovídání zpráv — hovory v AA ale ne (Google
beta).

Pozn. k verzi: ověřeno na F-Droid buildu Linphone 6.0.21 (Telecom fix pro
Android <13 z 6.0.23 se GrapheneOS netýká — běží na novějším Androidu).
