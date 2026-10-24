#!/bin/bash
# Shared helpers for the Conan Exiles Enhanced image.
#
# SOURCING THIS FILE MUST STAY SIDE-EFFECT FREE: tests/test-flux.sh sources it directly and
# calls the functions with made-up inputs. Everything that decides something takes its inputs
# as arguments, so the decision can be tested without a server, Steam or Docker.

# ---------------------------------------------------------------------------------------------
# Paths. The install (SteamCMD's, ~4.3 GB, disposable, local to the node, with the Workshop
# downloads and the game's logs) and the data (synced): Saved/ (the world database game_0.db and
# the server's ini files) and our flux/ (log, settings, mods list, backups). The install's
# ConanSandbox/Saved is a link to the data's Saved/.
# ---------------------------------------------------------------------------------------------
FLUX_SERVER_DIR="${FLUX_SERVER_DIR:-/mnt/conan/server}"
FLUX_DATA_DIR="${FLUX_DATA_DIR:-/mnt/conan/data}"
FLUX_SAVED_DIR="${FLUX_SAVED_DIR:-${FLUX_DATA_DIR}/Saved}"
FLUX_STATE_DIR="${FLUX_STATE_DIR:-${FLUX_DATA_DIR}/flux}"
# flux.log is on the INSTALL volume (local, never synced): it is written on every line, and on the
# synced data volume that would be constant Syncthing traffic. One rotated copy (flux.log.1).
FLUX_LOG_DIR="${FLUX_LOG_DIR:-${FLUX_SERVER_DIR}/flux-logs}"
FLUX_LOG="${FLUX_LOG-${FLUX_LOG_DIR}/flux.log}"
FLUX_LOG_MAX_BYTES="${FLUX_LOG_MAX_BYTES:-5242880}"
# What churns or can be downloaded again stays LOCAL (never synced): the game's logs, its crash
# reports and the mods it unpacks. Saved/Logs, Saved/Crashes and Saved/ExtractedMods are links here.
FLUX_LOCAL_DIR="${FLUX_LOCAL_DIR:-${FLUX_SERVER_DIR}/flux-local}"
FLUX_GAME_LOG_DIR="${FLUX_GAME_LOG_DIR:-${FLUX_LOCAL_DIR}/logs}"
FLUX_GAME_LOG_KEEP="${FLUX_GAME_LOG_KEEP:-5}"
FLUX_GAME_LOG_MAX_BYTES="${FLUX_GAME_LOG_MAX_BYTES:-20000000}"
FLUX_GAME_PROCESS="${FLUX_GAME_PROCESS:-ConanSandboxServer-Linux-Shipping}"
# The kernel's name for it (the executable's first 15 characters). Matched EXACTLY (pgrep -x):
# `pgrep -f` on the long name also matches any shell whose command line mentions it.
FLUX_GAME_COMM="${FLUX_GAME_COMM:-${FLUX_GAME_PROCESS:0:15}}"
FLUX_STEAM_APP="${FLUX_STEAM_APP:-443030}"
FLUX_RESTART_MARKER="${FLUX_RESTART_MARKER:-/tmp/flux-restart-requested}"
# The Unreal server refuses to run as root ("Refusing to run with the root privileges", measured):
# the supervisor (root, for SteamCMD and the volumes) starts it as this user.
FLUX_GAME_UID="${FLUX_GAME_UID:-1000}"

# One line, to the container's output and (when FLUX_LOG is set) to flux.log, rotated at
# FLUX_LOG_MAX_BYTES (the old file becomes flux.log.1).
flux_log_raw() {
  local line="$1"
  # A password option on a line (the launch line, an error quoting it) is never logged.
  if [[ "${line,,}" == *password=* ]]; then
    line="$(printf '%s\n' "${line}" | flux_log_filter)"
  fi
  printf '%s\n' "${line}"
  if [ -n "${FLUX_LOG}" ] && mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null; then
    printf '%s\n' "${line}" >>"${FLUX_LOG}" 2>/dev/null || return 0
    flux_rotate_log "${FLUX_LOG}" "${FLUX_LOG_MAX_BYTES}"
  fi
  return 0
}

# stdin -> stdout, line by line (unbuffered): what the game's log may show. NUL bytes are dropped
# (a log emptied under the game reads back as a run of them), and the value of -ServerPassword=
# and -AdminPassword= (the game prints its whole command line at start) becomes <hidden>.
flux_log_filter() {
  sed -u -E -e 's/\x00//g' -e 's/(-(server|admin)password=)("[^"]*"|[^ ]*)/\1<hidden>/Ig'
}

flux_log() {
  flux_log_raw "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [flux] $*"
}

# Moves $1 to $1.1 (replacing the previous one) once it is larger than $2 bytes.
flux_rotate_log() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
  if [ "${size}" -gt "$2" ] 2>/dev/null; then
    mv -f "$1" "$1.1" 2>/dev/null
  fi
  return 0
}

# The start-up banner, through the normal log path (docker logs, the panel's log). ASCII only.
# $1 = the game's name.
flux_banner() {
  local rule='====================================================================='
  flux_log_raw "${rule}"
  flux_log_raw " $1 server image by FluxCloud - https://runonflux.com"
  flux_log_raw " Host this and 30+ other games in one click: https://runonflux.com/games"
  flux_log_raw "${rule}"
}

# Once per start: a flux.log an older image left on the synced data volume ($@) is appended to
# the new one and deleted there, so Syncthing stops carrying it.
flux_log_migrate() {
  local old
  [ -n "${FLUX_LOG}" ] || return 0
  for old in "$@"; do
    [ -f "${old}" ] && [ "${old}" != "${FLUX_LOG}" ] || continue
    mkdir -p "$(dirname "${FLUX_LOG}")" 2>/dev/null
    if [ -s "${old}" ]; then
      cat "${old}" >>"${FLUX_LOG}" 2>/dev/null || continue
    fi
    rm -f "${old}" "${old}.tmp"
  done
  return 0
}

flux_truthy() {
  case "${1,,}" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a port as given. Prints it, or returns 1 for a value that is not a usable port.
flux_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] || return 1
  value=$((10#${value}))
  [ "${value}" -ge 1024 ] && [ "${value}" -le 65534 ] || return 1
  printf '%s' "${value}"
}

# $1 = game port, $2 = query port, $3 = RCON port. The game also binds the game port PLUS ONE
# (Unreal's raw UDP port, measured: 7777 and 7778), so none of the others may be that one.
# Returns 1 with the reason on stdout when they clash.
flux_ports_clash() {
  local game="$1" query="$2" rcon="$3"
  if [ "${query}" = "${game}" ] || [ "${query}" = "$((game + 1))" ]; then
    printf 'the query port %s is the game port or the one after it' "${query}"
    return 0
  fi
  if [ "${rcon}" = "${game}" ] || [ "${rcon}" = "$((game + 1))" ] || [ "${rcon}" = "${query}" ]; then
    printf 'the RCON port %s is already taken by the game or the query' "${rcon}"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------------------------
# The supervisor's restart budget: a server that keeps dying is not fixed by restarting it in
# the same container forever.
# ---------------------------------------------------------------------------------------------

# $1 = now (epoch seconds), $2 = window in seconds, $3.. = the times of earlier restarts.
# Prints the restarts that are still inside the window, space separated.
flux_restarts_in_window() {
  local now="$1" window="$2" t kept=()
  shift 2
  for t in "$@"; do
    [ "${t}" -gt $((now - window)) ] && kept+=("${t}")
  done
  printf '%s' "${kept[*]}"
}

# $1 = why the last generation ended. A restart the supervisor planned (a game update, the
# daily restart, one the panel asked for) is the plan working, not a crash.
flux_restart_counts() {
  case "$1" in
    planned* | requested*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# The daily restart. Players are warned over RCON first (broadcast), at FLUX_RESTART_WARN_MINUTES.
# ---------------------------------------------------------------------------------------------

# $1 = CONAN_RESTART_TIME as given. Prints HH:MM (in TZ), or "" when off. Returns 1 for a value
# that is not a time.
flux_restart_time() {
  local value="${1-}" h m
  case "${value,,}" in
    "" | off | none | false | 0) printf ''; return 0 ;;
  esac
  [[ "${value}" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
  [ "${h}" -le 23 ] && [ "${m}" -le 59 ] || return 1
  printf '%02d:%02d' "${h}" "${m}"
}

# $1 = now (epoch seconds), $2 = HH:MM in the container's time zone (TZ; UTC when unset). Prints
# the epoch of the next time it is $2: today when that is still ahead, tomorrow otherwise. Through
# `date`, so a daylight-saving change is the zone's, not an hour off.
flux_next_daily() {
  local now="$1" at
  at="$(date -d "$(date -d "@${now}" +%F) $2" +%s 2>/dev/null)" || return 1
  if [ "${at}" -le "${now}" ]; then
    at="$(date -d "$(date -d "@$((now + 86400))" +%F) $2" +%s 2>/dev/null)" || return 1
  fi
  printf '%s' "${at}"
}

# $1 = minutes left. The warning players read in chat before a planned restart.
flux_restart_warning() {
  local m="$1"
  if [ "${m}" -le 1 ]; then
    printf 'The server restarts in 1 minute. Find a safe spot: your progress is saved.'
  else
    printf 'The server restarts in %s minutes. Your progress is saved.' "${m}"
  fi
}

# ---------------------------------------------------------------------------------------------
# Rotation of the game logs.
# ---------------------------------------------------------------------------------------------

# $1 = number to keep, then the files NEWEST FIRST. Prints the ones to delete.
flux_files_to_prune() {
  local keep="$1" i=0 f
  shift
  for f in "$@"; do
    i=$((i + 1))
    [ "${i}" -gt "${keep}" ] && printf '%s\n' "${f}"
  done
  return 0
}

# $1 = directory, $2 = glob, $3 = number to keep.
flux_prune() {
  local f files=()
  # shellcheck disable=SC2012,SC2086  # $2 is a glob on purpose; names are ours, no spaces
  mapfile -t files < <(ls -t "$1"/$2 2>/dev/null)
  while IFS= read -r f; do
    [ -n "${f}" ] && rm -f "${f}"
  done < <(flux_files_to_prune "$3" "${files[@]}")
}

# ---------------------------------------------------------------------------------------------
# Steam builds: an outdated server refuses players on the new client, so a new build means a
# restart (onto it). SteamCMD's own "up to date" check is not trusted: the installed buildid
# (appmanifest) is compared with the public branch's (app_info).
# ---------------------------------------------------------------------------------------------

# $1 = an appmanifest_<app>.acf. Prints its buildid.
flux_installed_build() {
  [ -f "$1" ] || return 0
  awk -F'"' '$2 == "buildid" { print $4; exit }' "$1"
}

# stdin = steamcmd +app_info_print output. Prints the public branch's buildid.
flux_public_build() {
  awk '
    /"branches"/ { inb = 1 }
    inb && /"public"/ { inp = 1 }
    inp && /"buildid"/ { gsub(/"/, "", $2); print $2; exit }
  '
}

# The game's log of the current generation (the server's stdout, -log).
flux_game_log() {
  printf '%s' "${FLUX_GAME_LOG:-${FLUX_GAME_LOG_DIR}/current.log}"
}

flux_game_pid() {
  pgrep -x "${FLUX_GAME_COMM}" 2>/dev/null | head -1
}

# $1 = the restart marker. Prints the earliest epoch the server may be stopped for it, 0 when it
# says nothing.
flux_marker_not_before() {
  local value
  value="$(sed -n 's/^notbefore=//p' "$1" 2>/dev/null | head -1)"
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}

# $1 = a line of the game's log. Prints the player count of a "LogServerStats: Status report"
# line (written every minute, measured: "... Players=0 FPS=..."), or nothing.
flux_players_from_stats() {
  [[ "$1" == *"LogServerStats: Status report."* ]] || return 0
  [[ "$1" =~ [[:space:]]Players=([0-9]+)[[:space:]] ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}
