# Telefon — nastavení aplikace Phone21

Průvodce stranou telefonu: kontakty, aplikace Phone21, privátní síť, auto —
aby telefon fungoval jako „mobil s českým číslem" pohodlně.

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
   Import), ale jsou opakovaná hlášení o zaseknutí na 1 % / „format isn't
   supported" u větších moderních vCard. Když se to stane,
   použij Fossify — zapisuje do stejného systémového ContactsProvider,
   výsledek vidí všechny aplikace.
3. Kontakty bez účtu = lokální/Device kontakty — žádný sync, viditelné pro
   každou app s oprávněním Kontakty. Přesně to chceme.

### D. Ověření a přístup pro aplikaci Phone21

1. V Kontaktech zkontroluj počet, diakritiku (Řehoř, Šťastný…), pár čísel.
2. Přístup pro aplikaci Phone21 ke kontaktům:
   - **Plné oprávnění Kontakty** — vidí celý adresář → jméno se zobrazí
     u každého hovoru i zprávy. Pro tenhle účel praktická volba.
   - **Omezený přístup ke kontaktům** — některé varianty Androidu umí
     místo plného oprávnění vybrat jen konkrétní kontakty; aplikace pak
     vidí jen je, a to jen ke čtení. Bezpečnostně hezké, pro párování
     jmen z celého adresáře nepraktické (volba „vše" neexistuje).
3. Test: zavolej si z čísla, které je v kontaktech — musí se zobrazit jméno.

### E. Nové kontakty založené v aplikaci Phone21

Od verze **21p.30** aplikace nezakládá kontakty „jen u sebe": nový nebo
upravený kontakt jde rovnou do **adresáře telefonu**, tedy tam, kam ho
uloží i systémové Kontakty. Důsledky:

- kontakt vidí i ostatní aplikace a **auto přes Bluetooth** (jméno na
  displeji, seznam kontaktů v autě),
- kontakty založené ve starších verzích aplikace se při první aktualizaci
  jednorázově přenesly do adresáře telefonu (dělá se samo, nic nenastavuj),
- smazání kontaktu v aplikaci ho smaže i z adresáře telefonu.

Čísla drž v mezinárodním tvaru **+420…** — párování volajícího na jméno je
na něm nejspolehlivější.

### Gotchas

- **Diakritika:** export z Googlu i z iCloudu je UTF-8 vCard 3.0 — čeština OK.
- **Fotky:** webový export z Googlu = jen URL → offline importem se ztratí
  (proto A1). U iCloudu to ověř po importu.
- **Štítky/skupiny:** při importu do lokálního úložiště se typicky zahodí;
  kontakty projdou.
- **Duplicity:** import nededuplikuje — před re-importem smazat lokální
  kontakty, nebo Fossify „Merge duplicate contacts".
- **Formát čísel:** drž **+420… (E.164)** — párování volajícího je na E.164
  nejspolehlivější (a sedí na to, co posílá miniserver). Sjednotit jde
  hromadně v Google Contacts (Merge & fix) ještě před exportem.
- **Uživatelské profily telefonu:** kontakty jsou per-profil — importuj
  v tom profilu, kde běží aplikace Phone21.

Zdroje: [export Google kontaktů](https://support.google.com/contacts/answer/7199294),
[export vCard z iCloudu](https://support.apple.com/guide/icloud-web-only/mmfba748b2/icloud),
[Fossify Contacts](https://f-droid.org/en/packages/org.fossify.contacts/).

## 2. Párování SMS a hovorů na jména

Aplikace Phone21 páruje příchozí hovory a zprávy s kontaktem automaticky —
funguje to i když volající nebo odesílatel posílá číslo v jiném tvaru
(`606…` místo `+420606…`), miniserver čísla sjednocuje na mezinárodní tvar
sám, takže se konverzace nerozpadá na dvě vlákna. Krátká čísla (dárcovská
87x, 3030, 112) a alfanumeričtí odesílatelé (AIRBANK…) se z principu
nepárují — nejsou to čísla — zobrazí se ID odesílatele. Self-test: vytoč
`*984`.

Jméno spárovaného kontaktu jde i do telefonování v systému telefonu →
zobrazuje se i na displeji auta (viz níže).

## 3. Připojení k miniserveru

Telefon a miniserver se spolu spojí přes privátní síť — uzavřené spojení
jen mezi tvým telefonem a miniserverem, nikam jinam telefon přes ni nevidí.

**Účet se nastavuje naskenováním QR kódu**, ne ručně: v ovládání
miniserveru záložka *Telefon* → *Zobrazit QR*. Kód nese jednorázový odkaz
na konfiguraci (platí 10 minut, jedno použití) a přečte ho jak skener
přímo v aplikaci Phone21, tak běžný fotoaparát telefonu. Když skener
nespolupracuje, jde odkaz opsat ručně — je pod QR kódem.

Do privátní sítě se telefon zatím připojuje zvlášť: v aplikaci
*Nastavení → Privátní síť → Připojit* a potvrzení peněženkou v prohlížeči.
(Spojení obojího do jediného QR kódu se připravuje.)

### Spolehlivé doručení hovorů

Aplikace Phone21 si typ připojení i všechny ostatní parametry nastaví sama
z QR kódu tak, aby hovory a zprávy chodily spolehlivě i když telefon šetří
baterii. Zbývá pár kroků, které za tebe udělat nemůže:

1. Android → Aplikace → Phone21 → **Baterie: Neomezeno** (aplikace musí
   smět běžet na pozadí i ve spánku telefonu). Od verze 21p.31 si o to
   aplikace řekne sama systémovým dialogem hned po nastavení účtu; stav
   ukazuje obrazovka *Konexe* řádkem „Běh na pozadí".
2. Povolit **oznámení** pro aplikaci Phone21 — jinak nepřijde upozornění
   na hovor ani zprávu.

Systémovou volbu **Always-on VPN** nehledej — aplikace ji od verze 21p.26
záměrně nenabízí (spolu s ní by šlo omylem zapnout „Blokovat připojení bez
VPN", které telefon odřízne od internetu). Připojení k privátní síti se po
restartu telefonu obnoví samo.

**Zmeškané hovory:** když je telefon nedostupný, miniserver pošle do
aplikace zprávu „Zmeškaný hovor v HH:MM" od čísla volajícího; doručí se po
znovupřipojení. Chování k volajícímu (vyzvánět naprázdno / hláska) se
přepíná v ovládání miniserveru.

## 4. Handsfree v autě (Bluetooth HFP / Android Auto)

Poctivá tabulka (stav od 21p.28):

| Přání | Jde? | Jak / proč ne |
|---|---|---|
| Hovory přes handsfree (klasické Bluetooth) | **ANO** | Aplikace Phone21 se vždy napojuje na telefonování v systému telefonu, takže hovory jdou do handsfree normálně: vyzvánění v autě, příjem/zavěšení z volantu, zvuk přes reproduktory auta, jméno kontaktu na displeji (od 21p.28 se autu hlásí telefonní číslo, ne interní adresa — párování se jmény je spolehlivější). |
| **Historie hovorů na displeji auta** | **ANO (21p.28, přepínač)** | Privátní síť → „Historie hovorů do auta" + povolit oprávnění. Ukončené hovory se zapisují i do historie telefonu, odkud si je auto čte (PBAP). Jména ukazuje auto z kontaktů telefonu — u auta musí být povolené „Sdílení kontaktů". |
| **Čtení SMS v autě** | **ANO (21p.28, volba)** | Nastavení → „SMS do auta" → potvrdit Phone21 jako výchozí aplikaci pro SMS. Zprávy z miniserveru se pak zrcadlí do úložiště SMS telefonu, odkud je auto čte (u auta zapnout „Sdílení zpráv"). **Odpověď z auta nejde** — auto by ji poslalo mimo miniserver, tudy cesta nevede. |
| **Vytáčení z displeje auta / hlasem** | **ANO (21p.28, volba, experiment)** | Privátní síť → „Vytáčení z auta" + v systémovém Telefonu → Účty pro volání povolit „Phone21 (miniserver)" (a případně zvolit jako výchozí pro odchozí hovory). Auto pak vytáčí přes miniserver. Pozor: jako výchozí účet poteče přes miniserver každé vytočení v telefonu. |
| Phone21 jako **výchozí telefonní appka** (systémový vytáčeč) | **NE (a nevadí to)** | Není potřeba pro nic z výše uvedeného. |
| **Android Auto** (obrazovka auta) | **NE** | Dva nezávislé důvody: (1) Android Auto potřebuje služby Google Play (na telefonu bez nich neběží) a (2) hlasové volání v Android Auto Google zatím pouští jen do vlastního beta programu, veřejně to zapnout nejde. |

**Prakticky pro tebe:** spáruj telefon s autem přes Bluetooth a v detailu
spárovaného auta zapni „Sdílení kontaktů" i „Sdílení zpráv". V Phone21 pak
zapni přepínače — od 21p.29 jsou všechny pohromadě na obrazovce **Konexe**
(dřív „Privátní síť"), sekce Auto (Bluetooth).

**Ověřeno první jízdou (21p.28):** vytáčení z displeje, příjem z volantu
i přenos historie hovorů fungují. Poznatky: (1) **jména v autě** ukazuje
auto z adresáře telefonu — od verze **21p.30** tam kontakty z aplikace
Phone21 rovnou patří (viz 1E), takže je auto vidí; čísla drž ve tvaru
+420…; (2) **hlasové ovládání z volantu** předává auto hlasovému
asistentovi telefonu — na telefonu bez asistenta nemá kdo povel obsloužit,
s aplikací to nesouvisí; (3) prázdnou mezinárodní předvolbu účtu si
aplikace od 21p.29 doplní sama podle SIM/jazyka telefonu.
