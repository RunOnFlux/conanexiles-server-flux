#!/bin/bash
# Runs INSIDE the image (tests/test-image.sh). The repository's tests/ folder is mounted at /t.
set -uo pipefail
export LC_ALL=C

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
wait_for() {
  local _
  for _ in $(seq 1 $(($2 * 5))); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}
jget() { python3 -c 'import json,sys
d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d=d[int(k)] if isinstance(d,list) else d.get(k)
print(d)' "$1"; }

# --- What the scripts need is in the image -----------------------------------------------------
for tool in steamcmd python3 pgrep pkill setpriv timeout tail sed; do
  check "${tool} is installed" "0" "$(status command -v "${tool}")"
done
check "flux-conan is on the PATH" "0" "$(status command -v flux-conan)"
check "python3 has sqlite3 (consistent backups)" "0" "$(status python3 -c 'import sqlite3')"
for script in flux-entrypoint.sh flux-lib.sh; do
  check "${script} parses" "0" "$(status bash -n "/opt/flux/${script}")"
done

# --- The supervisor, around a stand-in Steam and a stand-in server -------------------------------
cat >/usr/local/bin/steamcmd <<'STUB'
#!/bin/bash
dir="" ws=()
while [ $# -gt 0 ]; do
  case "$1" in
    +force_install_dir) dir="$2"; shift ;;
    +workshop_download_item) ws+=("$3"); shift 2 ;;
  esac
  shift
done
[ -n "${dir}" ] || exit 0
mkdir -p "${dir}/ConanSandbox/Binaries/Linux" "${dir}/linux64" "${dir}/steamapps"
printf '"AppState"\n{\n\t"appid"\t\t"443030"\n\t"buildid"\t\t"25792439"\n}\n' >"${dir}/steamapps/appmanifest_443030.acf"
: >"${dir}/linux64/steamclient.so"
cp /t/image/fake-server.py "${dir}/ConanSandbox/Binaries/Linux/ConanSandboxServer-Linux-Shipping"
chmod 755 "${dir}/ConanSandbox/Binaries/Linux/ConanSandboxServer-Linux-Shipping"
for id in "${ws[@]}"; do
  mkdir -p "${dir}/steamapps/workshop/content/440900/${id}"
  echo pak >"${dir}/steamapps/workshop/content/440900/${id}/Mod${id}.pak"
done
STUB
chmod +x /usr/local/bin/steamcmd

export FLUX_SERVER_DIR=/tmp/srv FLUX_DATA_DIR=/tmp/data FLUX_RESTART_BACKOFF=1 FLUX_STOP_GRACE=20
CONAN_SERVER_NAME='Test "Server"' CONAN_ADMIN_PASSWORD=boss123 CONAN_SERVER_PASSWORD=joinsecret1 CONAN_PORT=40000 CONAN_QUERY_PORT=40002 CONAN_RCON_PORT=40003 \
  CONAN_MODS="111111, 222222" /opt/flux/flux-entrypoint.sh >/tmp/sup.log 2>&1 &
sup=$!
check "the server comes up and is marked running" "0" "$(status wait_for "grep -q 'the server is up (generation 1)' /tmp/sup.log" 30)"
check "it runs as uid 1000, not root" "1000" "$(ps -o uid= -p "$(pgrep -x ConanSandboxSer)" | tr -d ' ')"
check "the launch line carries the rolled ports and the name without quotes" "0" "$(status grep -q 'Command Line: ConanSandbox -log -Port=40000 -QueryPort=40002 -MaxPlayers=40 -ServerName=Test Server -ServerPassword=<hidden>' /tmp/sup.log)"
check "the join password is never in the container output" "0" "$(grep -c joinsecret1 /tmp/sup.log)"
check "nor in flux.log" "0" "$(grep -c joinsecret1 /tmp/srv/flux-logs/flux.log)"
check "the RCON karma limit is high" "100000" "$(sed -n 's/^RconMaxKarma=//p' /tmp/data/Saved/Config/LinuxServer/Game.ini)"
check "Saved is the data volume" "/tmp/data/Saved" "$(readlink /tmp/srv/ConanSandbox/Saved)"
check "the game's logs are local" "/tmp/srv/flux-local/logs-game" "$(readlink /tmp/data/Saved/Logs)"
check "RCON answers through flux-conan" "0" "$(status bash -c 'flux-conan rcon help | grep -q listplayers')"
check "RCON listens on the rolled port" "40003" "$(sed -n 's/^RconPort=//p' /tmp/data/Saved/Config/LinuxServer/Game.ini)"
check "players reads an empty roster" "[]" "$(flux-conan players | jget players)"
check "the status says running" "running" "$(flux-conan status | jget state)"
check "the version is read from the log" "3.0.1" "$(flux-conan status | jget version)"
check "the player count from the status line" "0" "$(wait_for "[ \"\$(flux-conan status | jget players)\" = 0 ]" 10; flux-conan status | jget players)"
check "mods are downloaded and listed in order" "*111111/Mod111111.pak *222222/Mod222222.pak" "$(tr '\n' ' ' </tmp/srv/ConanSandbox/Mods/modlist.txt | sed 's/ $//')"
check "each mod is linked by its ID" "/tmp/srv/steamapps/workshop/content/440900/111111" "$(readlink /tmp/srv/ConanSandbox/Mods/111111)"
check "no backup of a world that does not exist yet" "0" "$(find /tmp/data/flux/backups -name '*-conan.tar.gz' 2>/dev/null | wc -l)"
check "the generation is published for the hub" "1" "$(cut -d' ' -f1 /tmp/flux-generation)"
check "the admin password is written" "1" "$(grep -c '^AdminPassword=boss123' /tmp/data/Saved/Config/LinuxServer/ServerSettings.ini)"
check "the start-up noise stays out of the container output" "0" "$(grep -c 'FindRow' /tmp/sup.log)"

# The panel's restart: a marker; the server is stopped, mods re-applied, a new generation.
flux-conan set-mods '["222222"]' >/dev/null
check "a ban of an offline player is queued, no restart" "False True" "$(flux-conan ban 76561198000000005 griefing | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d["online"],d["pending"])')"
check "the restart is not done for it" "1" "$(status test -e /tmp/flux-restart-requested)"
check "a restart is accepted" "True" "$(flux-conan restart | jget ok)"
check "the next generation comes up" "0" "$(status wait_for "grep -q 'the server is up (generation 2)' /tmp/sup.log" 30)"
check "the server got SIGINT (a clean shutdown)" "0" "$(status grep -q 'Engine exit requested' /tmp/sup.log)"
check "a requested restart is not a crash" "0" "$(grep -c 'restarts within' /tmp/sup.log)"
check "the new mods list is applied" "*222222/Mod222222.pak" "$(cat /tmp/srv/ConanSandbox/Mods/modlist.txt)"
check "the queued ban is in blacklist.txt at the next start, owned by the server's user" "76561198000000005 1000" "$(cat /tmp/data/Saved/blacklist.txt) $(stat -c %u /tmp/data/Saved/blacklist.txt)"
check "and no longer queued" "[]" "$(flux-conan bans | jget pending)"
check "the dropped mod's link is gone" "1" "$(status test -L /tmp/srv/ConanSandbox/Mods/111111)"

# A restore: pending, applied between two servers, after a safety backup.
sleep 1
flux-conan backup manual force >/dev/null
first="$(flux-conan backups | python3 -c 'import json,sys;print(json.load(sys.stdin)["backups"][-1]["name"])')"
check "a restore restarts the server" "True" "$(flux-conan restore "${first}" | jget serverQuit)"
check "the server comes back after the restore" "0" "$(status wait_for "grep -q 'the server is up (generation 3)' /tmp/sup.log" 30)"
check "the restore was applied" "0" "$(status grep -q 'restore: restored' /tmp/sup.log)"
check "a broadcast reaches the server" "0" "$(status bash -c 'flux-conan rcon broadcast hello there && sleep 1 && grep -q "broadcast: hello there" /tmp/srv/flux-local/logs/current.log')"

# A crash: restarted in place, reported with its code.
flux-conan rcon crash >/dev/null 2>&1
check "a crash is restarted in place" "0" "$(status wait_for "grep -q 'the server is up (generation 4)' /tmp/sup.log" 30)"
check "the crash is reported with its code" "0" "$(status grep -q 'exit 139' /tmp/sup.log)"

# A mod the game refuses: no restart loop, a state naming the mod, the server starts once it is off the list.
flux-conan set-mods '["111111", "999999"]' >/dev/null
flux-conan restart >/dev/null
check "a refused mod puts the supervisor in needs-mod-fix" "0" "$(status wait_for "[ \"\$(flux-conan status | jget state)\" = needs-mod-fix ]" 40)"
check "the status names the mod" "999999" "$(flux-conan status | jget failedMods.0.id)"
check "the message names the mod" "yes" "$(flux-conan status | jget message | grep -q 999999 && echo yes)"
starts="$(grep -c 'starting the server (generation' /tmp/sup.log)"
sleep 5
check "it does not restart in a loop" "${starts}" "$(grep -c 'starting the server (generation' /tmp/sup.log)"
check "the restart budget is untouched" "0" "$(grep -c 'restarts within' /tmp/sup.log)"
flux-conan set-mods '["111111"]' >/dev/null
check "the server starts once the mod is off the list" "0" "$(status wait_for "grep -q 'the server is up (generation $((starts + 1)))' /tmp/sup.log" 40)"
check "needs-mod-fix is cleared" "running" "$(flux-conan status | jget state)"

# A stop with a teardown that takes minutes (the real server's): killed after FLUX_STOP_SETTLE_SECONDS,
# well inside Docker's ten seconds.
touch /tmp/slow-teardown
start="$(date +%s)"
kill -TERM "${sup}"
wait "${sup}"
took=$(($(date +%s) - start))
check "a stop exits 0" "0" "$?"
check "a stop with a minutes-long teardown still takes under 8 s" "yes" "$([ "${took}" -lt 8 ] && echo yes || echo "no (${took}s)")"
check "the world was checkpointed after the kill" "0" "$(status grep -q 'checkpoint busy=0' /tmp/sup.log)"
check "the server was ended, not waited for" "0" "$(status grep -q 'stopped on request (server exited 137)' /tmp/sup.log)"
check "nothing is left running" "1" "$(status pgrep -x ConanSandboxSer)"
check "the state says stopped" "stopped" "$(flux-conan status | jget state)"
check "the world database is intact" "ok" "$(python3 -c "import sqlite3;print(sqlite3.connect('/tmp/data/Saved/game_0.db').execute('pragma integrity_check').fetchone()[0])")"
check "the world was marked as seen" "0" "$(status grep -q '"seen"' /tmp/data/flux/worlds.json)"
rm -f /tmp/slow-teardown

# --- The world guard: a start on a volume whose world has not arrived (a half-synced g: volume) ---
rm -f /tmp/data/Saved/game_0.db /tmp/data/Saved/game_0.db-wal /tmp/data/Saved/game_0.db-shm
/opt/flux/flux-entrypoint.sh >/tmp/sup2.log 2>&1 &
sup=$!
check "a missing world this server had: the start waits for the sync" "0" "$(status wait_for "[ \"\$(flux-conan status | jget state)\" = updating ] && grep -q 'Waiting for it to sync' /tmp/sup2.log" 30)"
check "with the reason in the state" "1" "$(flux-conan status | jget message | grep -c 'Waiting for it to sync')"
check "and the game is not started on nothing" "1" "$(status pgrep -x ConanSandboxSer)"
check "no new world was made" "1" "$(status test -e /tmp/data/Saved/game_0.db)"
kill -TERM "${sup}"
wait "${sup}"
check "a stop while waiting exits 0" "0" "$?"
FLUX_WORLD_SYNC_GRACE_SECONDS=0 /opt/flux/flux-entrypoint.sh >/tmp/sup2.log 2>&1 &
sup=$!
check "after the wait, the newest backup is put back and the server starts" "0" "$(status wait_for "grep -q 'the server is up (generation 1)' /tmp/sup2.log" 30)"
check "and says so" "0" "$(status grep -q 'restored the newest backup' /tmp/sup2.log)"
check "the status says which" "missing" "$(flux-conan status | jget worldRestored.reason)"
kill -TERM "${sup}"
wait "${sup}"

# --- flux.log is local; the banner ----------------------------------------------------------------
fl_srv="/tmp/srv"
fl_data="/tmp/data"
check "flux.log is on the install volume" "0" "$(status test -s "${fl_srv}/flux-logs/flux.log")"
check "and not on the synced data volume" "1" "$(status test -e "${fl_data}/flux/flux.log")"
check "the banner is in the container output" "0" "$(status grep -q 'Conan Exiles server image by FluxCloud - https://runonflux.com' /tmp/sup.log)"
check "and in flux.log" "0" "$(status grep -q 'Host this and 30+ other games in one click: https://runonflux.com/games' "${fl_srv}/flux-logs/flux.log")"
check "at the container start and again for each generation" "1" "$([ "$(grep -c 'server image by FluxCloud' /tmp/sup.log)" -ge 2 ] && echo 1 || echo 0)"

printf '%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" = "0" ] || { echo "--- supervisor log"; grep -av "LogServerStats" /tmp/sup.log | head -60; exit 1; }
