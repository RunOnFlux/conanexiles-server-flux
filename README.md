# conanexiles-server-flux

The Conan Exiles Enhanced dedicated server for [Flux](https://runonflux.io), as
`runonflux/conanexiles-server-flux`. The game's native Linux server (Steam app 443030, Unreal
Engine 5, anonymous download), installed and updated with SteamCMD on every start, run as uid 1000
under a supervisor that:

- writes `Game.ini` (RCON, max players), `Engine.ini` (name, join password, map regions) and the
  owned keys of `ServerSettings.ini` (admin password) from the environment; every other
  `ServerSettings.ini` key is the hub panel's (or yours) and survives
- downloads the Steam Workshop mods anonymously in load order and writes `modlist.txt`
- **stops inside Docker's 10 s** (see "The stop"): RCON checkpoint, SIGINT, 3 s, SIGKILL, checkpoint
  of the dead database. The game's own shutdown takes 1-4 minutes and writes nothing
- restarts the server in place when it ends on its own, with a budget (5 in an hour, then exit 42);
  **a mod the game refuses is not a crash**: no restart, state `needs-mod-fix` naming the mod
- follows game updates (a restart onto the new build, players warned in chat over RCON first) and
  restarts daily at `CONAN_RESTART_TIME`
- makes consistent backups of the world database (SQLite online backup) on start, every 6 hours and
  on request; restores one, imports an uploaded `game_0.db`, or starts a new world, each after a
  safety backup
- gives the hub a JSON status, players, bans, mods, settings and backups (`flux-conan ...`)

## Volumes

| Path | Flux mount | What |
|---|---|---|
| `/mnt/conan/data` | `g:` (synced) | `Saved/` (`game_0.db` the world, `Config/LinuxServer/*.ini`; the install's `ConanSandbox/Saved` is a link to it) and `flux/` (state, rcon password, mods list, backups) |
| `/mnt/conan/server` | `ml:server` (local) | the game install, 4.2 GB, the Workshop downloads, `flux-local/` (game logs, crash dumps, extracted mods) Also `flux-logs/flux.log` (our supervisor log, 5 MB then one `.1`): local, never synced. |

Spec: `g:/mnt/conan/data|ml:server:/mnt/conan/server`.

## Ports

Game UDP 7777 (+ Unreal's raw port, the game port + 1 = 7778), Steam query UDP 27015, RCON TCP 25575.
RCON is always on (the hub drives the game through `flux-conan` inside the container, so **it need
not be published**); its password is `CONAN_RCON_PASSWORD` or one made up once in `flux/rcon-password`.

## Environment

A variable **set to a value** is applied on every start; one **not set or set empty** (the marketplace
writes every declared parameter, blank ones as `NAME=`) takes the default.

| Variable | Default | |
|---|---|---|
| `CONAN_SERVER_NAME` | Conan Exiles on Flux | name in the browser (quotes removed) |
| `CONAN_ADMIN_PASSWORD` | none | `MakeMeAdmin` in game |
| `CONAN_SERVER_PASSWORD` | none | join password |
| `CONAN_MAX_PLAYERS` | 40 | 1-70 (the spec fixes it per tier) |
| `CONAN_MAP_REGIONS` | `all` | `all` or `exiled-lands` (4.9 GiB instead of 8.6 GiB idle) |
| `CONAN_MODS` | none | Workshop IDs or links, in load order. Enhanced needs Enhanced-built mods; a UE4 mod is refused |
| `CONAN_RCON_PASSWORD` | made up once | |
| `CONAN_PORT` / `CONAN_QUERY_PORT` / `CONAN_RCON_PORT` | 7777 / 27015 / 25575 | the hub rolls them (public = container port) |
| `CONAN_RESTART_TIME` | 06:00 in the spec | `HH:MM` in `TZ`, players warned 15, 5, 1 min before |

Supervisor knobs: `FLUX_STOP_SETTLE_SECONDS` (3), `FLUX_CHECKPOINT_MINUTES` (5), `FLUX_BACKUP_HOURS`
(6), `FLUX_BACKUP_KEEP` (10), `FLUX_UPDATE_CHECK_MINUTES` (30), `FLUX_RESTART_MAX_ATTEMPTS` (5 in
`FLUX_RESTART_WINDOW` 3600 s), `SKIP_UPDATE`.

## The stop

`game_0.db` is SQLite in WAL mode and the server commits to it every few seconds while it plays
(measured: the WAL changes every 10-35 s even on an empty server). After SIGINT the server answers
nothing on RCON within a second, writes nothing to the database, and spends 60-245 s unloading
levels. So the stop is: `sql pragma wal_checkpoint(TRUNCATE)` through RCON, SIGINT (players leave
and are saved), 3 s, SIGKILL, `flux-conan checkpoint` on the dead database. Proved with
`docker stop` at the default 10 s (7 s, exit 0) and with `kill -9`: integrity_check ok, a row written
by RCON `sql` just before the stop is there after the restart. What is lost is only what the server
had not yet committed (a few seconds of play). Not verified with players connected.

## For the hub

`flux-conan status|players|bans|mods|set-mods|settings|set-settings|restart|backups|backup|restore|new-world|import-world|rcon`
(see the top of `scripts/fluxconan.py`). `status.state`: `updating`, `starting`, `running`,
`restarting`, `needs-mod-fix` (with `failedMods`: id, file, reason), `crashed`, `stopped`.

## Measured (build 25792439, UE 5.8.2, 2026-10-19)

See `~/work/game-drafts/conanexiles/NOTES.md`: install 4.2 GB (download 4.45 GB), ready ~20-45 s,
idle RAM 8.6 GiB all regions / 4.9 GiB Exiled Lands, CPU ~20 % of a core idle.

## Versions

- **1.0.0** (2026-10-19): first release.
- **1.0.1** (2026-10-20): `flux.log` moved off the synced data volume to `/mnt/conan/server/flux-logs/flux.log` (5 MB, one `.1`; an old one is moved there once); start-up banner; the weekly rebuild only when it has something to apply.
