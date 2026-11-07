# Telefon — nastavení aplikace Phone21

Průvodce stranou telefonu: kontakty a kalendář, aplikace Phone21, privátní síť, auto —
aby telefon fungoval jako „mobil s českým číslem" pohodlně.

## 1. Kontakty a kalendář

### Jak to funguje

Od verze 0.9.27 drží kontakty i kalendář **miniserver**. Telefon, jeho další
profily i další zařízení se s ním synchronizují. Změna na jednom zařízení se
přes miniserver propíše na ostatní a kontakty přežijí i ztrátu telefonu.
Žádný cizí cloud při tom nepotřebuješ.

Zařízení se přidávají v ovládání miniserveru na záložce **Kontakty
a kalendář** → **Přidat zařízení**:

- **Všechna zařízení vidí tentýž adresář kontaktů a tentýž kalendář.**
  Telefon, jeho další profily, tablet i počítač mají pořád stejný obsah.
- **Každé zařízení i profil dostane vlastní přihlášení** (jméno a heslo).
  Ztracené nebo prodané zařízení v ovládání smažeš a ostatní běží dál beze
  změny. Kontakty a kalendář při tom zůstanou.
- Heslo se ukáže jen jednou, zapiš si ho. Zapomenuté heslo nahradíš volbou
  **Nové heslo** u daného zařízení.
- Do kalendáře miniserver sám vkládá a aktualizuje událost **„Phone21:
  dojdou kredity sítě“** s upozorněním 3 dny a 1 den předem. Připomínka
  hlídá okamžik, kdy by se privátní síť zastavila. Když dobiješ, událost se
  sama posune. Funguje, když je miniserver připojený do sítě tokenem brány.

Synchronizaci v telefonu obstarává aplikace **DAVx⁵** (F-Droid). Kontakty,
které stáhne, ukládá do adresáře telefonu, takže je vidí aplikace Phone21
(jména volajících), auto přes Bluetooth i ostatní aplikace.

### 1A. Přechod ze starého telefonu s účtem Google

Kontakty i kalendář se přenesou jednorázově: export z Googlu, import do
miniserveru a nový telefon si je pak stáhne. Google a miniserver spolu nejsou
nijak propojené, proto **po exportu už nic neupravuj v Googlu**. Pozdější
změny se nepřenesou. Opakovaný import přeskakuje položky, které už na
miniserveru jsou, i když se mezitím změnily.

**Krok 1: kontakty do souboru `.vcf`**

Nejdřív v Google Kontaktech (contacts.google.com → **Sloučit a opravit**)
sluč duplicity a sjednoť čísla na tvar **+420…**. Pak vyber jednu z cest:

- **Export z telefonu (doporučeno):** Kontakty → **Opravit a spravovat** →
  **Exportovat do souboru** → `.vcf`. Je to lepší než webový export kvůli
  **fotkám**: telefon je vloží přímo do souboru, kdežto webový export dá jen
  odkaz na servery Googlu a ten se po importu ztratí.
- **Export z webu:** na počítači contacts.google.com → **Opravit a spravovat
  → Exportovat**, nic nevybírej (exportují se všechny), formát **vCard (pro
  kontakty v iOS)**. Navzdory názvu je to standardní vCard 3.0 v UTF-8, jeden
  soubor `contacts.vcf`. Formát Google CSV neber, je pro Outlook. Fotky touhle
  cestou nepřejdou.

**Krok 2: kalendář do souborů `.ics`**

1. Na počítači otevři **calendar.google.com** a přihlas se starým účtem.
2. ⚙ **Nastavení** → **Import a export** → **Exportovat**. Stáhne se ZIP
   a po rozbalení je v něm **jeden soubor `.ics` za každý tvůj kalendář**.
3. Bez počítače jde totéž přes **Google Takeout** (takeout.google.com) →
   vyber jen *Kalendář*.
4. Export obsahuje jen kalendáře, které jsou tvoje. Odebírané kalendáře
   (státní svátky, kalendáře sdílené od jiných) si na novém telefonu přidej
   znovu, svátky třeba jako předplatné v aplikaci **ICSx⁵** (F-Droid).
   Narozeniny se neexportují. Kalendářová aplikace je umí ukázat sama
   z kontaktů (Fossify Calendar má volbu v nastavení).

**Krok 3: import do miniserveru**

1. Soubory přenes do počítače, ze kterého otevíráš ovládání: USB kabelem
   nebo přes **LocalSend** (F-Droid) po Wi-Fi. Cizí cloud nepoužívej, je to
   celý tvůj adresář.
2. Ovládání → **Kontakty a kalendář** → v části **Import ze starého
   telefonu** nahraj `.vcf`. Počkej, až import ukáže *hotovo*, a pak nahraj
   postupně každý `.ics`. Všechno se uloží do společného adresáře
   a kalendáře.
3. Zkontroluj souhrn *uloženo / přeskočeno / chyb*. Všechny kalendáře
   z Googlu skončí v **jednom kalendáři** a barvy kalendářů se nepřenesou.
   Připomínky událostí se přenesou s nimi.

**Krok 4: nový telefon** nastav podle 1B.

**Krok 5: kontrola a rozloučení s Googlem**

1. Porovnej počet kontaktů, diakritiku (Řehoř, Šťastný…) a pár čísel.
   V kalendáři zkontroluj opakované události a připomínky.
2. Na nový telefon účet Google nepřidávej. Pokud už tam je, vypni u něj
   synchronizaci Kontaktů a Kalendáře, jinak budeš mít všechno dvakrát.
3. Soubory `.vcf` a `.ics` si nech jako zálohu mimo miniserver.
4. Data u Googlu maž, až když je všechno ověřené. Smazání se propíše i do
   starého telefonu.

**Starý telefon je iPhone.** iOS v Kontaktech hromadný export neumí. Na
počítači otevři **icloud.com** → **Kontakty** → **Vybrat vše** → **Exportovat
vCard**. Kontakty musí být synchronizované do iCloudu (*Nastavení → [jméno]
→ iCloud → Kontakty*). Pokud na iPhonu žijí v účtu Google (*Nastavení →
Kontakty → Účty*), exportuj je rovnou z Googlu podle kroku 1. Fotky po
importu ověř, jestli se do exportu dostanou, se liší.

### 1B. Nastavení telefonu

**Android**

1. V ovládání přidej zařízení (třeba `telefon`) a zapiš si heslo.
2. Nainstaluj **DAVx⁵** (F-Droid) → přidej účet volbou *Přihlásit se pomocí
   URL a uživatelského jména*. Jako adresu vlož tu, kterou ovládání vypisuje
   na záložce Kontakty a kalendář:
   - v profilu, kde běží aplikace Phone21, adresu pro **privátní síť**, která
     funguje doma i venku;
   - jinde (vedlejší profil, tablet bez aplikace Phone21) adresu pro
     **domácí síť**, viz 1C.

   Doplň jméno zařízení a jeho heslo, potvrď nešifrované spojení a zapni
   adresář **Kontakty** i **Kalendář**.
3. Aby se DAVx⁵ dostal k miniserveru i mimo domov, nastav v aplikaci Phone21
   na obrazovce **Konexe** jednu z těchto voleb:
   - **Přístup na miniserver**: do privátní sítě smí všechny aplikace;
   - **Synchronizovat kontakty i přes privátní síť**: zbytek telefonu zůstane
     mimo privátní síť. Volba platí pro kontakty i kalendář, obojí
     synchronizuje DAVx⁵.
4. Nastav, kam se mají ukládat nové záznamy. Kontakt založený do *Telefon /
   Zařízení* nebo událost v lokálním kalendáři zůstanou jen v tom zařízení.
   - **Kontakty:** v aplikaci Kontakty → Nastavení → *Výchozí účet pro nové
     kontakty* → účet z DAVx⁵.
   - **Phone21:** Konexe → Kontakty → *Nové kontakty ukládat do* → adresář
     z miniserveru. Volba *Automaticky* ho vybere sama, když je jediný.
   - **Kalendář:** na telefonech bez služeb Googlu kalendářová aplikace
     obvykle chybí. Nainstaluj **Fossify Calendar** nebo **Etar** (F-Droid).
     Ve Fossify Calendar zapni v nastavení synchronizaci CalDAV a vyber
     kalendář z miniserveru. Etar ho ukáže sám. Nové události zakládej do
     kalendáře z miniserveru.

**iPhone:** Nastavení → Aplikace → Kontakty → Účty → Přidat účet → Jiné →
Přidat účet CardDAV. Server je adresa pro domácí síť z ovládání bez
`http://`, v *Upřesnit* vypni SSL a nastav port 5232. Kalendář se nastaví
stejně, jen přes CalDAV. Přesné názvy položek se mezi verzemi iOS liší.
iPhone se synchronizuje jen v domácí síti.

**Počítač (Thunderbird):** nový adresář typu *CardDAV* a nový kalendář
*v síti*. Adresa je z ovládání, jméno a heslo zařízení. Kdyby Thunderbird
adresář nebo kalendář sám nenašel, zadej přímo
`http://<adresa>:5232/spolecne/kontakty/` a
`http://<adresa>:5232/spolecne/kalendar/`.
Thunderbird umí naimportovat soubor `.ics` rovnou do kalendáře z miniserveru,
hodí se to jako alternativa ke kroku 3.

### 1C. Víc profilů a víc zařízení

Pravidlo je jedno: **každý profil a každé zařízení dostane v ovládání
vlastní přihlášení a vlastní DAVx⁵.** Obsah je všude stejný.

**Profily telefonu (víc uživatelů v jednom telefonu)**

- Každý profil má vlastní kontakty, kalendář i aplikace a o ostatních
  profilech neví. DAVx⁵ nainstaluj a nastav zvlášť v každém profilu, kde
  kontakty chceš.
- **Hovory a zprávy chodí jen do profilu s aplikací Phone21.** Jména
  volajících bere z kontaktů téhož profilu, proto tam adresář z miniserveru
  být musí.
- **Privátní síť běží jen v profilu s aplikací Phone21**, protože připojení
  tohoto druhu patří vždy jen jednomu profilu. V ostatních profilech použij
  adresu pro **domácí síť**. Synchronizace pak proběhne, když je telefon doma
  na Wi-Fi, a změny z cesty se dorovnají po návratu. V DAVx⁵ v nastavení účtu
  zapni *Synchronizovat jen přes Wi-Fi*, ať to venku zbytečně nezkouší.
- Pokud potřebuješ synchronizovat i venku v dalším profilu, musí být do
  privátní sítě připojený i ten. Počítá se pak jako další zařízení a čerpá
  kredit navíc (1 denně).

**Další zařízení (tablet, druhý telefon, počítač, iPhone)**

- Vlastní přihlášení z ovládání a nastavení podle 1B.
- Doma stačí adresa pro domácí síť. Mimo domov se k miniserveru dostane jen
  zařízení připojené do privátní sítě, a každé takové čerpá kredit.

### 1D. Jak s kontakty a kalendářem zacházet

- **Jedno místo pravdy** je adresář a kalendář z miniserveru. Nové záznamy
  zakládej tam (1B, bod 3), ne do *Telefon / Zařízení*.
- **Smazání se propíše všude.** Kontakt smazaný v jednom zařízení zmizí ze
  všech.
- Čísla drž v mezinárodním tvaru **+420…**, párování volajícího na jméno je
  na něm nejspolehlivější.
- Změny se přenesou při další synchronizaci DAVx⁵. Interval nastavíš v účtu,
  ručně jde spustit volbou *Synchronizovat nyní*.
- **Zálohuj mimo miniserver:** jednou za čas exportuj kontakty (Kontakty →
  Exportovat do souboru) i kalendář (Fossify Calendar → export událostí do
  `.ics`) a soubory ulož jinam.
- **Ztracené nebo prodané zařízení:** v ovládání ho smaž. Ostatní zařízení
  si ničeho nevšimnou. Na vyřazeném zařízení smaž i účet v DAVx⁵.
- **Přechod z verze před 0.9.35:** dřív měl každý účet vlastní adresář.
  Aktualizace obsah všech účtů jednou sama přelije do společného adresáře
  a kalendáře, původní data přitom zůstanou. Dosavadní jména a hesla
  platí dál jako přihlášení zařízení. Hned po aktualizaci v DAVx⁵ v účtu
  dej *Obnovit seznam adresářů* a zapni synchronizaci nového adresáře
  a kalendáře. Na iPhonu účet smaž a přidej znovu. Změny udělané v telefonu
  mezi aktualizací a tímhle krokem zůstanou ve starém adresáři a nepřenesou
  se, proto mezitím kontakty neupravuj.

### 1E. Varianta bez synchronizace (jen do telefonu)

Když synchronizaci nechceš, jde `.vcf` naimportovat přímo do telefonu:
**Fossify Contacts** (F-Droid) → Settings → *Import contacts* → vybrat
soubor → cíl **Phone storage / lokální úložiště** (ne účet). Zvládá
vCard 3.0/4.0 spolehlivě. AOSP Kontakty to umí taky (Fix & manage →
Settings → Import), ale u větších moderních vCard jsou opakovaná hlášení
o zaseknutí na 1 % / „format isn't supported".

Kontakty bez účtu jsou lokální — žádná synchronizace, viditelné pro každou
aplikaci s oprávněním Kontakty.

### 1F. Ověření a přístup pro aplikaci Phone21

1. V Kontaktech zkontroluj počet, diakritiku (Řehoř, Šťastný…), pár čísel.
2. Přístup pro aplikaci Phone21 ke kontaktům:
   - **Plné oprávnění Kontakty** — vidí celý adresář → jméno se zobrazí
     u každého hovoru i zprávy. Pro tenhle účel praktická volba.
   - **Omezený přístup ke kontaktům** — některé varianty Androidu umí
     místo plného oprávnění vybrat jen konkrétní kontakty; aplikace pak
     vidí jen je, a to jen ke čtení. Bezpečnostně hezké, pro párování
     jmen z celého adresáře nepraktické (volba „vše" neexistuje).
3. Test: zavolej si z čísla, které je v kontaktech — musí se zobrazit jméno.

### 1G. Nové kontakty založené v aplikaci Phone21

Od verze **21p.30** aplikace nezakládá kontakty „jen u sebe": nový nebo
upravený kontakt jde rovnou do **adresáře telefonu**, tedy tam, kam ho
uloží i systémové Kontakty. Od **21p.31** si navíc vybereš, do kterého
adresáře: s nastaveným DAVx⁵ zvol adresář z miniserveru (1B, bod 3)
a kontakt se dostane na všechna zařízení. Důsledky:

- kontakt vidí i ostatní aplikace a **auto přes Bluetooth** (jméno na
  displeji, seznam kontaktů v autě),
- kontakty založené ve starších verzích aplikace se při první aktualizaci
  jednorázově přenesly do adresáře telefonu (dělá se samo, nic nenastavuj),
- smazání kontaktu v aplikaci ho smaže i z adresáře telefonu.

### Gotchas

- **Diakritika:** export z Googlu i z iCloudu je UTF-8 vCard 3.0 — čeština OK.
- **Fotky:** webový export z Googlu = jen URL → offline importem se ztratí
  (proto export z telefonu). U iCloudu to ověř po importu.
- **Štítky/skupiny:** při importu se typicky zahodí; kontakty projdou.
- **Duplicity:** import na miniserver přeskakuje kontakty, které tam už
  jsou, ale jen se stejným vnitřním označením. Tentýž člověk exportovaný
  dvakrát různými cestami se zdvojí. Proto exportuj jen jednou cestou
  a duplicity sluč ještě v Googlu.
- **Formát čísel:** drž **+420… (E.164)** — párování volajícího je na E.164
  nejspolehlivější (a sedí na to, co posílá miniserver). Sjednotit jde
  hromadně v Google Contacts (Sloučit a opravit) ještě před exportem.
- **Kalendáře z Googlu** se na miniserveru slijí do jednoho společného kalendáře.
  Pozvánky se přenesou jako obyčejné události, miniserver účastníkům nic
  neposílá.
- **Uživatelské profily telefonu:** kontakty jsou v každém profilu zvlášť —
  adresář z miniserveru musí být v profilu, kde běží aplikace Phone21 (1C).

Zdroje: [export Google kontaktů](https://support.google.com/contacts/answer/7199294),
[export Google kalendáře](https://support.google.com/calendar/answer/37111),
[export vCard z iCloudu](https://support.apple.com/guide/icloud-web-only/mmfba748b2/icloud),
[DAVx⁵](https://f-droid.org/packages/at.bitfire.davdroid/),
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
Phone21 rovnou patří (viz 1G), takže je auto vidí; čísla drž ve tvaru
+420…; (2) **hlasové ovládání z volantu** předává auto hlasovému
asistentovi telefonu — na telefonu bez asistenta nemá kdo povel obsloužit,
s aplikací to nesouvisí; (3) prázdnou mezinárodní předvolbu účtu si
aplikace od 21p.29 doplní sama podle SIM/jazyka telefonu.
