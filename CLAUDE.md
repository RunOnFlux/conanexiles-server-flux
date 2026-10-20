# CLAUDE.md

Guidance for Claude Code in this repository.

## What this is

A **Docker image repo**, not an application: the Conan Exiles Enhanced dedicated server for Flux,
`runonflux/conanexiles-server-flux`. steamcmd/steamcmd:ubuntu-24, the game's native Linux UE5 server
(Steam app 443030, anonymous) and a bash supervisor. Same family as `~/work/soulmask-server-flux`,
`~/work/corekeeper-server-flux`, `~/work/tf2-server-flux`.

**The container supervises its own server.** PID 1 is `flux-entrypoint.sh`, never the game. The game
is a child (uid 1000), so a stop reaches us first and a server that ends on its own is followed by
the next one in place.

## Commands

```bash
./tests/test-flux.sh
docker build --build-arg FLUX_IMAGE_VERSION=1.0.0 -t conanexiles-server-flux:local .
./tests/test-image.sh                    # the scripts INSIDE the built image (stand-in steamcmd + server)
docker run --rm -v "$PWD:/m" -w /m koalaman/shellcheck:stable -x scripts/*.sh tests/*.sh tests/image/*.sh .github/ci/*.sh
```

A change to what the image does bumps `VERSION` and gets a line under "Versions" in the README.

## The files

- `scripts/flux-entrypoint.sh`: PID 1. Per generation: SteamCMD update, Saved/ linked to the data
  volume, mods from the Workshop, a pending restore / new world, a backup, `fluxconan.py apply`
  (ini files + launch args on stdout), the server, then the watcher (ready, updates, daily restart,
  checkpoints), the backupper and the log capper.
- `scripts/fluxconan.py`: every decision about the server's files and the hub's commands
  (`flux-conan ...`), incl. the RCON client. The one place those rules live.
- `scripts/flux-lib.sh`: shared helpers; **sourcing it must stay side-effect free** (tests source it).
- `tests/image/fake-server.py`: the stand-in server (RCON, a SQLite world, the refused-mod block, a
  600 s teardown when `/tmp/slow-teardown` exists). **Its shebang must be `#!/usr/bin/python3`**:
  with `env` the process name becomes `python3` and `pgrep -x ConanSandboxSer` finds nothing.

## Things that will bite you

- **The stop** (README "The stop"): RCON checkpoint, SIGINT, 3 s, SIGKILL, offline checkpoint. The
  game's own shutdown is 1-4 min and writes nothing; Flux allows 10 s. Do not wait for it.
- **Not as root.** Unreal refuses it; volumes are chowned every start.
- **RCON needs `RconPassword`/`RconPort` in Game.ini** ("Rcon disabled" if only in ServerSettings.ini).
  `sql <query>` runs arbitrary SQL on the world (writes too); there is no save command and no player
  `kick` of offline players. `help` lists ~25 commands.
- **A refused mod exits 1 about 3.5 s after launch**, stdout lost (forced exit). The block
  "The following mods failed mounting" is only in `Saved/Logs/ConanSandbox.log`; the supervisor reads
  that, goes to `needs-mod-fix` and does not count a restart.
- **UE4 mods do not load on Enhanced.** Only Enhanced-built Workshop items.
- **Map regions:** `exiled-lands` saves ~3.7 GB RAM.
- **Backups copy the SQLite world with its online-backup API**, never the loose file (WAL).
- **Empty env = unset.** **Flux stops a container with Docker's default 10 seconds.**
- The game's stdout is not reliable at exit; its log file is. The version string in the log ends
  with a dot ("3.0.1.").
- **`flux.log` is local** (`$FLUX_SERVER_DIR/flux-logs/flux.log`, 5 MB then one `.1`), never on the synced data volume: a constantly written file there is constant Syncthing traffic. `flux_log_migrate` moves an old one off the data volume at start. `flux_banner` prints the FluxCloud banner at container start and every generation; its text is tested.
- **The scheduled CI run publishes only with something to apply** (`.github/ci/needs-rebuild.sh`): urgent security updates, or commits on main since the published `:latest` (label `org.opencontainers.image.revision`) that touch the image inputs.
