# GSM2SIP — image: Asterisk 20 (Ubuntu 24.04) + ovladač LTE modemu
#
# Build:  docker compose build

FROM ubuntu:24.04 AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates \
      asterisk-dev libsqlite3-dev libasound2-dev \
    && rm -rf /var/lib/apt/lists/*
# plný clone včetně tagů — CMake si verzi bere z `git describe`
RUN git clone https://github.com/RoEdAl/asterisk-chan-quectel /src
WORKDIR /src
# Lokální patche (upstream je archivovaný). Cesty jsou relativní ke kořeni
# repa — build context je `.`, dockerfile docker/Dockerfile.
COPY docker/patches/ /patches/
RUN git apply --verbose /patches/*.patch
# Ninja s fallbackem na make; linker flagy jsou nutné, neměnit.
RUN (cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic" \
      || cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic") \
    && cmake --build build
RUN find build -name 'chan_quectel.so' -exec cp {} /chan_quectel.so \; \
    && test -f /chan_quectel.so

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# libqmi-utils: správa modemu přes QMI; iproute2/iputils: ostrovní režim
RUN apt-get update && apt-get install -y --no-install-recommends \
      asterisk asterisk-core-sounds-en-gsm tzdata libqmi-utils \
      iproute2 iputils-ping \
    && rm -rf /var/lib/apt/lists/* \
    # přístup na sériové porty (gid 20 = dialout)
    && usermod -aG dialout asterisk
COPY --from=build /chan_quectel.so /tmp/chan_quectel.so
RUN moddir="$(dirname "$(find /usr/lib -name 'chan_pjsip.so' -path '*asterisk*' | head -1)")" \
    && test -n "$moddir" \
    && install -m 644 /tmp/chan_quectel.so "$moddir/chan_quectel.so" \
    && rm /tmp/chan_quectel.so

# Selfkonfigurace: šablony a skripty zapečené v image (entrypoint je použije
# jen v režimu GSM2SIP_SELFCONFIG=1).
COPY asterisk/ /opt/gsm2sip/templates/
COPY scripts/mbn-profile.sh scripts/wwan.sh /opt/gsm2sip/scripts/
COPY docker/entrypoint.sh /opt/gsm2sip/entrypoint.sh
RUN chmod +x /opt/gsm2sip/entrypoint.sh /opt/gsm2sip/scripts/*.sh

# Spouštět bez -G (viz initgroups); entrypoint bez env = exec asterisk.
CMD ["/opt/gsm2sip/entrypoint.sh"]
