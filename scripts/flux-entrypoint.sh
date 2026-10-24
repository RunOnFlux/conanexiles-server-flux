#!/bin/bash
# PID 1, and the supervisor of the Conan Exiles Enhanced server.
#
# The game runs as a CHILD, never exec, so a stop reaches us first and becomes a clean shutdown,
# and a server that ends on its own is followed by the next one in place:
#
#   - every start: SteamCMD update, a pending restore / new world / uploaded world applied and the
#     world guard (no new world over a missing one this server had), the mods list downloaded from
#     the Workshop (modlist.txt in its order), a backup of the world, Game.ini,
#     Engine.ini and the image's keys of ServerSettings.ini from the environment (fluxconan.py apply,
#     whose output is the launch arguments), then the server, as an unprivileged user (Unreal
#     refuses root)
#   - SIGTERM/SIGINT from Docker: SIGINT to the server, which shuts down cleanly (the world is a
#     SQLite database the server writes as the game goes)
#   - a new build on Steam: an outdated server refuses players on the new client, so it is
#     restarted onto it, players warned in chat over RCON first
#   - CONAN_RESTART_TIME: a daily restart at that time (in TZ, UTC when unset), players warned first
#   - the server ending on its own: a new generation in the same container; FLUX_RESTART_MAX_ATTEMPTS
#     unplanned ones inside FLUX_RESTART_WINDOW seconds end the container with 42
#   - a backup on start (unless one is under an hour old) and every FLUX_BACKUP_HOURS
#   - the panel's restart (flux-conan restart) is a marker: the supervisor stops the server for it
#
# Same shape as runonflux/corekeeper-server-flux and runonflux/tf2-server-flux.

set -uo pipefail
# shellcheck source=scripts/flux-lib.sh
source /opt/flux/flux-lib.sh

FLUX_RESTART_MAX_ATTEMPTS="${FLUX_RESTART_MAX_ATTEMPTS:-5}"
FLUX_RESTART_WINDOW="${FLUX_RESTART_WINDOW:-3600}"
FLUX_RESTART_BACKOFF="${FLUX_RESTART_BACKOFF:-10}"
# How long a server asked to stop may take before it is killed. The server starts shutting down
# the moment it gets SIGINT (players are dropped within a second), then tears the world down for
# one minute (the Exiled Lands only) to four (the whole map), measured. Docker's own deadline on
# Flux is ten seconds, which cuts that teardown short; this grace is for a restart, where nobody is
# waiting on us and the next server must not start beside the old one.
FLUX_STOP_GRACE="${FLUX_STOP_GRACE:-30}"
# After SIGINT the server is given this long (players leaving are saved), then it is killed.
FLUX_STOP_SETTLE_SECONDS="${FLUX_STOP_SETTLE_SECONDS:-3}"
FLUX_CHECKPOINT_MINUTES="${FLUX_CHECKPOINT_MINUTES:-5}"
FLUX_BACKUP_HOURS="${FLUX_BACKUP_HOURS:-6}"
export FLUX_BACKUP_KEEP="${FLUX_BACKUP_KEEP:-10}"
FLUX_UPDATE_CHECK_MINUTES="${FLUX_UPDATE_CHECK_MINUTES:-30}"
# Workshop mod updates: how often Steam is asked whether a listed mod has a newer version (0 = off).
FLUX_MOD_CHECK_MINUTES="${FLUX_MOD_CHECK_MINUTES:-30}"
# Deadlines for SteamCMD: a node that cannot reach Steam must not hang a start or the watcher.
FLUX_STEAMCMD_TIMEOUT="${FLUX_STEAMCMD_TIMEOUT:-1800}"
FLUX_STEAMCMD_UPDATE_TIMEOUT="${FLUX_STEAMCMD_UPDATE_TIMEOUT:-600}"
FLUX_STEAMCMD_QUERY_TIMEOUT="${FLUX_STEAMCMD_QUERY_TIMEOUT:-180}"
# Warnings in chat before a planned restart (a game update or the daily one), in minutes.
FLUX_RESTART_WARN_MINUTES="${FLUX_RESTART_WARN_MINUTES:-15 5 1}"
FLUX_STOP_SIGNAL="${FLUX_STOP_SIGNAL:-INT}"

s="${FLUX_SERVER_DIR}"
d="${FLUX_DATA_DIR}"
conan() { python3 /opt/flux/fluxconan.py "$@"; }

rm -f "${FLUX_RESTART_MARKER}"
mkdir -p "${s}" "${d}" "${FLUX_SAVED_DIR}" "${FLUX_STATE_DIR}" "${FLUX_STATE_DIR}/import" "${FLUX_GAME_LOG_DIR}" \
  "${FLUX_LOCAL_DIR}/crashes" "${FLUX_LOCAL_DIR}/extracted-mods"
# An older image kept flux.log on the synced data volume: move it here, once.
flux_log_migrate "${FLUX_STATE_DIR}/flux.log"
flux_banner "Conan Exiles"

ports_ok=1
port="$(flux_valid_port "${CONAN_PORT:-7777}")" || ports_ok=0
qport="$(flux_valid_port "${CONAN_QUERY_PORT:-27015}")" || ports_ok=0
rport="$(flux_valid_port "${CONAN_RCON_PORT:-25575}")" || ports_ok=0
if [ "${ports_ok}" = "0" ]; then
  flux_log "ERROR CONAN_PORT / CONAN_QUERY_PORT / CONAN_RCON_PORT must be ports from 1024 to 65534; refusing to start"
  conan state crashed "A port setting is not a usable port"
  exit 42
fi
if clash="$(flux_ports_clash "${port}" "${qport}" "${rport}")"; then
  flux_log "ERROR ${clash}; refusing to start"
  conan state crashed "The ports clash: ${clash}"
  exit 42
fi
if ! restart_at="$(flux_restart_time "${CONAN_RESTART_TIME:-}")"; then
  flux_log "WARN CONAN_RESTART_TIME='${CONAN_RESTART_TIME}' is not HH:MM; no daily restart"
  restart_at=""
fi
flux_log "flux-entrypoint starting (image ${FLUX_IMAGE_VERSION:-dev}): game UDP ${port} and $((port + 1)), query UDP ${qport}, RCON TCP ${rport}"

game_pid=""
tail_pid=""
watch_pid=""
ckpt_pid=""
backup_pid=""
cap_pid=""
terminating=0
generation=0
restart_history=()

# THE STOP. Docker gives ten seconds on Flux; the game's own shutdown takes one to four minutes
# (measured: 125 s for the whole map) and writes NOTHING to the world in that time: the world is a
# WAL-mode SQLite database the server commits to every few seconds as the game goes (measured), and
# its teardown is only unloading levels. So the stop is: a checkpoint through RCON (the world file
# is whole before anything else), SIGINT (drops the players, who are saved as they leave), a few
# seconds for those writes to land, SIGKILL, and a checkpoint of the dead database. Everything
# committed survives (proved with docker stop at the default ten seconds and with kill -9); the
# only loss is what the server had not yet written, a few seconds of play.
stop_server() {
  local pid i
  pid="$(flux_game_pid)"
  pid="${pid:-${game_pid}}"
  [ -z "${pid}" ] && return 0
  timeout 3 python3 /opt/flux/fluxconan.py rcon "sql pragma wal_checkpoint(TRUNCATE)" >/dev/null 2>&1
  kill "-${FLUX_STOP_SIGNAL}" "${pid}" 2>/dev/null
  for ((i = 0; i < FLUX_STOP_SETTLE_SECONDS * 2; i++)); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "${pid}" 2>/dev/null; then
    pkill -KILL -x "${FLUX_GAME_COMM}" 2>/dev/null
    kill -KILL "${pid}" 2>/dev/null
    flux_log "the server was ended ${FLUX_STOP_SETTLE_SECONDS}s after the stop signal (its own teardown takes minutes and writes nothing)"
  fi
  # wait: the game runs as a background job of this shell, reaped here or by the main loop
  conan checkpoint 2>&1 | while IFS= read -r line; do flux_log "${line#\# }"; done
}

# shellcheck disable=SC2329  # invoked by the trap below
term_handler() {
  terminating=1
  flux_log "stop requested: shutting the server down, no restart will follow"
  stop_server
}
trap term_handler TERM INT

# One SteamCMD run with a deadline, in the background so a stop is not held up by it (bash runs
# a trap only between foreground commands). $1 = seconds, the rest = SteamCMD's arguments.
# Returns 124 on the deadline, 143 when the container is stopping.
steamcmd_run() {
  local limit="$1" pid rc
  shift
  timeout -k 10 "${limit}" steamcmd "$@" >/tmp/steamcmd.log 2>&1 &
  pid=$!
  wait "${pid}"
  rc=$?
  if [ "${terminating}" = "1" ]; then
    kill "${pid}" 2>/dev/null
    pkill -f 'steamcmd' 2>/dev/null
    return 143
  fi
  return "${rc}"
}

# Every SteamCMD run has a deadline (FLUX_STEAMCMD_TIMEOUT, 30 min, for a first install;
# FLUX_STEAMCMD_UPDATE_TIMEOUT, 10 min, over an install): a node that cannot reach Steam's CDN
# must not stay "updating" for ever.
update_server() {
  local attempt validate limit rc why
  if flux_truthy "${SKIP_UPDATE:-}" && [ -x "${s}/ConanSandbox/Binaries/Linux/${FLUX_GAME_PROCESS}" ]; then
    flux_log "SKIP_UPDATE is set: not updating the server files"
    return 0
  fi
  conan state updating "Downloading the server from Steam"
  flux_log "updating the server from Steam (app ${FLUX_STEAM_APP})"
  # No `validate` on the first attempt: it re-hashes the whole install on every start. A broken
  # install fails the first attempt, and every retry validates.
  validate=""
  for attempt in 1 2 3 4 5; do
    limit="${FLUX_STEAMCMD_TIMEOUT}"
    [ -x "${s}/ConanSandbox/Binaries/Linux/${FLUX_GAME_PROCESS}" ] && limit="${FLUX_STEAMCMD_UPDATE_TIMEOUT}"
    # app_info_update + a second app_update: SteamCMD answers "Missing configuration" to a first
    # app_update now and then.
    # shellcheck disable=SC2086  # validate is "" or "validate"
    steamcmd_run "${limit}" +@sSteamCmdForcePlatformType linux +force_install_dir "${s}" +login anonymous +app_info_update 1 \
      +app_update "${FLUX_STEAM_APP}" +app_update "${FLUX_STEAM_APP}" ${validate} +quit
    rc=$?
    [ "${terminating}" = "1" ] && return 1
    if [ "${rc}" = "0" ]; then
      flux_log "server build $(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      return 0
    fi
    validate="validate"
    why="$(grep -aE 'ERROR|Error|error' /tmp/steamcmd.log | tail -2 | tr '\n' ' ')"
    [ "${rc}" = "124" ] && why="no answer within ${limit} s (Steam unreachable from this node?) ${why}"
    flux_log "WARN steamcmd failed (attempt ${attempt}/5): ${why}retrying in 5s with validate"
    sleep 5 &
    wait $!
    [ "${terminating}" = "1" ] && return 1
  done
  if [ -x "${s}/ConanSandbox/Binaries/Linux/${FLUX_GAME_PROCESS}" ]; then
    flux_log "WARN could not update from Steam; starting the build already installed"
    return 0
  fi
  flux_log "ERROR could not install the server from Steam"
  return 1
}

# The install's ConanSandbox/Saved is the data volume's Saved/ (the world database and the ini
# files, synced). Inside it, Logs, Crashes and ExtractedMods are links back to the LOCAL volume:
# they churn or can be made again, and Syncthing would copy every line.
link_saved() {
  local saved="${s}/ConanSandbox/Saved" name target
  mkdir -p "${s}/ConanSandbox"
  if [ -L "${saved}" ]; then
    [ "$(readlink "${saved}")" = "${FLUX_SAVED_DIR}" ] || { rm -f "${saved}"; ln -s "${FLUX_SAVED_DIR}" "${saved}"; }
  else
    if [ -d "${saved}" ]; then
      # A Saved/ the game made in the install (an older image, a hand install): moved across once,
      # never over what the data volume already holds.
      cp -an "${saved}/." "${FLUX_SAVED_DIR}/" 2>/dev/null
      rm -rf "${saved}"
      flux_log "moved the install's Saved/ onto the data volume"
    fi
    ln -s "${FLUX_SAVED_DIR}" "${saved}"
  fi
  for name in Logs:logs-game Crashes:crashes ExtractedMods:extracted-mods; do
    target="${FLUX_LOCAL_DIR}/${name#*:}"
    mkdir -p "${target}"
    if [ ! -L "${FLUX_SAVED_DIR}/${name%%:*}" ]; then
      rm -rf "${FLUX_SAVED_DIR:?}/${name%%:*}"
      ln -s "${target}" "${FLUX_SAVED_DIR}/${name%%:*}"
    fi
  done
  # The server writes as FLUX_GAME_UID; what SteamCMD and we wrote as root must be its.
  chown -R "${FLUX_GAME_UID}:${FLUX_GAME_UID}" "${FLUX_SAVED_DIR}" "${FLUX_LOCAL_DIR}" 2>/dev/null
  chown -h "${FLUX_GAME_UID}:${FLUX_GAME_UID}" "${saved}" 2>/dev/null
}

# A backup (fluxconan.py backup: what goes in, what is skipped and what is kept). $2 = force.
backup_world() {
  local line
  while IFS= read -r line; do
    flux_log "${line#\# }"
  done < <(conan backup "$1" ${2:+"$2"} 2>&1)
}

# shellcheck disable=SC2329  # run in the background below
backupper() {
  [ "${FLUX_BACKUP_HOURS}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_BACKUP_HOURS * 3600))
    backup_world "every ${FLUX_BACKUP_HOURS}h"
  done
}

# Asks the supervisor to restart the server: the marker says why; wait_for_generation stops it.
request_restart() {
  [ -f "${FLUX_RESTART_MARKER}" ] && return 0
  printf '%s\nnotbefore=0\n' "$1" >"${FLUX_RESTART_MARKER}"
  flux_log "$1: restarting the server"
}

# The players currently on, from the last LogServerStats line (the watcher keeps it). "" unknown.
player_count() {
  cat /tmp/flux-players 2>/dev/null
}

# Warns the players in chat at each of FLUX_RESTART_WARN_MINUTES before a planned restart, then
# returns. An empty server is restarted at once.
warn_and_wait() {
  local what="$1" prev=0 m
  local -a marks
  read -r -a marks <<<"${FLUX_RESTART_WARN_MINUTES}"
  [ "$(player_count)" = "0" ] && return 0
  for m in "${marks[@]}"; do
    [[ "${m}" =~ ^[0-9]+$ ]] || continue
    if [ "${prev}" -gt "${m}" ]; then
      sleep $(((prev - m) * 60))
      [ "$(player_count)" = "0" ] && return 0
    fi
    conan rcon "broadcast $(flux_restart_warning "${m}")" >/dev/null 2>&1 \
      && flux_log "${what}: players warned (${m} min)"
    prev="${m}"
  done
  [ "${prev}" -gt 0 ] && sleep $((prev * 60))
  return 0
}

# shellcheck disable=SC2329  # run in the background below
# The world file whole every FLUX_CHECKPOINT_MINUTES (the game's WAL is checkpointed and truncated
# through RCON), so what Syncthing copies to another node is a consistent database, not half of a
# WAL pair. A loop of its own: the watcher's waits (Steam, the warnings before a restart) never
# hold it up.
checkpointer() {
  [ "${FLUX_CHECKPOINT_MINUTES}" -gt 0 ] 2>/dev/null || exit 0
  while true; do
    sleep $((FLUX_CHECKPOINT_MINUTES * 60))
    timeout 5 python3 /opt/flux/fluxconan.py rcon "sql pragma wal_checkpoint(TRUNCATE)" >/dev/null 2>&1
  done
}

# shellcheck disable=SC2329  # run in the background below
# Marks the server running once the Steam query has started, keeps the player count from the
# per-minute status line, follows Steam for a newer build and newer Workshop mods, and keeps the
# daily restart.
watcher() {
  local line build public last_check last_mods now next_restart="" n mods
  last_check="$(date -u +%s)"
  last_mods="${last_check}"
  while IFS= read -r line; do
    if [[ "${line}" == *"Started SourceServerQueries"* ]]; then
      conan world-seen
      conan state running
      printf '0' >/tmp/flux-players
      flux_log "the server is up (generation ${generation})"
      break
    fi
  done < <(tail -n +1 -F "$(flux_game_log)" 2>/dev/null)
  if [ -n "${restart_at}" ]; then
    next_restart="$(flux_next_daily "$(date -u +%s)" "${restart_at}")"
    conan note nextRestart "${next_restart}"
  else
    conan note nextRestart
  fi
  conan note updateWaiting
  conan note modUpdateWaiting
  # The per-minute status line carries the player count.
  (tail -n 0 -F "$(flux_game_log)" 2>/dev/null | while IFS= read -r line; do
    n="$(flux_players_from_stats "${line}")"
    [ -n "${n}" ] && printf '%s' "${n}" >/tmp/flux-players
  done) &
  while true; do
    sleep 60
    now="$(date -u +%s)"
    if [ "${FLUX_UPDATE_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_check)) -ge $((FLUX_UPDATE_CHECK_MINUTES * 60)) ]; then
      last_check="${now}"
      build="$(flux_installed_build "${s}/steamapps/appmanifest_${FLUX_STEAM_APP}.acf")"
      # A deadline: a SteamCMD that never answers would end the update checks and the daily
      # restart for the whole generation.
      public="$(timeout -k 10 "${FLUX_STEAMCMD_QUERY_TIMEOUT}" steamcmd +login anonymous +app_info_update 1 +app_info_print "${FLUX_STEAM_APP}" +quit 2>/dev/null | flux_public_build)"
      if [ -n "${public}" ] && [ -n "${build}" ] && [ "${public}" != "${build}" ] && ! conan update-skip "${public}"; then
        flux_log "a new server build is on Steam (${build} -> ${public}): restarting onto it"
        conan note updateWaiting "${public}"
        warn_and_wait "game update"
        conan update-target "${public}"
        request_restart "planned: game update ${build} -> ${public}"
        exit 0
      fi
    fi
    # A Workshop mod with a newer version on Steam: the players' clients already have it and the
    # server refuses them until it restarts and downloads it (mods-sync).
    if [ "${FLUX_MOD_CHECK_MINUTES}" -gt 0 ] 2>/dev/null && [ $((now - last_mods)) -ge $((FLUX_MOD_CHECK_MINUTES * 60)) ]; then
      last_mods="${now}"
      if mods="$(timeout -k 5 60 python3 /opt/flux/fluxconan.py mods-update-check 2>/dev/null)" && [ -n "${mods}" ]; then
        flux_log "a newer version of Workshop mod(s) ${mods} is on Steam: restarting onto it"
        warn_and_wait "mod update"
        request_restart "planned: mod update (${mods})"
        exit 0
      fi
    fi
    if [ -n "${next_restart}" ] && [ "${now}" -ge "${next_restart}" ]; then
      warn_and_wait "daily restart"
      request_restart "planned: the daily restart (${restart_at} ${TZ:-UTC})"
      exit 0
    fi
  done
}

# shellcheck disable=SC2329  # run in the background below
# The game log, capped at FLUX_GAME_LOG_MAX_BYTES: its last 5 MB go to a rotated file and the live
# one is emptied in place (the writer appends).
log_capper() {
  local current size
  current="$(flux_game_log)"
  while true; do
    sleep 60
    size="$(stat -c %s "${current}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt "${FLUX_GAME_LOG_MAX_BYTES}" ] 2>/dev/null; then
      tail -c 5242880 "${current}" >"${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log" 2>/dev/null
      : >"${current}"
      flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
      flux_log "the game log reached $((size / 1048576)) MB: rotated"
    fi
  done
}

# Lines the game writes many times a second at start (missing AI table rows, NPCs in odd
# movement modes): kept in the log file, left out of the container's output (the panel's Console).
FLUX_LOG_NOISE='UDataTable::FindRow|is in an unsafe movement move|SpawnNPCFromWeightedTable|Removing placed module that did not manage|TickSpawnBase - Failed to spawn module|ThrallActorClass was not loaded|LogBlueprintUserMessages: \[BP_OuterDarkArenaController'

# Before every start: a restore / import / new world the panel asked for, then the world guard
# (fluxconan.py world-guard): never start the game on a missing world this server had, which on a
# half-synced volume would make a new world and sync it over the real one. A restore from a backup
# is said in flux.log and the state; while it waits (for the sync, or with no backup for ever) the
# state is `updating` with the reason, checked every 30 s (the panel may ask for a restore or a new
# world meanwhile). Returns 1 when stopping.
guard_world() {
  local line out rc said=""
  while true; do
    while IFS= read -r line; do
      flux_log "restore: ${line#\# }"
      case "${line}" in
        *"NOT done"* | *"failed ("*) world_note="${line#\# WARN }" ;;
      esac
    done < <(conan do-restore 2>&1)
    out="$(conan world-guard 2>&1)"
    rc=$?
    while IFS= read -r line; do
      [ -n "${line}" ] && [[ "${line}" == "# "* ]] && flux_log "world: ${line#\# }"
    done <<<"${out}"
    if [ "${rc}" = "0" ]; then
      line="$(grep -o 'restored the newest backup, [^ ,]*' <<<"${out}" | head -1)"
      [ -n "${line}" ] && world_note="the world was missing on this node: backup ${line#restored the newest backup, } put back"
      return 0
    fi
    line="$(grep -v '^# ' <<<"${out}" | tail -1)"
    if [ "${said}" != "${line}" ]; then
      flux_log "WARN ${line}"
      said="${line}"
    fi
    conan state updating "${line}"
    sleep 30 &
    wait $!
    [ "${terminating}" = "1" ] && return 1
  done
}

start_generation() {
  local line args=() current applied
  generation=$((generation + 1))
  rm -f "${FLUX_RESTART_MARKER}" /tmp/flux-players
  world_note=""

  update_server || return 1
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(conan update-check 2>&1)
  [ "${terminating}" = "1" ] && return 2
  link_saved
  # A restore, a new world or an uploaded world the panel asked for, and the world guard, before
  # anything reads them: the mods list is the restored one when mods-sync runs.
  guard_world || return 2
  conan state starting "Downloading mods"
  while IFS= read -r line; do flux_log "${line#\# }"; done < <(conan mods-sync 2>&1)
  [ "${terminating}" = "1" ] && return 2
  backup_world "start"

  # apply's stdout is the arguments (and "# " notes). A failed apply starts the server on the
  # files as they are and the defaults, never on an error message as arguments.
  if applied="$(conan apply 2>/tmp/flux-apply.err)"; then
    while IFS= read -r line; do
      case "${line}" in
        "# "*) flux_log "config: ${line#\# }" ;;
        "") ;;
        *) args+=("${line}") ;;
      esac
    done <<<"${applied}"
  else
    flux_log "WARN applying the settings failed: $(tail -3 /tmp/flux-apply.err | tr '\n' ' ')"
    args=("-Port=${port}" "-QueryPort=${qport}")
  fi
  chown -R "${FLUX_GAME_UID}:${FLUX_GAME_UID}" "${FLUX_SAVED_DIR}" 2>/dev/null

  # steamclient.so where the Steam API looks for it, for the unprivileged user.
  mkdir -p /home/conan/.steam/sdk64
  cp -f "${s}/linux64/steamclient.so" /home/conan/.steam/sdk64/ 2>/dev/null
  chown -R "${FLUX_GAME_UID}:${FLUX_GAME_UID}" /home/conan

  current="$(flux_game_log)"
  if [ -s "${current}" ]; then
    mv "${current}" "${FLUX_GAME_LOG_DIR}/$(date -u +%Y%m%d-%H%M%S)-server.log"
  fi
  : >"${current}"
  chown "${FLUX_GAME_UID}:${FLUX_GAME_UID}" "${current}"
  flux_prune "${FLUX_GAME_LOG_DIR}" '*-server.log' "${FLUX_GAME_LOG_KEEP}"
  [ "${terminating}" = "1" ] && return 2

  conan state starting "Loading the world${world_note:+ (${world_note})}"
  flux_banner "Conan Exiles"
  # flux_log hides the join password (flux_log_filter).
  flux_log "starting the server (generation ${generation}): ${args[*]}"

  # The game's log onto the container's output, without the start-up noise. flux_log_filter: no
  # NUL bytes, and the join password on the game's "Command Line:" line hidden.
  (tail -n 0 -F "${current}" 2>/dev/null | grep --line-buffered -avE "${FLUX_LOG_NOISE}" | flux_log_filter) &
  tail_pid=$!

  (
    cd "${s}" || exit 1
    exec setpriv --reuid="${FLUX_GAME_UID}" --regid="${FLUX_GAME_UID}" --clear-groups \
      env HOME=/home/conan "./ConanSandbox/Binaries/Linux/${FLUX_GAME_PROCESS}" ConanSandbox -log "${args[@]}" \
      </dev/null >>"${current}" 2>&1
  ) &
  game_pid=$!
  # The hub waits for this to change to know a restart is over (never the clocks).
  printf '%s %s\n' "${generation}" "$(date -u +%s)" >/tmp/flux-generation

  watcher &
  watch_pid=$!
  checkpointer &
  ckpt_pid=$!
  backupper &
  backup_pid=$!
  log_capper &
  cap_pid=$!
  return 0
}

sweep_generation() {
  local pid
  for pid in "${tail_pid}" "${watch_pid}" "${ckpt_pid}" "${backup_pid}" "${cap_pid}"; do
    [ -n "${pid}" ] && pkill -P "${pid}" 2>/dev/null
    [ -n "${pid}" ] && kill "${pid}" 2>/dev/null
  done
  tail_pid="" watch_pid="" ckpt_pid="" backup_pid="" cap_pid=""
  pkill -f "tail -n [0+1]* -F $(flux_game_log)" 2>/dev/null
  pkill -KILL -x "${FLUX_GAME_COMM}" 2>/dev/null
  game_pid=""
  rm -f /tmp/flux-players
}

# Waits for the game to end. A requested stop or restart that is not honoured within
# FLUX_STOP_GRACE ends it by force; the grace runs from when the request was first seen.
wait_for_generation() {
  local asked_at=0 now signalled=0
  while kill -0 "${game_pid}" 2>/dev/null; do
    sleep 1 &
    wait $!
    if [ "${signalled}" = "0" ] && [ "${terminating}" = "0" ] && [ -f "${FLUX_RESTART_MARKER}" ] \
      && [ "$(date -u +%s)" -ge "$(flux_marker_not_before "${FLUX_RESTART_MARKER}")" ]; then
      signalled=1
      stop_server
    fi
    if [ "${terminating}" = "1" ] || [ "${signalled}" = "1" ]; then
      now="$(date -u +%s)"
      [ "${asked_at}" = "0" ] && asked_at="${now}"
      if [ $((now - asked_at)) -ge "${FLUX_STOP_GRACE}" ]; then
        flux_log "WARN the server was asked to stop ${FLUX_STOP_GRACE}s ago and has not; ending it"
        pkill -KILL -x "${FLUX_GAME_COMM}" 2>/dev/null
        kill -KILL "${game_pid}" 2>/dev/null
        break
      fi
    else
      asked_at=0
    fi
  done
  wait "${game_pid}" 2>/dev/null
}

# The game refused a mod and exited (about 3.5 s after launch, every time): restarting cannot fix
# it, so nothing restarts and the restart budget is left alone. The state tells the hub which mod
# to take off the list; the next generation starts once the list no longer has it, or on the
# panel's restart (the author may have updated it: every start downloads the mods again).
wait_for_mod_fix() {
  local line first="" ids=""
  while IFS= read -r line; do
    flux_log "ERROR ${line#\# }"
    [ -z "${first}" ] && first="${line#\# mod }"
  done </tmp/flux-modfail.txt
  ids="$(grep -o 'mod [0-9]*' /tmp/flux-modfail.txt | awk '{print $2}' | tr '\n' ' ')"
  conan state needs-mod-fix "The game refused a mod it cannot load: ${first%% was refused*}. Remove mod(s) ${ids}from the Mods list, or wait for the mod's author to update it, then restart."
  flux_log "not restarting: the same mod would be refused again. Remove ${ids}from the Mods list (hub: Mods) or CONAN_MODS; the server starts when it is gone."
  while [ "${terminating}" = "0" ] && [ ! -f "${FLUX_RESTART_MARKER}" ] && ! conan mods-fixed; do
    sleep 5 &
    wait $!
  done
  rm -f "${FLUX_RESTART_MARKER}"
}

while true; do
  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request before the server started"
    conan state stopped
    exit 0
  fi
  start_generation
  started=$?
  if [ "${started}" = "2" ]; then
    flux_log "stopped on request before the server started"
    conan state stopped
    exit 0
  elif [ "${started}" != "0" ]; then
    flux_log "ERROR the server could not be prepared; ending the container (42)"
    conan state crashed "The server could not be installed or started"
    exit 42
  fi
  wait_for_generation
  rc=$?

  reason=""
  if [ -f "${FLUX_RESTART_MARKER}" ]; then
    reason="$(head -1 "${FLUX_RESTART_MARKER}" 2>/dev/null)"
  fi
  sweep_generation
  rm -f "${FLUX_RESTART_MARKER}"

  if [ "${terminating}" = "1" ]; then
    flux_log "stopped on request (server exited ${rc})"
    conan state stopped
    exit 0
  fi

  if [ -z "${reason}" ] && conan mods-failed >/tmp/flux-modfail.txt 2>/dev/null; then
    wait_for_mod_fix
    continue
  fi

  [ -z "${reason}" ] && reason="the server ended on its own (exit ${rc})"

  if flux_restart_counts "${reason}"; then
    now="$(date -u +%s)"
    read -r -a restart_history <<<"$(flux_restarts_in_window "${now}" "${FLUX_RESTART_WINDOW}" "${restart_history[@]}")"
    restart_history+=("${now}")
    if [ "${#restart_history[@]}" -gt "${FLUX_RESTART_MAX_ATTEMPTS}" ]; then
      flux_log "${reason}: ${#restart_history[@]} restarts within ${FLUX_RESTART_WINDOW}s, so restarting it here is not working. Ending the container so the platform can rebuild or move it (42)."
      conan state crashed "The server keeps stopping: ${reason}"
      exit 42
    fi
  fi

  conan state restarting "${reason}"
  flux_log "${reason}: restarting the server in place in ${FLUX_RESTART_BACKOFF}s"
  sleep "${FLUX_RESTART_BACKOFF}" &
  wait $!
done
