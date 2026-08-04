# GSM2SIP — vlastní image: Asterisk 20 (Ubuntu 24.04) + chan_quectel (RoEdAl fork)
#
# Proč vlastní image: starší image obsahuje starý
# chan_quectel, který (ověřeno) segfaultuje Asterisk při odesílání DTMF do
# modemu a neumí ccinfo/dsci hangup detection. RoEdAl fork obojí řeší
# (dsci=on pro modem, dtmf_duration) — repo je archivované (2024), ale
# stabilní; buildí se ze zdrojáků proti Asterisku z image, takže ABI sedí.
#
# Build (na Pi, nativně arm64, ~5-10 min):  sudo docker compose build

FROM ubuntu:24.04 AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates \
      asterisk-dev libsqlite3-dev libasound2-dev \
    && rm -rf /var/lib/apt/lists/*
# plný clone včetně tagů — CMake si verzi bere z `git describe`
RUN git clone https://github.com/RoEdAl/asterisk-chan-quectel /src
WORKDIR /src
# Lokální patche. Upstream je archivovaný (2024), takže je neseme u sebe.
# 0001: msg_send() testoval interní API(), což se ptá PŘÍCHOZÍCH
#   handlerů, jestli zprávu umí směrovat do dialplanu — pro odchozí směr to
#   nedává smysl a podmínka byla navíc obrácená. Důsledek: SMS z chatu (přišla
#   přes kontext [messages], takže destinaci má) driver zahodil s „Destination
#   number not specified", zatímco SMS z AMI (bez dialplanové destinace) prošla
#   do větve, kde je ast_msg_get_to() prázdné → PDU s nulovou délkou příjemce,
#   na které modem zatuhl. Nově se testuje přímo prázdné číslo příjemce.
# cesty relativně ke kořeni repa (build context: ., dockerfile: docker/Dockerfile)
COPY docker/patches/ /patches/
RUN git apply --verbose /patches/*.patch
# preferuj Ninja, fallback na make; RelWithDebInfo kvůli použitelným backtrace.
# -Bsymbolic je KRITICKÉ: interní symboly modulu (channel_new, cpvt_alloc, ...)
# nejsou static a volají se přes PLT. V procesu Asterisku je i cizí knihovna,
# která exportuje VLASTNÍ globální `channel_new` — bez -Bsymbolic dynamický
# linker navázal volání na cizí knihovna, ta vracela NULL a odchozí hovory padaly
# na "Unable to allocate channel structure" (ověřeno objdump + /proc/maps,
# 2026-07-20). S -Bsymbolic se interní reference váží už při linku.
RUN (cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic" \
      || cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic") \
    && cmake --build build
RUN find build -name 'chan_quectel.so' -exec cp {} /chan_quectel.so \; \
    && test -f /chan_quectel.so

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# libqmi-utils: MBN profil (VoLTE) + wwan data; iproute2/iputils: ostrovní režim
RUN apt-get update && apt-get install -y --no-install-recommends \
      asterisk asterisk-core-sounds-en-gsm tzdata libqmi-utils \
      iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/* \
    # přístup na ttyUSB (gid 20 = dialout) — nezávisle na group_add v compose
    && usermod -aG dialout asterisk
COPY --from=build /chan_quectel.so /tmp/chan_quectel.so
RUN moddir="$(dirname "$(find /usr/lib -name 'chan_pjsip.so' -path '*asterisk*' | head -1)")" \
    && test -n "$moddir" \
    && install -m 644 /tmp/chan_quectel.so "$moddir/chan_quectel.so" \
    && rm /tmp/chan_quectel.so

# Selfkonfigurace (Umbrel): šablony + skripty zapečené v image; v LXC režimu
# se nepoužijí (config dodává bind-mount, entrypoint pak nic nerenderuje).
# POZOR: build context je KOŘEN repa (docker-compose.yml: context: .,
# dockerfile: docker/Dockerfile) — kvůli přístupu k asterisk/ a scripts/.
COPY asterisk/ /opt/gsm2sip/templates/
COPY scripts/mbn-profile.sh scripts/wwan.sh /opt/gsm2sip/scripts/
COPY docker/entrypoint.sh /opt/gsm2sip/entrypoint.sh
RUN chmod +x /opt/gsm2sip/entrypoint.sh /opt/gsm2sip/scripts/*.sh

# POZOR: bez -G! S rungroup Asterisk zahodí supplementary skupiny (dialout →
# Permission denied na ttyUSB). Samotné -U jde přes initgroups(), dialout drží.
# Entrypoint bez env proměnných dělá přesně: exec asterisk -f -U asterisk.
CMD ["/opt/gsm2sip/entrypoint.sh"]
