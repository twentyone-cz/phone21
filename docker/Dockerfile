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
# DIAGNOSTIKA: channel_new umí selhat tiše (bez logu) na dvou místech —
# přidáme explicitní ERROR log, ať je z produkčního logu vidět které.
RUN perl -0pi -e 's/if \(!cpvt\) \{\s*\n\s*return NULL;/if (!cpvt) {\n        ast_log(LOG_ERROR, "GSM2SIP-DBG: cpvt_alloc failed\\n");\n        return NULL;/s' src/channel.c \
 && perl -0pi -e 's/if \(!channel\) \{\s*\n\s*cpvt_free\(cpvt\);/if (!channel) {\n        ast_log(LOG_ERROR, "GSM2SIP-DBG: ast_channel_alloc failed\\n");\n        cpvt_free(cpvt);/s' src/channel.c \
 && [ "$(grep -c 'GSM2SIP-DBG' src/channel.c)" = "2" ]
# preferuj Ninja, fallback na make; RelWithDebInfo kvůli použitelným backtrace
RUN (cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
      || cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo) \
    && cmake --build build
RUN find build -name 'chan_quectel.so' -exec cp {} /chan_quectel.so \; \
    && test -f /chan_quectel.so

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      asterisk asterisk-core-sounds-en-gsm tzdata \
    && rm -rf /var/lib/apt/lists/* \
    # přístup na ttyUSB (gid 20 = dialout) — nezávisle na group_add v compose
    && usermod -aG dialout asterisk
COPY --from=build /chan_quectel.so /tmp/chan_quectel.so
RUN moddir="$(dirname "$(find /usr/lib -name 'chan_pjsip.so' -path '*asterisk*' | head -1)")" \
    && test -n "$moddir" \
    && install -m 644 /tmp/chan_quectel.so "$moddir/chan_quectel.so" \
    && rm /tmp/chan_quectel.so

# /etc/asterisk dodává bind-mount z runtime adresáře (viz docker-compose.yml)
# POZOR: bez -G! S rungroup Asterisk zahodí supplementary skupiny (dialout →
# Permission denied na ttyUSB). Samotné -U jde přes initgroups(), dialout drží.
CMD ["asterisk", "-f", "-U", "asterisk"]
