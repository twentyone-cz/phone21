# FAQ — provozní otázky a odpovědi

## Android dovolí jen jednu VPN — jak vedle miniserveru provozovat komerční VPN?

Android (i GrapheneOS) povolí jednu aktivní VPN na profil a aplikaci
privátní sítě to místo zabere. Obojí naráz proto nejde spustit vedle sebe.

Co s tím:

- **Výstupní uzel uvnitř privátní sítě** — provoz telefonu jde ven přes
  vybrané zařízení v síti a jednu aplikaci tím zastanou obě role.
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

## Jedou hovory přes VoLTE?

Ano, pokud to zvládne modem, SIM i síť. Ověření: během hovoru se telefon
nesmí přepnout z LTE na 2G/3G. VoLTE je potřeba mít **aktivované na lince
u operátora** — u některých se zapíná až po prvním připojení běžného
telefonu, takže novou SIM je občas nutné jednou vložit do mobilu.
Miniservery prodávané jako hotové řešení mají tuhle část vyřešenou
z výroby.

## Ostrovní režim: co se stane, když během něj přijde hovor?

Ostrovní režim je záloha internetu — když vypadne domácí linka,
miniserver si vezme připojení z mobilních dat SIM. Pro hovory má smysl
**jen s VoLTE**: hlas i data pak jedou po LTE současně, takže hovor
projde i v ostrovním režimu.

Bez VoLTE se hovor přepne do 2G (CSFB) a mobilní data po tu dobu nejedou.
Prakticky to znamená, že v ostrovním režimu bez VoLTE hovor nedorazí —
cesta k telefonu vede přes ta samá data. Miniserver to pozná, napíše to
do logu a spojení po hovoru sám postaví znovu; SMS jdou po jiné cestě
a fungují dál. Stav VoLTE vidíš v aplikaci u dlaždice mobilní sítě.

## Posílá aplikace do privátní sítě všechen provoz telefonu?

Ne. Do privátní sítě jde jen provoz na miniserver — hovory, zprávy a jeho
web UI. Všechno ostatní (web, e-mail, streamování) jde z telefonu
normálně mimo privátní síť a miniserver o tom nic neví.

Obráceně to platí taky: miniserver nepustí provoz z privátní sítě dál do
domácí sítě ani do internetu. Telefon se přes něj tedy nedostane nikam
jinam než k němu samotnému — není to router ani výstupní uzel.

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
