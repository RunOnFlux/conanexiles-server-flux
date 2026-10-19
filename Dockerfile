# Conan Exiles Enhanced dedicated server image for Flux.
#
# Written from scratch. The game's NATIVE Linux server (Steam app 443030, Unreal Engine 5 since
# the Enhanced relaunch), installed and updated with SteamCMD on every start, under a supervisor
# that writes the server's ini files from the environment, downloads the Workshop mods in load
# order, shuts down cleanly on stop, follows game updates with warnings in chat, restarts daily if
# asked, keeps backups of the world database, and gives the hub a JSON status, RCON, players,
# bans, mods and backups. See README.md.
#
# The base. CI builds it pinned to the digest it resolved and records that digest in the
# org.opencontainers.image.base.digest label, which the scheduled check compares against
# (.github/ci/needs-rebuild.sh).
ARG BASE_IMAGE=steamcmd/steamcmd:ubuntu-24
FROM ${BASE_IMAGE}

ARG DEBIAN_FRONTEND=noninteractive
ARG FLUX_IMAGE_VERSION=dev

# python3 (with sqlite3: consistent backups of the live world), util-linux for setpriv (Unreal
# refuses to run as root, so the server runs as uid 1000), procps for pgrep.
RUN apt-get update -y && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl procps tzdata python3 util-linux && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/flux-lib.sh scripts/flux-entrypoint.sh scripts/fluxconan.py /opt/flux/
RUN chmod 0755 /opt/flux/*.sh /opt/flux/fluxconan.py && \
    ln -s /opt/flux/fluxconan.py /usr/local/bin/flux-conan && \
    mkdir -p /home/conan && chown 1000:1000 /home/conan

# SteamCMD's self-update, done once here instead of on every container start; the weekly
# rebuild keeps it current.
RUN steamcmd +quit >/dev/null 2>&1; test -d /root/.local/share/Steam

ENV FLUX_IMAGE_VERSION=${FLUX_IMAGE_VERSION}

VOLUME ["/mnt/conan/server", "/mnt/conan/data"]

# The game (UDP, and Unreal's raw UDP port, the game port plus one), the Steam query (UDP) and
# RCON (TCP). All four move with CONAN_PORT / CONAN_QUERY_PORT / CONAN_RCON_PORT.
EXPOSE 7777/udp 7778/udp 27015/udp 25575/tcp

# The first start downloads about 4.3 GB. FluxOS does not act on health; this is for anyone
# running the image by hand.
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --retries=3 \
    CMD pgrep -x ConanSandboxSer >/dev/null || exit 1

ENTRYPOINT []
CMD ["/opt/flux/flux-entrypoint.sh"]
