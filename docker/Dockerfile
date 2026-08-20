# Phone21 — image ústředny (Ubuntu 24.04) + ovladač LTE modemu
#
# Build:  docker compose build

FROM ubuntu:24.04 AS build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake ninja-build git ca-certificates \
      asterisk-dev libsqlite3-dev libasound2-dev \
    && rm -rf /var/lib/apt/lists/*
# plný clone včetně tagů (CMake si bere verzi z `git describe`)
RUN git clone https://github.com/RoEdAl/asterisk-chan-quectel /src
WORKDIR /src
# Lokální patche; build context je kořen repa.
COPY docker/patches/ /patches/
RUN git apply --verbose /patches/*.patch
# Ninja s fallbackem na make; linker flagy neměnit.
RUN (cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic" \
      || cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-Bsymbolic") \
    && cmake --build build
RUN find build -name 'chan_quectel.so' -exec cp {} /chan_quectel.so \; \
    && test -f /chan_quectel.so

FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# nástroje pro správu modemu, ostrovní režim a filtr provozu
RUN apt-get update && apt-get install -y --no-install-recommends \
      asterisk asterisk-core-sounds-en-gsm tzdata libqmi-utils \
      iproute2 iputils-ping dbus nftables \
    && rm -rf /var/lib/apt/lists/* \
    # přístup na sériové porty (dialout)
    && usermod -aG dialout asterisk
COPY --from=build /chan_quectel.so /tmp/chan_quectel.so
RUN moddir="$(dirname "$(find /usr/lib -name 'chan_pjsip.so' -path '*asterisk*' | head -1)")" \
    && test -n "$moddir" \
    && install -m 644 /tmp/chan_quectel.so "$moddir/chan_quectel.so" \
    && rm /tmp/chan_quectel.so

# Šablony a skripty zapečené v image (použijí se v režimu selfkonfigurace).
COPY asterisk/ /opt/phone21/templates/
COPY scripts/mbn-profile.sh scripts/wwan.sh docker/tunnel-firewall.sh /opt/phone21/scripts/
# Pravidla filtru pro provoz z privátní sítě.
COPY docker/tunnel-firewall.nft /opt/phone21/tunnel-firewall.nft
# sms-queue.sh musí být v obraze na cestě, kterou volá dialplan.
COPY scripts/sms-queue.sh /usr/local/phone21/sms-queue.sh
COPY docker/entrypoint.sh /opt/phone21/entrypoint.sh
RUN chmod +x /opt/phone21/entrypoint.sh /opt/phone21/scripts/*.sh \
      /usr/local/phone21/sms-queue.sh

# Spouštět bez -G; entrypoint bez env jen spustí ústřednu.
CMD ["/opt/phone21/entrypoint.sh"]
