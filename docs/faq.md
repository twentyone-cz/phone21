# FAQ — provozní otázky a odpovědi

## Android dovolí jen jednu VPN — jak vedle brány provozovat komerční VPN?

Android (i GrapheneOS) povolí jednu aktivní VPN na profil. Řešení je sloučit
obojí do jednoho WireGuard profilu se **dvěma peery**: WireGuard routuje
podle nejdelšího prefixu, takže rozsah privátní sítě jde na bránu a
`0.0.0.0/0, ::/0` na komerční VPN. Privátní klíč přitom nemusí opustit
telefon — config od poskytovatele se naskenuje do aplikace a peer brány se
doplní ručně (veřejný klíč brány, AllowedIPs rozsahu privátní sítě,
PersistentKeepalive 25). Výpadek VPN pak shodí internet telefonu, ale hovory
přes bránu jedou dál.

Alternativy: druhá VPN v jiném uživatelském profilu (limit je per-profil),
nebo exit node uvnitř privátní sítě.

## Linphone při odchozím hovoru hlásí „Cannot place a call as there is already another call connecting…"

Kosmetický artefakt aplikace (souhra s Telecom integrací, která je zapnutá
kvůli handsfree v autě): hovor se zakládá jednou přes Telecom vrstvu a
jednou v UI, druhá cesta ohlásí toast — na bránu vždy dorazí jediný hovor
a proběhne normálně (ověřeno logem 2026-08-03). Neřešit, neexistuje k tomu
známý upstream bug; Telecom integraci nevypínat (přišli bychom o hovory na
displeji auta). Sledovat, zda nezmizí s aktualizací Linphone.

## Volajícímu to po odmítnutí hovoru dál vyzvánělo — proč?

Opraveno 2026-08-03: 603 Decline (kauza 21) a 486 Busy (kauza 17) Asterisk
mapuje do stejných DIALSTATUS jako nedosažitelnost; dialplan proto nově
testuje `HANGUPCAUSE` a při aktivní odpovědi telefonu okamžitě zavěsí
(žádná notifikace, žádné do-vyzvánění). Diagnostika: každý příchozí hovor
loguje `Dial konec: DIALSTATUS=… HANGUPCAUSE=…` v messages.log.

## Jedou hovory přes VoLTE?

Ano, pokud to zvládne modem, SIM i síť. Ověření: během hovoru se telefon
nesmí přepnout z LTE na 2G/3G. VoLTE je potřeba mít **aktivované na lince
u operátora** — u některých se zapíná až po prvním připojení běžného
telefonu, takže novou SIM je občas nutné jednou vložit do mobilu. Krabičky
prodávané jako hotové řešení mají tuhle část vyřešenou z výroby.

## Ostrovní režim: co se stane, když během něj přijde hovor?

Ostrovní režim je záloha internetu — když vypadne domácí linka, krabička
si vezme připojení z mobilních dat SIM. Pro hovory má smysl **jen
s VoLTE**: hlas i data pak jedou po LTE současně, takže hovor projde
i v ostrovním režimu.

Bez VoLTE se hovor přepne do 2G (CSFB) a mobilní data po tu dobu nejedou.
Prakticky to znamená, že v ostrovním režimu bez VoLTE hovor nedorazí —
cesta k telefonu vede přes ta samá data. Krabička to pozná, napíše to do
logu a spojení po hovoru sama postaví znovu; SMS jdou po jiné cestě
a fungují dál. Stav VoLTE vidíš v aplikaci u dlaždice mobilní sítě.

## Posílá WireGuard do tunelu všechen provoz telefonu?

Ne — profil má `AllowedIPs = rozsah privátní sítě` (split tunnel): do tunelu jde jen
SIP/RTP/SMS na bránu (a web UI brány). Ostatní provoz jde
normálně mimo tunel. Brána navíc dropuje forward z `wg0` mimo tunel, takže
telefon se přes ni nedostane do LAN ani do internetu. Pozor: řádek
`DNS = 1.1.1.1` v profilu přesměruje DNS celého telefonu na Cloudflare
(nešifrovaně, mimo tunel), pokud není aktivní Private DNS (DoT) — ten má
přednost. Volbu „Blokovat spojení mimo VPN" nezapínat (zablokovala by
všechen provoz mimo AllowedIPs).
