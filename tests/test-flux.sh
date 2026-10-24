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

# --- Passwords out of the logs ----------------------------------------------------------------
check "the log filter hides the passwords" "LogInit: Command Line: ConanSandbox -log -Port=7777 -ServerPassword=<hidden> -AdminPassword=<hidden> -MaxPlayers=20" \
  "$(printf 'LogInit: Command Line: ConanSandbox -log -Port=7777 -ServerPassword=joinme -AdminPassword="a b" -MaxPlayers=20\n' | flux_log_filter)"
check "and drops NUL bytes" "abc" "$(printf 'a\0\0b\0c\n' | flux_log_filter)"
check "flux_log hides it too" "x -ServerPassword=<hidden> -Y=1" "$(FLUX_LOG="" flux_log_raw 'x -ServerPassword=secret -Y=1')"

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

# The game's own rotating copies are not the world: a new world or a restore leaves them.
mkdir -p "${data}/Saved"
: >"${data}/Saved/game_0_backup_1.db"
: >"${data}/Saved/game_0.db-wal"
PYTHONPATH=scripts FLUX_DATA_DIR="${data}" python3 -c 'import fluxconan as c; c.remove_world()'
check "remove_world keeps game_0_backup_N.db" "0" "$(status test -e "${data}/Saved/game_0_backup_1.db")"
check "and removes the world's sidecars" "1" "$(status test -e "${data}/Saved/game_0.db-wal")"
check "and the world" "1" "$(status test -e "${data}/Saved/game.db")"
rm -f "${data}/Saved/game_0_backup_1.db"

# Backups and restores are staged on the LOCAL volume, never on the synced one.
mkdb() { python3 -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("create table if not exists t(v)"); c.execute("delete from t"); c.execute("insert into t values (?)",(sys.argv[2],)); c.commit()' "$@"; }
wval() { python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("select v from t").fetchone()[0])' "$1"; }
mkdb "${data}/Saved/game_0.db" three
cx backup manual force >/dev/null
check "the backup was staged in flux-local/tmp" "0" "$(status test -d "${server}/flux-local/tmp")"
check "nothing staged on the data volume" "0" "$(find "${data}" -name '.flux-*' | wc -l)"

# A safety backup that fails stops a new world, an import or a restore: the world stays.
# (backups into a folder that cannot be made: under a file, which stops root as well)
rm -f "${data}/flux/worlds.json"
: >"${tmp}/not-a-dir"
cx new-world >/dev/null
cx FLUX_BACKUP_DIR="${tmp}/not-a-dir/backups" do-restore >"${tmp}/restore"
check "a failed safety backup keeps the world" "three" "$(wval "${data}/Saved/game_0.db")"
check "and says so" "1" "$(grep -c 'NOT done: the safety backup failed' "${tmp}/restore")"
check "in status.lastAction too" "new-world False" "$(cx status | python3 -c 'import json,sys;a=json.load(sys.stdin)["lastAction"];print(a["kind"],a["ok"])')"
check "the request is dropped" "1" "$(status test -e "${data}/flux/restore-pending.json")"
check "a failed backup exits 1 (the panel's: ok false)" "1 False" "$(cx FLUX_BACKUP_DIR="${tmp}/not-a-dir/backups" backup manual force >"${tmp}/b"; echo "$? $(grep -v '^#' "${tmp}/b" | jget ok)")"
check "a new world is not marked while the backup fails" "1" "$(status test -e "${data}/flux/worlds.json")"

# A restore puts back the backup's mods list, with the deployment's CONAN_MODS as it is now.
cx CONAN_MODS="777777" set-mods '["777777"]' >/dev/null
sleep 1
cx CONAN_MODS="777777" backup manual force >/dev/null
withmods="$(cx backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][0]["name"])')"
cx CONAN_MODS="888888" mods >/dev/null
cx CONAN_MODS="888888" restore "${withmods}" >/dev/null
cx CONAN_MODS="888888" do-restore >/dev/null
check "a restore brings its mods list back" "777777" "$(cx CONAN_MODS="888888" mods | python3 -c 'import json,sys;print(*[m["id"] for m in json.load(sys.stdin)["mods"]])')"

# The world guard. A world that is there starts, and is remembered by world-seen.
guard() { cx FLUX_WORLD_SYNC_GRACE_SECONDS="${grace:-300}" world-guard; }
check "guard: a world that is there starts" "0" "$(status guard)"
cx world-seen
check "world-seen remembers it" "1" "$(python3 -c 'import json,sys;print(int("seen" in json.load(open(sys.argv[1]))))' "${data}/flux/worlds.json")"
mkdb "${data}/Saved/game_0.db" four
rm -f "${data}/Saved/game_0.db"
check "guard: a missing world first waits for the sync" "3" "$(status guard)"
check "and says so" "1" "$(guard | grep -c 'Waiting for it to sync before putting a backup back')"
check "no backup put back yet" "1" "$(status test -e "${data}/Saved/game_0.db")"
grace=0 guard >"${tmp}/guard.out"
check "guard: after the wait, the newest backup is put back, not a new world" "three" "$(wval "${data}/Saved/game_0.db")"
check "and says so" "1" "$(grep -c 'restored the newest backup' "${tmp}/guard.out")"
check "in the state too" "missing" "$(cx status | jget worldRestored.reason)"
mv "${data}/flux/backups" "${tmp}/backups-aside"
rm -f "${data}/Saved/game_0.db"
grace=0 guard >"${tmp}/guard.out"
check "guard: no backup, but the world existed: wait" "3" "$(grace=0 status guard)"
check "with the reason" "1" "$(grep -c 'waiting for it to sync' "${tmp}/guard.out")"
echo "not sqlite" >"${data}/Saved/game_0.db"
check "guard: an unusable game_0.db is no world" "3" "$(grace=0 status guard)"
check "and is kept aside, not deleted" "1" "$(find "${data}/Saved" -name 'game_0.db.flux-unusable-*' | wc -l)"
rm -f "${data}/Saved"/game_0.db.flux-unusable-* "${data}/flux/worlds.json"
: >"${data}/Saved/game_0_backup_2.db"
check "guard: the game's own copies are a sign of a world too" "3" "$(grace=0 status guard)"
rm -f "${data}/Saved/game_0_backup_2.db"
check "a brand new server (no trace of a world) starts" "0" "$(grace=0 status guard)"
mv "${tmp}/backups-aside" "${data}/flux/backups"
cx world-seen
cx new-world >/dev/null
cx do-restore >/dev/null
check "guard: after the panel's new world, a missing world starts" "0" "$(status guard)"
check "an imported UE4 game.db is a world" "0" "$(mkdb "${data}/Saved/game.db" ue4; status guard)"
rm -f "${data}/Saved/game.db"
# A stop in the middle of a restore, after the world went and before the new one was in place
# (the request then still pending, or already gone): the guard puts a backup back.
cx world-seen 2>/dev/null; mkdb "${data}/Saved/game_0.db" five; cx world-seen
rm -f "${data}/Saved/game_0.db"
grace=0 guard >/dev/null
check "guard: a world lost mid-restore comes back from the backups" "0" "$(status test -s "${data}/Saved/game_0.db")"
# Syncthing conflict copies: moved aside, never a world, never in a backup.
cp "${data}/Saved/game_0.db" "${data}/Saved/game_0.sync-conflict-20261023-101010-ABCDEFG.db"
touch "${cfgdir}/ServerSettings.sync-conflict-20261023-101010-ABCDEFG.ini"
guard >/dev/null
check "conflict copies are moved to flux/sync-conflicts" "2 0" "$(find "${data}/flux/sync-conflicts" -type f | wc -l) $(find "${data}/Saved" -name '*sync-conflict*' | wc -l)"

# Unreal's UTF-16 ini files (written so when a value has a character outside ASCII).
printf '[ServerSettings]\r\nServerName=Caf\xc3\xa9\r\nAdminPassword=old\r\n' | python3 -c 'import sys; sys.stdout.buffer.write(b"\xff\xfe" + sys.stdin.buffer.read().decode().encode("utf-16-le"))' >"${tmp}/u16.ini"
check "a UTF-16 ini is read" "Café" "$(ini "${tmp}/u16.ini" ServerSettings ServerName)"
PYTHONPATH=scripts python3 -c 'import fluxconan as c,sys; c.ini_apply(sys.argv[1], [("ServerSettings", "AdminPassword", "new")])' "${tmp}/u16.ini"
check "and written back as UTF-16 with its BOM" "fffe" "$(head -c 2 "${tmp}/u16.ini" | od -An -tx1 | tr -d ' \n')"
check "the key replaced, not doubled" "new 1 1" "$(ini "${tmp}/u16.ini" ServerSettings AdminPassword) $(python3 -c 'import sys; t=open(sys.argv[1],encoding="utf-16").read(); print(t.count("AdminPassword"), t.count("[ServerSettings]"))' "${tmp}/u16.ini")"
check "a UTF-8 ini stays UTF-8" "utf-8" "$(PYTHONPATH=scripts python3 -c 'import fluxconan as c,sys; print(c.ini_encoding(sys.argv[1]))' "${cfgdir}/Engine.ini")"

# RCON: the karma limit, and a refused connection is one line, not a traceback.
cx apply >/dev/null
check "RconMaxKarma is high by default" "100000" "$(ini "${cfgdir}/Game.ini" RconPlugin RconMaxKarma)"
cx CONAN_RCON_MAX_KARMA=500 apply >/dev/null
check "CONAN_RCON_MAX_KARMA sets it" "500" "$(ini "${cfgdir}/Game.ini" RconPlugin RconMaxKarma)"
check "a bad one is the default" "100000" "$(cx CONAN_RCON_MAX_KARMA=lots apply >/dev/null; ini "${cfgdir}/Game.ini" RconPlugin RconMaxKarma)"
# A server that takes the connection and drops it at once (the karma system's denial).
python3 -c '
import socket,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 0)); s.listen(8)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    c,_=s.accept(); c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, b"\1\0\0\0\0\0\0\0"); c.close()
' "${tmp}/rport" &
deny_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${tmp}/rport" ] && break; sleep 0.2; done
cx CONAN_RCON_PORT="$(cat "${tmp}/rport")" apply >/dev/null
cx rcon listplayers >"${tmp}/rcon.out" 2>&1
check "a refused RCON connection exits 3" "3" "$?"
check "with one line saying so, no traceback" "1 0" "$(grep -c 'RCON refused the connection' "${tmp}/rcon.out") $(grep -c Traceback "${tmp}/rcon.out")"
check "players: the same, as JSON" "3" "$(status cx players)"
kill "${deny_pid}" 2>/dev/null
cx apply >/dev/null

# Workshop mod updates: Steam's time_updated against SteamCMD's record.
mkdir -p "${server}/steamapps/workshop"
cat >"${server}/steamapps/workshop/appworkshop_440900.acf" <<'ACF'
"AppWorkshop"
{
	"appid"		"440900"
	"WorkshopItemsInstalled"
	{
		"444444"
		{
			"size"		"10"
			"timeupdated"		"1700000000"
			"manifest"		"1"
		}
		"555555"
		{
			"size"		"10"
			"timeupdated"		"1700000500"
			"manifest"		"2"
		}
	}
	"WorkshopItemDetails"
	{
		"444444"
		{
			"timeupdated"		"1"
		}
	}
}
ACF
check "installed mod times from the acf" "{'444444': 1700000000, '555555': 1700000500}" "$(PYTHONPATH=scripts FLUX_SERVER_DIR="${server}" python3 -c 'import fluxconan as c; print(c.installed_mod_times())')"
check "only a newer, installed, not recently failed mod needs a restart" "['444444']" "$(PYTHONPATH=scripts python3 -c '
import fluxconan as c
print(c.mods_needing_update(["444444","555555","666666","777777"], {"444444":2,"555555":5,"666666":9,"777777":9}, {"444444":1,"555555":5,"777777":1}, {"777777":{"target":9,"at":100}}, 200))')"
# A stand-in for Steam's GetPublishedFileDetails.
python3 -c '
import http.server,json,sys,urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        form=urllib.parse.parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        ids=[form[f"publishedfileids[{i}]"][0] for i in range(int(form["itemcount"][0]))]
        body=json.dumps({"response":{"publishedfiledetails":[{"publishedfileid":i,"result":1,"time_updated":1700000900} for i in ids]}}).encode()
        self.send_response(200); self.send_header("Content-Length",str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self,*a): pass
s=http.server.HTTPServer(("127.0.0.1",0),H); open(sys.argv[1],"w").write(str(s.server_port)); s.serve_forever()
' "${tmp}/apiport" &
api_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "${tmp}/apiport" ] && break; sleep 0.2; done
api="http://127.0.0.1:$(cat "${tmp}/apiport")/"
cx set-mods '["444444", "555555"]' >/dev/null
check "a newer mod on Steam is found" "444444 555555" "$(cx FLUX_WORKSHOP_API="${api}" mods-update-check)"
check "and is in the status" '["444444", "555555"]' "$(cx status | jget modUpdateWaiting)"
check "mods-sync records an update that did not land" "2" "$(cx mods-sync | grep -c 'did not install')"
check "so it is not retried" "1" "$(status cx FLUX_WORKSHOP_API="${api}" mods-update-check)"
kill "${api_pid}" 2>/dev/null
check "Steam unreachable: no restart, a warning" "1 1" "$(cx FLUX_WORKSHOP_API=http://127.0.0.1:9/ mods-update-check >"${tmp}/mu"; echo "$? $(grep -c 'could not ask Steam' "${tmp}/mu")")"
check "no mods: nothing to ask" "1" "$(cx set-mods '[]' >/dev/null; status cx FLUX_WORKSHOP_API="${api}" mods-update-check)"

# Bans: an offline player (or no server) is queued; apply writes the queue into blacklist.txt,
# which the server reads only at start.
check "a ban needs a SteamID64" "2" "$(status cx ban 12345)"
check "with no server, a ban is queued" '{"ok": true, "online": false, "pending": true, "appliesOn": "restart"}' "$(cx ban 76561198000000001 cheating on purpose)"
cx ban 76561198000000001 >/dev/null
cx ban 76561198000000002 >/dev/null
check "the queue, deduplicated" '["76561198000000001", "76561198000000002"]' "$(cx bans | jget pending)"
check "bans without RCON: empty, with the reason, not a failure" "0 [] 1" "$(cx bans >"${tmp}/bans"; echo "$? $(jget bans <"${tmp}/bans") $(grep -c '"error"' "${tmp}/bans")")"
check "unban takes one off the queue" '{"ok": true}' "$(cx unban 76561198000000002)"
check "the queue after it" '["76561198000000001"]' "$(cx bans | jget pending)"
printf '76561198000000009\n76561198000000001\n' >"${data}/Saved/blacklist.txt"
cx ban 76561198000000003 >/dev/null
cx apply >"${tmp}/args"
check "apply writes the queued bans not listed yet" "76561198000000009 76561198000000001 76561198000000003" "$(tr '\n' ' ' <"${data}/Saved/blacklist.txt" | sed 's/ $//')"
check "and says so" "1" "$(grep -c 'bans from the panel: 1 written' "${tmp}/args")"
check "and clears the queue" "1" "$(status test -e "${data}/flux/bans-pending.json")"
check "the launch line is unchanged by it" "0" "$(grep -c 'blacklist' <(grep -v '^#' "${tmp}/args"))"
cx unban 76561198000000009 >/dev/null
check "unban with no server takes the line out of blacklist.txt" "76561198000000001 76561198000000003" "$(tr '\n' ' ' <"${data}/Saved/blacklist.txt" | sed 's/ $//')"
rm -f "${data}/Saved/blacklist.txt"
cx ban 76561198000000004 >/dev/null
cx apply >/dev/null
check "blacklist.txt is made when there is none" "76561198000000004" "$(cat "${data}/Saved/blacklist.txt")"

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
cx note nextRestart 1791800000
cx state stopped
check "a stopped server has no next restart" "None" "$(cx status | jget nextRestart)"
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

# --- flux.log: local, rotated, migrated; the start-up banner -------------------------------------
lt="$(mktemp -d)"
rule='====================================================================='
want="$(printf '%s\n %s server image by FluxCloud - https://runonflux.com\n Host this and 30+ other games in one click: https://runonflux.com/games\n%s' "${rule}" "Test Game" "${rule}")"
banner_out="$(FLUX_LOG="${lt}/logs/flux.log" flux_banner "Test Game")"
check "the banner is exactly the FluxCloud text" "${want}" "${banner_out}"
check "the banner is ASCII only" "0" "$(printf '%s' "${banner_out}" | LC_ALL=C grep -c -P '[^\x00-\x7F]')"
check "the banner goes to flux.log too" "${want}" "$(cat "${lt}/logs/flux.log")"
# shellcheck source=scripts/flux-lib.sh
check "flux.log lives in flux-logs on the install volume by default" "/x/flux-logs/flux.log" "$(unset FLUX_LOG FLUX_LOG_DIR; FLUX_SERVER_DIR=/x; source scripts/flux-lib.sh; echo "${FLUX_LOG}")"
check "an empty FLUX_LOG writes no file" "" "$(FLUX_LOG="" flux_log hello >/dev/null; ls "${lt}/none" 2>/dev/null)"
for i in $(seq 1 40); do FLUX_LOG="${lt}/logs/flux.log" FLUX_LOG_MAX_BYTES=500 flux_log "line number ${i} padding padding padding" >/dev/null; done
check "flux.log rotates to one .1" "1" "$([ -s "${lt}/logs/flux.log.1" ] && echo 1 || echo 0)"
check "and the live file stays under the cap" "1" "$([ "$(stat -c %s "${lt}/logs/flux.log")" -le 600 ] && echo 1 || echo 0)"
check "no second rotated copy" "1" "$(status test -e "${lt}/logs/flux.log.2")"
printf 'old 1\nold 2\n' >"${lt}/old.log"
printf 'new 1\n' >"${lt}/mig.log"
FLUX_LOG="${lt}/mig.log" flux_log_migrate "${lt}/old.log" "${lt}/absent.log"
check "an old flux.log is appended to the new one" "new 1 old 1 old 2" "$(tr '\n' ' ' <"${lt}/mig.log" | sed 's/ $//')"
check "and deleted from the data volume" "1" "$(status test -e "${lt}/old.log")"
check "migrating with nothing to migrate is harmless" "0" "$(FLUX_LOG="${lt}/mig.log" status flux_log_migrate "${lt}/old.log")"
rm -rf "${lt}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ]
