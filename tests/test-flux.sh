#!/bin/bash
# Unit tests: the pure decisions in flux-lib.sh and fluxconan.py's file handling. No Docker, no
# Steam, no game. Run from the repository root.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# The daily restart is in TZ: the expectations below are UTC unless a test sets its own.
export TZ=UTC

# shellcheck source=scripts/flux-lib.sh
FLUX_LOG="" source scripts/flux-lib.sh

pass=0
fail=0
check() { # description, expected, actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"
  fi
}
status() { "$@" >/dev/null 2>&1; echo $?; }
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# --- Inputs ------------------------------------------------------------------------------------
check "7777 is a port" "7777" "$(flux_valid_port 7777)"
check "a leading zero is not octal" "7778" "$(flux_valid_port 07778)"
check "port 80 is refused" "1" "$(status flux_valid_port 80)"
check "65535 is refused (the game binds the next one)" "1" "$(status flux_valid_port 65535)"
check "a word is not a port" "1" "$(status flux_valid_port abc)"
check "the default ports do not clash" "1" "$(status flux_ports_clash 7777 27015 25575)"
check "a rolled block P..P+3 does not clash" "1" "$(status flux_ports_clash 40000 40002 40003)"
check "the query on the raw UDP port clashes" "0" "$(status flux_ports_clash 7777 7778 25575)"
check "RCON on the query port clashes" "0" "$(status flux_ports_clash 7777 27015 27015)"
check "restart time 5:00" "05:00" "$(flux_restart_time 5:00)"
check "restart time off" "" "$(flux_restart_time off)"
check "restart time 24:00 refused" "1" "$(status flux_restart_time 24:00)"
check "restart time words refused" "1" "$(status flux_restart_time noon)"
# 2026-10-11 12:00 UTC = 1791720000
check "next 05:00 after noon is tomorrow" "$((1791720000 - 43200 + 86400 + 18000))" "$(flux_next_daily 1791720000 05:00)"
check "next 13:30 after noon is today" "$((1791720000 + 5400))" "$(flux_next_daily 1791720000 13:30)"
check "the time is the zone's (Lisbon is UTC+1 in October)" "$((1791720000 + 5400 - 3600))" "$(TZ=Europe/Lisbon flux_next_daily 1791720000 13:30)"
check "the last warning is singular" "The server restarts in 1 minute. Find a safe spot: your progress is saved." "$(flux_restart_warning 1)"
check "a warning in minutes" "The server restarts in 15 minutes. Your progress is saved." "$(flux_restart_warning 15)"

# --- Restart budget ----------------------------------------------------------------------------
check "old restarts drop out of the window" "950 990" "$(flux_restarts_in_window 1000 100 800 950 990)"
check "a crash counts" "0" "$(status flux_restart_counts 'the server ended on its own (exit 139)')"
check "a game update does not count" "1" "$(status flux_restart_counts 'planned: game update 1 -> 2')"
check "a panel restart does not count" "1" "$(status flux_restart_counts 'requested: from the panel')"
check "prune keeps the newest" "c d" "$(flux_files_to_prune 2 a b c d | tr '\n' ' ' | sed 's/ $//')"
check "the marker's not-before" "123" "$(printf 'x\nnotbefore=123\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"
check "a marker without one" "0" "$(printf 'x\n' >"${tmp}/m"; flux_marker_not_before "${tmp}/m")"

# --- The game's log ------------------------------------------------------------------------------
# A real line (build 25792439, 2026-10-18).
stats='[2026.10.18-20.55.11:789][  3]LogServerStats: Status report. Uptime=120 Mem=5762875392:16300290048:8358457344:8916320256 CPU=2.122620:42.452400 Players=3 FPS=25.19:35.37:224.80 NPC_AILOD=0:0:0:12602'
check "players from the status report" "3" "$(flux_players_from_stats "${stats}")"
check "nothing from another line" "" "$(flux_players_from_stats '[x]LogNet: Players=4 joined')"

# --- Steam builds ------------------------------------------------------------------------------
cat >"${tmp}/manifest.acf" <<'EOF'
"AppState"
{
	"appid"		"443030"
	"buildid"		"25792439"
}
EOF
check "installed build" "25792439" "$(flux_installed_build "${tmp}/manifest.acf")"
check "public build from app_info" "25900000" "$(printf '%s\n' '"443030"' '{' '"depots"' '{' '"branches"' '{' '"public"' '{' '"buildid"		"25900000"' '}' '"conan-exiles-legacy"' '{' '"buildid"		"1"' '}' | flux_public_build)"

# --- fluxconan.py ------------------------------------------------------------------------------
data="${tmp}/data"
server="${tmp}/server"
cfgdir="${data}/Saved/Config/LinuxServer"
cx() { # VAR=value... command args: fluxconan.py with exactly these variables
  local vars=()
  while [[ "${1:-}" == *=* ]]; do vars+=("$1"); shift; done
  env -i PATH="${PATH}" FLUX_DATA_DIR="${data}" FLUX_SERVER_DIR="${server}" FLUX_RESTART_MARKER="${tmp}/restart-marker" \
    FLUX_GENERATION_FILE="${tmp}/generation" FLUX_PLAYERS_FILE="${tmp}/players" FLUX_GAME_PROCESS="no-such-process-xyz" FLUX_GAME_COMM="no-such-procxyz" \
    "${vars[@]}" python3 scripts/fluxconan.py "$@"
}
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d.get(k)
print(json.dumps(d) if isinstance(d,(dict,list)) else d)' "$@"; }
ini() { PYTHONPATH=scripts python3 -c 'import fluxconan as c,sys; print(c.ini_get(c.ini_read(sys.argv[1]), sys.argv[2], sys.argv[3]))' "$@"; }

# A ServerSettings.ini as the server writes it (excerpt, build 25792439).
mkdir -p "${cfgdir}"
printf ';METADATA=(Diff=true, UseCommands=true)\n[ServerSettings]\nMaxNudity=0\nPVPEnabled=False\nclanMaxSize=7\nServerPassword=\n' >"${cfgdir}/ServerSettings.ini"

cx CONAN_SERVER_NAME='My "Kingdom"' CONAN_SERVER_PASSWORD='join me' CONAN_ADMIN_PASSWORD=boss123 CONAN_MAX_PLAYERS=20 apply >"${tmp}/args"
check "the launch line" "-Port=7777 -QueryPort=27015 -MaxPlayers=20 -ServerName=My Kingdom -ServerPassword=joinme" "$(grep -v '^#' "${tmp}/args" | tr '\n' ' ' | sed 's/ $//')"
check "RCON is on in Game.ini" "1" "$(ini "${cfgdir}/Game.ini" RconPlugin RconEnabled)"
check "on the default port" "25575" "$(ini "${cfgdir}/Game.ini" RconPlugin RconPort)"
pw="$(ini "${cfgdir}/Game.ini" RconPlugin RconPassword)"
check "with a made-up password" "24" "${#pw}"
check "Game.ini is not world-readable (it holds the RCON password)" "600" "$(stat -c %a "${cfgdir}/Game.ini")"
check "max players in Game.ini too" "20" "$(ini "${cfgdir}/Game.ini" /Script/Engine.GameSession MaxPlayers)"
check "the admin password" "boss123" "$(ini "${cfgdir}/ServerSettings.ini" ServerSettings AdminPassword)"
check "the join password in ServerSettings" "joinme" "$(ini "${cfgdir}/ServerSettings.ini" ServerSettings ServerPassword)"
check "the server's own lines are kept" "7" "$(ini "${cfgdir}/ServerSettings.ini" ServerSettings ClanMaxSize)"
check "the metadata line is kept" "1" "$(grep -c '^;METADATA' "${cfgdir}/ServerSettings.ini")"
check "a key is replaced, not doubled" "1" "$(grep -ci '^ServerPassword=' "${cfgdir}/ServerSettings.ini")"
check "the name in Engine.ini" "My Kingdom" "$(ini "${cfgdir}/Engine.ini" OnlineSubsystem ServerName)"
check "both regions by default" "None" "$(ini "${cfgdir}/Engine.ini" Regions ExcludedRegions)"
cx apply >/dev/null
check "the made-up RCON password is kept" "${pw}" "$(ini "${cfgdir}/Game.ini" RconPlugin RconPassword)"
check "an empty admin password is empty" "" "$(ini "${cfgdir}/ServerSettings.ini" ServerSettings AdminPassword)"
cx CONAN_RCON_PASSWORD=owner-pass-1 CONAN_MAP_REGIONS=exiled-lands apply >/dev/null
check "the owner's RCON password wins" "owner-pass-1" "$(ini "${cfgdir}/Game.ini" RconPlugin RconPassword)"
check "Exiled Lands only leaves Siptah out" "IsleOfSiptah" "$(ini "${cfgdir}/Engine.ini" Regions ExcludedRegions)"
cx apply >/dev/null
check "back to both regions" "None" "$(ini "${cfgdir}/Engine.ini" Regions ExcludedRegions)"
cx CONAN_MAX_PLAYERS=500 apply >"${tmp}/args"
check "players above 70 are refused" "1" "$(grep -c 'WARN CONAN_MAX_PLAYERS' "${tmp}/args")"
check "and the default is used" "-MaxPlayers=40" "$(grep -- '-MaxPlayers' "${tmp}/args")"
cx CONAN_PORT=40000 CONAN_QUERY_PORT=40002 CONAN_RCON_PORT=40003 apply >"${tmp}/args"
check "rolled ports reach the launch line" "-Port=40000 -QueryPort=40002" "$(grep -E -- '^-(Port|QueryPort)=' "${tmp}/args" | tr '\n' ' ' | sed 's/ $//')"
check "and RCON's" "40003" "$(ini "${cfgdir}/Game.ini" RconPlugin RconPort)"
cx CONAN_SERVER_NAME= apply >"${tmp}/args"
check "an empty name is the default" "-ServerName=Conan Exiles on Flux" "$(grep -- '-ServerName' "${tmp}/args")"
printf '[OnlineSubsystemSteam]\nbUseBuildIdOverride=True\nBuildIdOverride=123\n' >>"${cfgdir}/Engine.ini"
cx apply >/dev/null
check "a stale UE4 build override is removed" "0" "$(grep -c 'BuildIdOverride' "${cfgdir}/Engine.ini")"

# Mods: the deployment's list, the panel's list, load order.
check "IDs and links are read, in order, once" '["2886779102", "880454836"]' "$(PYTHONPATH=scripts python3 -c 'import fluxconan as c,json; print(json.dumps(c.parse_ids("2886779102, https://steamcommunity.com/sharedfiles/filedetails/?id=880454836 2886779102 junk 12")))')"
cx CONAN_MODS="111111, 222222" mods >"${tmp}/mods"
check "the deployment's list" "111111" "$(jget mods.0.id <"${tmp}/mods")"
check "set-mods takes the panel's order" "0" "$(status cx CONAN_MODS="111111, 222222" set-mods '["222222", "333333", "111111"]')"
check "the panel's list stands while the deployment's is unchanged" "222222 333333 111111" "$(cx CONAN_MODS="111111, 222222" mods | python3 -c 'import json,sys;print(*[m["id"] for m in json.load(sys.stdin)["mods"]])')"
check "a changed deployment list replaces it" "444444" "$(cx CONAN_MODS="444444" mods | python3 -c 'import json,sys;print(*[m["id"] for m in json.load(sys.stdin)["mods"]])')"
check "a bad ID is refused" "2" "$(status cx set-mods '["12; rm"]')"
check "not a list is refused" "2" "$(status cx set-mods '{"a":1}')"
mkdir -p "${server}/steamapps/workshop/content/440900/444444" "${server}/steamapps/workshop/content/440900/555555/sub"
echo x >"${server}/steamapps/workshop/content/440900/444444/BetterThralls.pak"
echo x >"${server}/steamapps/workshop/content/440900/444444/BetterThralls-LinuxServer.pak"
echo x >"${server}/steamapps/workshop/content/440900/555555/sub/B.pak"
echo x >"${server}/steamapps/workshop/content/440900/555555/A.pak"
check "modlist.txt lines: the client pak only, by ID, in order" "*555555/A.pak *555555/sub/B.pak *444444/BetterThralls.pak" "$(PYTHONPATH=scripts FLUX_SERVER_DIR="${server}" python3 -c 'import fluxconan as c; print(*c.modlist_lines(["555555", "444444", "666666"]))')"
check "a downloaded mod says so" "True" "$(cx CONAN_MODS="444444" mods | jget mods.0.downloaded)"

# Backups of a live SQLite world, restore, new world, import.
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("pragma journal_mode=wal"); c.execute("create table t(v)"); c.execute("insert into t values (\"first\")"); c.commit()' "${data}/Saved/game_0.db"
check "a first backup" "1" "$(cx backup start | grep -c 'backup (start): flux/backups/')"
check "a second within the hour is skipped" "1" "$(cx backup start | grep -c 'skipped')"
check "unless forced (the panel's, as JSON)" "True" "$(sleep 1; cx backup manual force | grep -v '^#' | jget ok)"
check "the list says why" "manual start" "$(cx backups | python3 -c 'import json,sys;print(" ".join(b["reason"] for b in json.load(sys.stdin)["backups"]))')"
first="$(cx backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][-1]["name"])')"
check "the backup holds the world and the ini files" "Saved/Config/LinuxServer/Engine.ini Saved/Config/LinuxServer/Game.ini Saved/Config/LinuxServer/ServerSettings.ini Saved/game_0.db flux/mods.json" "$(python3 -c 'import tarfile,sys; print(*sorted(tarfile.open(sys.argv[1]).getnames()))' "${data}/flux/backups/${first}")"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("update t set v=\"second\""); c.commit()' "${data}/Saved/game_0.db"
check "keep: the 2 newest, the newest over a day, the newest over a week" "a b d f" "$(PYTHONPATH=scripts python3 -c '
import fluxconan as c
names=["20261011-120000-conan.tar.gz","20261011-110000-conan.tar.gz","20261011-100000-conan.tar.gz","20261009-120000-conan.tar.gz","20261008-120000-conan.tar.gz","20261001-120000-conan.tar.gz"]
now=c.backup_time(names[0])
k=c.backups_to_keep(names,2,now)
print(" ".join("abcdef"[i] for i,n in enumerate(names) if n in k))')"
check "a bad backup name is refused" "2" "$(status cx restore '../x.tar.gz')"
check "restore is pending (no server to quit)" "False" "$(cx restore "${first}" | jget serverQuit)"
cx do-restore >"${tmp}/restore"
check "the restore puts the world back" "first" "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select v from t").fetchone()[0])' "${data}/Saved/game_0.db")"
check "after a safety backup" "1" "$(grep -c 'before restoring' "${tmp}/restore")"
check "and it is no longer pending" "1" "$(status test -e "${data}/flux/restore-pending.json")"
cx new-world >/dev/null
cx do-restore >"${tmp}/restore"
check "a new world removes the database" "1" "$(status test -e "${data}/Saved/game_0.db")"
check "after a safety backup" "1" "$(grep -c 'before a new world' "${tmp}/restore")"
check "the ini files stay" "0" "$(status test -e "${cfgdir}/ServerSettings.ini")"
mkdir -p "${data}/flux/import"
echo "not a db" >"${data}/flux/import/game.db"
check "an upload that is not a world is refused" "2" "$(status cx import-world game.db)"
check "and deleted" "1" "$(status test -e "${data}/flux/import/game.db")"
python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table t(v)"); c.execute("insert into t values (\"ue4\")"); c.commit()' "${data}/flux/import/game.db"
check "an upload outside flux/import is refused" "2" "$(status cx import-world ../../Saved/x.db)"
check "a world upload is accepted" "True" "$(cx import-world game.db | jget ok)"
cx do-restore >"${tmp}/restore"
check "an older world goes in as game.db, for the server to convert" "ue4" "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select v from t").fetchone()[0])' "${data}/Saved/game.db")"
check "and says so" "1" "$(grep -c 'converts it' "${tmp}/restore")"

# Failed updates: a target that did not install is skipped for 6 hours.
mkdir -p "${server}/steamapps" && printf '"AppState"\n{\n\t"buildid"\t\t"100"\n}\n' >"${server}/steamapps/appmanifest_443030.acf"
cx update-target 200
cx update-check >/dev/null
check "a build that did not install is skipped" "0" "$(status cx update-skip 200)"
check "another build is not" "1" "$(status cx update-skip 300)"
cx update-target 100
cx update-check >/dev/null
check "a reached target clears the failure" "1" "$(status cx update-skip 200)"

# The panel's restart is a marker the supervisor acts on, one at a time.
check "no server, no restart" "3" "$(status cx restart)"
check "the marker" "notbefore=0" "$(PYTHONPATH=scripts FLUX_RESTART_MARKER="${tmp}/m2" python3 -c 'import fluxconan as c; c.request_restart("requested: test")'; sed -n 2p "${tmp}/m2")"
check "a second request joins the first" "False" "$(PYTHONPATH=scripts FLUX_RESTART_MARKER="${tmp}/m2" python3 -c 'import fluxconan as c; print(c.request_restart("requested: again"))')"

# Status for the hub.
printf '4 1791720000\n' >"${tmp}/generation"
printf '2' >"${tmp}/players"
cx state running
cx note nextRestart 1791800000
check "the generation" "4" "$(cx status | jget generation.n)"
check "the players" "2" "$(cx status | jget players)"
check "the state" "running" "$(cx status | jget state)"
check "the next daily restart" "1791800000" "$(cx status | jget nextRestart)"
check "the build" "100" "$(cx status | jget build)"
cx note nextRestart
check "removed" "None" "$(cx status | jget nextRestart)"
check "rcon without a server says so" "3" "$(status cx rcon listplayers)"
check "and in words the hub knows" "1" "$(cx rcon listplayers | grep -c 'no server is running')"

# Settings the panel queues for the next start (the PvP schedule).
check "the schedule is read (a key the file lacks is null)" "None" "$(cx settings | jget settings.RestrictPVPTime)"
check "settings are queued" "True" "$(cx set-settings '{"RestrictPVPTime": "True", "PVPTimeFridayStart": "1800"}' | jget ok)"
check "and shown as pending" "1800" "$(cx settings | jget pending.PVPTimeFridayStart)"
check "the admin password cannot be set this way" "2" "$(status cx set-settings '{"AdminPassword": "x"}')"
check "a value with a quote is refused" "2" "$(status cx set-settings '{"ServerMessageOfTheDay": "a\"b"}')"
cx apply >/dev/null
check "apply writes them" "1800" "$(ini "${cfgdir}/ServerSettings.ini" ServerSettings PVPTimeFridayStart)"
check "and clears the queue" "1" "$(status test -e "${data}/flux/settings-pending.json")"

# A mod the game refuses (the real block, from the build 25792439 log).
modlog="${tmp}/ConanSandbox.log"
cat >"${modlog}" <<'LOG'
[2026.10.19-15.33.05:632][  0]LogModManager: Error: Mod pak file: /mnt/conan/server/ConanSandbox/Mods/3722881816/StayBloody.pak failed check and will be excluded.
[2026.10.19-15.33.05:646][  0]LogModManager: Error: You are running incompatible mods with this version of the game. The following mods failed mounting:

 - /mnt/conan/server/ConanSandbox/Mods/3722881816/StayBloody.pak (Mod is too old and needs to be updated for this game version)
 - /mnt/conan/server/ConanSandbox/Mods/3700000001/Other.pak (Mod is too old and needs to be updated for this game version)

These mods cannot be loaded and could lead to crashes for the client or server. Please try to reinstall or validate these mods before playing.
[2026.10.19-15.33.05:646][  0]LogCore: FUnixPlatformMisc::RequestExit(bForce=true, ReturnCode=1, CallSite=<NoCallSiteInfo>)
LOG
check "failed mods are read from the block" "3722881816 StayBloody.pak 3700000001 Other.pak" "$(PYTHONPATH=scripts python3 -c 'import fluxconan as c,sys; print(*[x for m in c.failed_mods(open(sys.argv[1]).read()) for x in m[:2]])' "${modlog}")"
check "a log without the block has none" "[]" "$(echo 'LogInit: fine' | PYTHONPATH=scripts python3 -c 'import fluxconan as c,sys; print(c.failed_mods(sys.stdin.read()))')"
mkdir -p "${data}/Saved/Logs" "${data}/flux"
cp "${modlog}" "${data}/Saved/Logs/ConanSandbox.log"
printf '1 %s\n' "$(($(date +%s) - 100))" >"${tmp}/gen"
check "mods-failed finds them and records them" "2" "$(cx FLUX_ENGINE_LOG="${data}/Saved/Logs/ConanSandbox.log" FLUX_GENERATION_FILE="${tmp}/gen" mods-failed >/dev/null; python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["failedMods"]))' "${data}/flux/state.json")"
check "a log older than the generation is not blamed" "1" "$(status cx FLUX_ENGINE_LOG="${data}/Saved/Logs/ConanSandbox.log" FLUX_GENERATION_FILE="${tmp}/gen2" mods-failed)"
printf '1 %s\n' "$(($(date +%s) + 100))" >"${tmp}/gen3"
check "a log older than the generation (by time) is not blamed" "1" "$(status cx FLUX_ENGINE_LOG="${data}/Saved/Logs/ConanSandbox.log" FLUX_GENERATION_FILE="${tmp}/gen3" mods-failed)"
cx set-mods '["3722881816", "555555"]' >/dev/null
check "mods-fixed waits while a refused mod is listed" "1" "$(status cx mods-fixed)"
cx set-mods '["555555"]' >/dev/null
check "mods-fixed passes once they are off the list" "0" "$(status cx mods-fixed)"
check "and clears the record" "None" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("failedMods"))' "${data}/flux/state.json")"
check "state running clears a stale record" "None" "$(cx state running >/dev/null; python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("failedMods"))' "${data}/flux/state.json")"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
