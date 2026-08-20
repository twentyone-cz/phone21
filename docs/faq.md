# FAQ — provozní otázky a odpovědi

## Android dovolí jen jednu VPN — jak vedle miniserveru provozovat komerční VPN?

Android povolí jednu aktivní VPN na profil a aplikace
privátní sítě to místo zabere. Obojí naráz proto nejde spustit vedle sebe.

Co s tím:

- **Výstupní uzel uvnitř privátní sítě** — provoz telefonu jde ven přes
  vybrané zařízení v síti a jednu aplikaci tím zastanou obě role. Od verze
  0.9.31 to zvládne i sám miniserver: v ovládání na záložce Síť přepni
  přístup na **i dál do sítě** (trasu ještě musí schválit správa sítě).
- **Druhý uživatelský profil** na telefonu — limit platí na profil, takže
  v jednom může běžet komerční VPN a v druhém miniserver.

Bez toho platí prosté pravidlo: když si zapneš komerční VPN, hovory přes
miniserver po dobu jejího běhu nechodí.

## Aplikace při odchozím hovoru hlásí „Cannot place a call as there is already another call connecting…"

Kosmetická hláška samotné aplikace. Hovor se zakládá dvěma cestami —
jednou přes systémovou vrstvu pro telefonování (díky ní se hovory ukazují
na displeji auta) a jednou přímo v aplikaci; druhá cesta hlášku vypíše. Na
miniserver vždy dorazí jediný hovor a normálně se spojí, takže se dá
ignorovat. Systémovou integraci kvůli tomu nevypínej — přišel bys o
handsfree v autě.

## Volajícímu to po odmítnutí hovoru dál vyzvánělo — proč?

Stará chyba, opravená v srpnu 2026. Odmítnutí hovoru vypadalo pro
miniserver stejně jako nedostupný telefon, takže volajícímu vyzvánělo
dál. Dneska miniserver pozná rozdíl mezi „nezvedl to" a „aktivně odmítl"
a při odmítnutí zavěsí okamžitě — volající uslyší obsazeno a žádná
notifikace o zmeškaném hovoru nepřijde. Když se to chová jinak, máš
starou verzi.

## Jedou hovory po datové síti?

Ano, pokud to zvládne modem, SIM i síť. Ověření: během hovoru se
miniserver nesmí přepnout do starší mobilní sítě. Hlas po datové síti je
potřeba mít **aktivovaný na lince u operátora** — u některých se zapíná až
po prvním připojení běžného telefonu, takže novou SIM je občas nutné
jednou vložit do mobilu. Miniservery prodávané jako hotové řešení mají
tuhle část vyřešenou z výroby.

## Ostrovní režim: co se stane, když během něj přijde hovor?

Ostrovní režim je záloha internetu — když vypadne domácí linka,
miniserver si vezme připojení z mobilních dat SIM. Pro hovory má smysl
**jen s hlasem po datové síti**: hlas i data pak jedou současně, takže
hovor projde i v ostrovním režimu.

Bez toho se hovor přepne do starší mobilní sítě a mobilní data po tu dobu
nejedou. Prakticky to znamená, že v ostrovním režimu takový hovor
nedorazí — cesta k telefonu vede přes ta samá data. Miniserver to pozná,
napíše to do logu a spojení po hovoru sám postaví znovu; zprávy jdou po
jiné cestě a fungují dál. Stav vidíš v ovládání u dlaždice mobilní sítě.

## Posílá aplikace do privátní sítě všechen provoz telefonu?

Ne. Do privátní sítě jde jen provoz na miniserver — hovory, zprávy a jeho
web UI. Všechno ostatní (web, e-mail, streamování) jde z telefonu
normálně mimo privátní síť a miniserver o tom nic neví.

Obráceně to ve výchozím nastavení platí taky: miniserver nepustí provoz
z privátní sítě dál do domácí sítě ani do internetu a z jeho vlastních
služeb je vidět jen to, co telefon potřebuje. Od verze 0.9.25 si to
vynucuje sám, od 0.9.31 se to dá v ovládání (záložka Síť) povolit ve třech
stupních:

- **jen telefon** (výchozí) — hovory, zprávy, ovládání, párování;
- **celý miniserver** — všechny jeho služby (dashboard, další aplikace,
  vzdálená správa); dál než na miniserver se pořád nedostaneš;
- **i dál do sítě** — miniserver propouští provoz do domácí sítě a ven,
  tedy funguje i jako výstupní uzel.

Domácí sítě se filtr netýká v žádném stupni.

Výjimkou je, když si výstupní uzel zapneš sám (viz otázka o komerční VPN
výš) — pak přes něj jde všechno, protože přesně o to jde.

## Po připojení aplikace přestal na telefonu fungovat internet

Zkontroluj systémové nastavení VPN: **Nastavení → Síť a internet → VPN →
Phone21 → „Blokovat připojení bez VPN"**. Tahle volba říká systému, že nic
nesmí ven mimo VPN — jenže privátní síť Phone21 vede jen telefonování,
takže zbytek telefonu zůstane odříznutý. Volbu u Phone21 vypni; aplikace
na zapnutou volbu od verze 21p.24 sama upozorní notifikací.

Od verze 21p.26 aplikace systému rovnou říká, že trvalé připojení
(always-on) nepodporuje — volba „Blokovat připojení bez VPN" se u ní už
vůbec nenabízí a omylem zapnout nejde.

(Pokud používáš jinou VPN na celý provoz, téhle volby se to netýká —
patří k té druhé aplikaci, ne k Phone21.)

## Potřebuju se k miniserveru dostat na dálku kvůli servisu

Od verze 0.9.25 je vzdálená správa z privátní sítě **standardně zavřená**.
Když je potřeba (servisní zásah, ladění), zapni ji v ovládání na záložce
**Síť** přepínačem „Povolit ladění" — projeví se do 15 s, přežije restart
a na dashboardu ji připomíná dlaždice. Po skončení práce ji zase vypni.

Kdyby se filtr zachoval nečekaně, jde vypnout i z domácí sítě: do souboru
`firewall.env` v datovém adresáři aplikace přidej řádek `FW_DISABLE=1`.
Do minuty se filtr vypne a miniserver jede dál.

## Aplikace v obchodě se přejmenovala — co s tím?

Od verze 0.9.26 se aplikace v obchodě jmenuje **Phone21** a je to nová
položka. Nainstaluj ji, přenes data z předchozí instalace (adresář
`app-data`) a starou aplikaci pak odinstaluj — postup je na
phone.twentyone.cz. Bez přenosu dat začneš s prázdným žurnálem zpráv,
novým heslem k ústředně a telefon bude potřebovat nový QR kód.

## Co se stane s kontakty, když přijdu o telefon?

Od verze 0.9.27 mohou kontakty i kalendář žít na miniserveru a telefon je
s ním jen synchronizuje. Nový telefon si po nastavení účtu stáhne všechno
zpátky. Účty pro jednotlivá zařízení se zakládají v ovládání na záložce
*Kontakty a kalendář*, kde se dá i naimportovat záloha ze starého telefonu.

## Proč se kontakty mimo domov nesynchronizují?

Synchronizace jde na adresu miniserveru — doma po wifi, mimo domov přes
privátní síť. Když privátní síť na telefonu neběží, synchronizace počká.
Od verze 21p.32 umí aplikace pustit do privátní sítě i synchronizační
aplikaci; bez toho se synchronizuje jen doma.

## Jsou kontakty na miniserveru šifrované?

V domácí síti jde přenos nešifrovaně po wifi (nikam ven neopouští tvůj
byt), mimo domov jde přes šifrovanou privátní síť. Na disku miniserveru
leží kontakty v otevřené podobě — ochranou je šifrovaný disk miniserveru,
ne aplikace.
