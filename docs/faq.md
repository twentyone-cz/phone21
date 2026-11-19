# FAQ — provozní otázky a odpovědi

## Můžu mít vedle Phone21 zapnutou jinou VPN (komerční, firemní…)?

**Ano.** Od aplikace 6.2.4-21p.46 běží privátní síť ve výchozím stupni
**jen hovory** uvnitř aplikace Phone21 a systémovou VPN vůbec nepoužívá.
Místo pro VPN v Androidu tak zůstává volné a VPN libovolné jiné aplikace
může běžet souběžně — nic se nenastavuje. Hovory i zprávy jdou dál a hlas
je šifrovaný až do miniserveru; během hovoru to ukazuje štítek
„Šifrováno do miniserveru“.

Android dovolí jen jednu VPN naráz. Místo pro ni Phone21 potřebuje jen
v těchto případech:

- **Přístup na miniserver** a **vše přes miniserver** — tyhle stupně dávají
  privátní síť i ostatním aplikacím v telefonu, a to jde jen přes systémovou
  VPN. Když běží jiná VPN, aplikace se zeptá, jestli ji vypnout. Když
  odmítneš, hovory jedou dál uvnitř aplikace a přístup ostatních aplikací
  zůstane vypnutý.
- **Synchronizovat kontakty i přes privátní síť** — synchronizační aplikace
  je jiná aplikace, proto i ve stupni jen hovory potřebuje místo pro VPN.
  Když běží jiná VPN, kontakty se přes privátní síť nesynchronizují; doma
  po wifi se synchronizuje účet s adresou pro domácí síť.

Kvůli samotnému souběhu s VPN už pracovní profil (např. aplikace Shelter)
potřeba není. Má smysl jen tehdy, když chceš vyšší stupeň přístupu a zároveň
jinou VPN: limit jedné VPN platí na profil, takže jiná VPN může běžet
v hlavním profilu a Phone21 v pracovním.

**„Vše přes miniserver“ (výstupní uzel) komerční VPN nenahrazuje:** provoz
pak vychází z domácího připojení, ne z místa a pod adresou poskytovatele
VPN. Stupeň zároveň zpřístupní celou domácí síť a služby miniserveru všem
aplikacím v telefonu a výstup se zapne až po zhruba 90 s přímého spojení
(nikdy přes přenosový uzel).

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

Ne. Ve výchozím stupni jen hovory jde do privátní sítě jen provoz aplikace
Phone21 na miniserver — hovory, zprávy a nastavení účtu; ostatní aplikace
v telefonu do ní vůbec nevidí. Všechno ostatní (web, e-mail, streamování)
jde z telefonu normálně mimo privátní síť a miniserver o tom nic neví.

Obráceně to ve výchozím nastavení platí taky: miniserver nepustí provoz
z privátní sítě dál do domácí sítě ani do internetu a z jeho vlastních
služeb je vidět jen to, co telefon potřebuje. Od verze 0.9.25 si to
vynucuje sám a povolit se to dá ve třech stupních. Volí se v aplikaci na
obrazovce privátní sítě; ovládání miniserveru (záložka Síť) od verze 0.9.47
zvolený stupeň jen ukazuje:

- **jen hovory** (výchozí) — hovory, zprávy, ovládání, kontakty, párování;
  v telefonu se do sítě dostane jen aplikace Phone21 a místo pro VPN
  zůstává volné;
- **přístup na miniserver** — i ostatní aplikace v telefonu dosáhnou na
  všechny služby miniserveru (dashboard, další aplikace, vzdálená správa);
  dál než na miniserver se pořád nedostaneš;
- **vše přes miniserver** — všechen provoz telefonu jde ven přes miniserver,
  který ho propouští do domácí sítě i do internetu (výstupní uzel).

Druhé dva stupně potřebují v telefonu místo pro VPN (viz otázka o jiné VPN
výš). Domácí sítě se filtr netýká v žádném stupni.

Výjimkou je, když si výstupní uzel zapneš sám — pak přes něj jde všechno,
protože přesně o to jde.

## Po připojení aplikace přestal na telefonu fungovat internet

Zkontroluj systémové nastavení VPN: **Nastavení → Síť a internet → VPN →
Phone21 → „Blokovat připojení bez VPN"**. Tahle volba říká systému, že nic
nesmí ven mimo VPN — jenže privátní síť Phone21 vede jen telefonování,
takže zbytek telefonu zůstane odříznutý. Volbu u Phone21 vypni; aplikace
na zapnutou volbu od verze 21p.24 sama upozorní notifikací.

Od verze 21p.26 aplikace systému rovnou říká, že trvalé připojení
(always-on) nepodporuje — volba „Blokovat připojení bez VPN" se u ní už
vůbec nenabízí a omylem zapnout nejde.

Ve stupni jen hovory (od 21p.46) Phone21 systémovou VPN nepoužívá, takže
se tě tohle týká jen u vyšších stupňů nebo se zapnutou synchronizací
kontaktů přes privátní síť. (Pokud používáš jinou VPN na celý provoz, téhle
volby se to netýká — patří k té druhé aplikaci, ne k Phone21.)

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

## Ukradli mi telefon (nebo jsem ho ztratil) — co teď?

Číslo bydlí v miniserveru, takže o něj nepřicházíš. Ztracený telefon
odregistruj v **Moje síť**, v ovládání miniserveru na záložce **Telefon**
dej **Změnit heslo telefonu** (ztracený telefon se odpojí i z domácí
wifi) a na záložce Kontakty mu změň heslo nebo ho smaž. Nový telefon
připojíš QR kódem doma, nebo na dálku: ovládání otevřené z počítače
v privátní síti dá QR kód s jednorázovým klíčem do sítě a nový telefon ho
načte odkudkoli (miniserver od 0.9.42, aplikace od 6.2.4-21p.37). Celý
postup krok za krokem: phone.twentyone.cz/kradez.

## Co se stane s kontakty, když přijdu o telefon?

Od verze 0.9.27 mohou kontakty i kalendář žít na miniserveru a telefon je
s ním jen synchronizuje. Nový telefon si po nastavení účtu stáhne všechno
zpátky. Účty pro jednotlivá zařízení se zakládají v ovládání na záložce
*Kontakty a kalendář*, kde se dá i naimportovat záloha ze starého telefonu.

## Proč se kontakty mimo domov nesynchronizují?

Synchronizace jde na adresu miniserveru — doma po wifi, mimo domov přes
privátní síť. Když privátní síť na telefonu neběží, synchronizace počká.
Od verze 21p.32 umí aplikace pustit do privátní sítě i synchronizační
aplikaci (volba *Synchronizovat kontakty i přes privátní síť*, nebo stupeň
*přístup na miniserver*); bez toho se synchronizuje jen doma. Obojí
potřebuje v telefonu místo pro VPN — když běží VPN jiné aplikace,
synchronizace přes privátní síť nejede. Doma po wifi se synchronizuje
účet s adresou pro domácí síť.

## Jsou kontakty na miniserveru šifrované?

V domácí síti jde přenos nešifrovaně po wifi (nikam ven neopouští tvůj
byt), mimo domov jde přes šifrovanou privátní síť. Na disku miniserveru
leží kontakty v otevřené podobě — ochranou je šifrovaný disk miniserveru,
ne aplikace.
