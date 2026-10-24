#!/usr/bin/env python3
"""Every decision about the Conan Exiles Enhanced server's files, and the hub's commands.

    fluxconan.py apply               write Game.ini (RCON, max players), Engine.ini (name, join
                                     password, the regions) and the owned keys of ServerSettings.ini
                                     from the environment; print the launch arguments, one per line
    fluxconan.py mods-sync           download the mods list from the Steam Workshop (SteamCMD,
                                     anonymous) and write ConanSandbox/Mods/modlist.txt in its order
    fluxconan.py state <state> [msg] record what the supervisor is doing (flux/state.json)
    fluxconan.py note <key> [value]  a field of flux/state.json (nextRestart, updateWaiting)
    fluxconan.py mods-failed|mods-fixed  the game refused a mod (exit 0 = yes) / the owner removed it
    fluxconan.py players-seen <n>    the player count of the last LogServerStats line
    fluxconan.py backup <why> [force]
    fluxconan.py do-restore          a pending restore or new world, before a start
    fluxconan.py world-guard         before a start: exit 0 to start, 3 to wait (a world this
                                     server had is missing: see "The world guard" below)
    fluxconan.py world-seen          the server is up: its world is one never to replace silently
    fluxconan.py update-target|update-check|update-skip <build>
    fluxconan.py mods-update-check   exit 0 when Steam has a newer version of a listed mod (the ids
                                     go to state.json modUpdateWaiting), 1 when not or unknown

    flux-conan status                state, players, build, mods, generation (one JSON document)
    flux-conan rcon <command...>     one RCON command on the running server, its answer printed
    flux-conan players               the online players (listplayers), as JSON
    flux-conan bans                  the ban list (listbans) and the bans queued for the next start
    flux-conan ban <steamid64> [why] at once when the player is online, else queued (blacklist.txt
                                     is read only at start); never restarts the server
    flux-conan unban <steamid64>
    flux-conan mods                  the mods list, in load order, with what is downloaded
    flux-conan set-mods '<json>'     ["<workshop id>", ...] in load order; applied on the next start
    flux-conan settings [key...]     ServerSettings.ini values (the PvP schedule's when none named)
    flux-conan set-settings '<json>' {"Key": "value"}: written into ServerSettings.ini before the
                                     next start (the server is restarted now when it runs)
    flux-conan restart               save, stop and start the server again (returns at once)
    flux-conan backups               the backups in flux/backups (name, size, date, why)
    flux-conan backup manual force   a backup now
    flux-conan restore <backup>      put one back on the next start, after a safety backup
    flux-conan new-world             a fresh world on the next start, after a safety backup
    flux-conan import-world <file>   a world uploaded to flux/import (game.db / game_0.db), put in
                                     place on the next start, after a safety backup

THE WORLD IS ONE SQLITE DATABASE, Saved/game_0.db (Enhanced; game.db before it), written by the
server as the game goes (WAL). A backup is taken with SQLite's own backup API, so a copy made
under a running server is consistent. The server's own rotating copies (game_0_backup_N.db) stay
where the game keeps them.

Settings that are not the launch line's (rates, PvP, building, clans) are ServerSettings.ini's, which
the hub's Server Settings tab edits directly; this script only owns AdminPassword and the keys
listed in OWNED_SERVER_SETTINGS, so an edit there survives every start.

An environment variable that is SET to a value is applied on every start; one set EMPTY (the
marketplace writes every declared parameter, blank ones included) is the image's default.
"""

import json
import os
import re
import secrets
import shutil
import socket
import sqlite3
import string
import struct
import subprocess
import sys
import tarfile
import tempfile
import time

SERVER_DIR = os.environ.get("FLUX_SERVER_DIR", "/mnt/conan/server")
DATA_DIR = os.environ.get("FLUX_DATA_DIR", "/mnt/conan/data")
SAVED_DIR = os.environ.get("FLUX_SAVED_DIR", os.path.join(DATA_DIR, "Saved"))
STATE_DIR = os.environ.get("FLUX_STATE_DIR", os.path.join(DATA_DIR, "flux"))
CONFIG_DIR = os.path.join(SAVED_DIR, "Config", "LinuxServer")
STATE_FILE = os.path.join(STATE_DIR, "state.json")
MODS_FILE = os.path.join(STATE_DIR, "mods.json")
RCON_FILE = os.path.join(STATE_DIR, "rcon-password")
BACKUP_DIR = os.environ.get("FLUX_BACKUP_DIR", os.path.join(STATE_DIR, "backups"))
BACKUP_INDEX = os.path.join(BACKUP_DIR, "index.json")
RESTORE_FILE = os.path.join(STATE_DIR, "restore-pending.json")
UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "update-target.json")
UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "update-failed.json")
UPDATE_FAILED_SKIP = 6 * 3600
MOD_UPDATE_TARGET_FILE = os.path.join(STATE_DIR, "mods-update-target.json")
MOD_UPDATE_FAILED_FILE = os.path.join(STATE_DIR, "mods-update-failed.json")
MODS_DIR = os.path.join(SERVER_DIR, "ConanSandbox", "Mods")
WORKSHOP_APP = "440900"
WORKSHOP_DIR = os.path.join(SERVER_DIR, "steamapps", "workshop", "content", WORKSHOP_APP)
# SteamCMD's record of the Workshop items it installed (timeupdated per item).
WORKSHOP_ACF = os.path.join(SERVER_DIR, "steamapps", "workshop", f"appworkshop_{WORKSHOP_APP}.acf")
WORKSHOP_API = os.environ.get("FLUX_WORKSHOP_API",
                              "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")
# What churns or can be made again, LOCAL to the node (never synced): the game's logs, and the
# staging folders of a backup or a restore (a world-sized file Syncthing must not carry).
LOCAL_DIR = os.environ.get("FLUX_LOCAL_DIR", os.path.join(SERVER_DIR, "flux-local"))
LOCAL_TMP = os.path.join(LOCAL_DIR, "tmp")
GAME_LOG = os.environ.get("FLUX_GAME_LOG", os.path.join(LOCAL_DIR, "logs", "current.log"))
ENGINE_LOG = os.environ.get("FLUX_ENGINE_LOG", os.path.join(SAVED_DIR, "Logs", "ConanSandbox.log"))
RESTART_MARKER = os.environ.get("FLUX_RESTART_MARKER", "/tmp/flux-restart-requested")
GENERATION_FILE = os.environ.get("FLUX_GENERATION_FILE", "/tmp/flux-generation")
PLAYERS_FILE = os.environ.get("FLUX_PLAYERS_FILE", "/tmp/flux-players")
BACKUP_NAME_RE = re.compile(r"^\d{8}-\d{6}-conan\.tar\.gz$")
GAME_PROCESS = os.environ.get("FLUX_GAME_PROCESS", "ConanSandboxServer-Linux-Shipping")
# The kernel's 15-character name for it, matched exactly (see flux-lib.sh).
GAME_COMM = os.environ.get("FLUX_GAME_COMM", GAME_PROCESS[:15])

# The world: the database and the game's own sidecars. -wal/-shm are never copied loose: the backup
# API writes one consistent file.
WORLD_DB = "game_0.db"
LEGACY_DB = "game.db"
# The game's own rotating copies of the world (game_0_backup_N.db).
GAME_BACKUP_RE = re.compile(r"^game(_\d+)?_backup_\d+\.db$")
# Whether this server has had a world, and a new world the panel asked for (world-guard).
WORLDS_SEEN = os.path.join(STATE_DIR, "worlds.json")
# When the world went missing, on THIS node (kept off the synced volume, so each node counts its
# own wait), and how long the guard waits for Syncthing before it puts a backup back.
WORLD_MISSING = os.path.join(LOCAL_DIR, "world-missing.json")
WORLD_SYNC_GRACE = int(os.environ.get("FLUX_WORLD_SYNC_GRACE_SECONDS", "300"))
CONFLICTS_DIR = os.path.join(STATE_DIR, "sync-conflicts")

MAX_PLAYERS_CAP = 70
DEFAULT_PORT = 7777
DEFAULT_QUERY_PORT = 27015
DEFAULT_RCON_PORT = 25575
# The game's RCON anti-flood ("karma"): past RconMaxKarma, connections from an address are denied
# for minutes ("triggered karma system and has been denied"). 60 was reached by ~14 one-shot
# connections in 15 s from 127.0.0.1 (measured, 2026-10-24), and every RCON user is inside the
# container (the hub's player list every 15 s, the stop's checkpoint, the restart warnings), so
# the limit only ever locks us out. CONAN_RCON_MAX_KARMA overrides it.
DEFAULT_RCON_MAX_KARMA = 100000
NAME_MAX = 60
PASSWORD_MAX = 32

# ServerSettings.ini keys this image writes on every start (from env); the hub's Server Settings
# tab leaves them alone.
OWNED_SERVER_SETTINGS = ("AdminPassword", "ServerPassword")

WORKSHOP_ID_RE = re.compile(r"^\d{6,12}$")
MODS_MAX = 60


# ------------------------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def write_json(path, data, indent=2):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=indent)
        f.write("\n")
    os.replace(tmp, path)


def out(data):
    print(json.dumps(data, ensure_ascii=False))


def fail(message, code=1):
    out({"ok": False, "error": message})
    sys.exit(code)


def env(name):
    """The value of a variable that is set to something; None when unset or empty."""
    value = os.environ.get(name)
    if value is None:
        return None
    value = value.strip()
    return value or None


def truthy(value):
    return str(value or "").strip().lower() in ("1", "true", "yes", "on")


def clean_text(value, limit):
    """One line, no control characters, no quotes or backslashes (they end an ini value or a
    command-line argument), at most `limit` characters."""
    text = re.sub(r"[\x00-\x1f\x7f\"\\]", "", str(value or "")).strip()
    return text[:limit]


def clean_password(value):
    """A password as the game and the launch line can carry it: printable, no spaces or quotes."""
    return re.sub(r"[^\x21-\x7e]|[\"\\]", "", str(value or ""))[:PASSWORD_MAX]


def port_of(name, default):
    raw = env(name)
    if raw is None:
        return default
    if not re.fullmatch(r"\d{1,5}", raw) or not 1024 <= int(raw) <= 65534:
        print(f"# WARN {name}={raw} is not a port from 1024 to 65534; using {default}")
        return default
    return int(raw)


def max_players():
    raw = env("CONAN_MAX_PLAYERS")
    if raw is None:
        return 40
    if not re.fullmatch(r"\d{1,3}", raw) or not 1 <= int(raw) <= MAX_PLAYERS_CAP:
        print(f"# WARN CONAN_MAX_PLAYERS={raw} is not 1 to {MAX_PLAYERS_CAP}; using 40")
        return 40
    return int(raw)


def rcon_max_karma():
    raw = env("CONAN_RCON_MAX_KARMA")
    if raw is None:
        return DEFAULT_RCON_MAX_KARMA
    if not re.fullmatch(r"\d{1,9}", raw) or int(raw) < 1:
        print(f"# WARN CONAN_RCON_MAX_KARMA={raw} is not a positive number; using {DEFAULT_RCON_MAX_KARMA}")
        return DEFAULT_RCON_MAX_KARMA
    return int(raw)


def rcon_password():
    """The owner's (CONAN_RCON_PASSWORD), or one made up once and kept on the data volume: RCON is
    always on, because the hub's console, player list and bans speak it from inside the container."""
    own = clean_password(env("CONAN_RCON_PASSWORD") or "")
    if own:
        return own
    try:
        with open(RCON_FILE, encoding="utf-8") as f:
            kept = clean_password(f.read().strip())
        if len(kept) >= 16:
            return kept
    except OSError:
        pass
    made = "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(24))
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(RCON_FILE, "w", encoding="utf-8") as f:
        f.write(made + "\n")
    os.chmod(RCON_FILE, 0o600)
    return made


# ------------------------------------------------------------------------------------------------
# Unreal ini files: sections of key=value lines. Keys are matched without case (Unreal reads them
# that way, and Enhanced rewrote ClanMaxSize as clanMaxSize). Every other line is kept as it is.
# ------------------------------------------------------------------------------------------------

def ini_encoding(path):
    """How the file is written. Unreal saves an ini as UTF-16LE with a BOM when a value has a
    character outside ASCII (a name with an accent); read as UTF-8 that is one garbled line per
    character, and every section would be added again. The file is written back the same way."""
    try:
        with open(path, "rb") as f:
            head = f.read(3)
    except OSError:
        return "utf-8"
    if head[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return "utf-16"
    if head == b"\xef\xbb\xbf":
        return "utf-8-sig"
    return "utf-8"


def ini_read(path):
    try:
        with open(path, encoding=ini_encoding(path), errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def ini_get(lines, section, key):
    current = None
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            current = s[1:-1]
            continue
        if current == section and "=" in s and not s.startswith(";"):
            k, v = s.split("=", 1)
            if k.strip().lower() == key.lower():
                return v.strip()
    return None


def ini_set(lines, section, key, value):
    """Sets key=value in [section] (value None removes the key). Returns the new lines."""
    out_lines, current, done, section_seen, insert_at = [], None, False, False, None
    for line in lines:
        s = line.strip()
        if s.startswith("[") and s.endswith("]"):
            if current == section and not done:
                insert_at = len(out_lines)
            current = s[1:-1]
            if current == section:
                section_seen = True
            out_lines.append(line)
            continue
        if current == section and "=" in s and not s.startswith(";") and s.split("=", 1)[0].strip().lower() == key.lower():
            if not done and value is not None:
                out_lines.append(f"{key}={value}")
            done = True
            continue
        out_lines.append(line)
    if done or value is None:
        return out_lines
    if section_seen:
        if insert_at is None:
            # The section is the last one: after its last non-blank line.
            insert_at = len(out_lines)
            while insert_at > 0 and not out_lines[insert_at - 1].strip():
                insert_at -= 1
        out_lines.insert(insert_at, f"{key}={value}")
        return out_lines
    if out_lines and out_lines[-1].strip():
        out_lines.append("")
    out_lines += [f"[{section}]", f"{key}={value}"]
    return out_lines


def ini_write(path, lines, encoding="utf-8"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".flux-tmp"
    # "utf-16" writes the BOM and little-endian on this machine, as Unreal does.
    with open(tmp, "w", encoding=encoding) as f:
        f.write("\n".join(lines).rstrip("\n") + "\n")
    os.replace(tmp, path)


def ini_apply(path, changes):
    """changes = [(section, key, value|None)]. Writes the file only when something changed."""
    before = ini_read(path)
    lines = list(before)
    for section, key, value in changes:
        lines = ini_set(lines, section, key, value)
    if lines != before:
        ini_write(path, lines, ini_encoding(path))
        return True
    return False


# ------------------------------------------------------------------------------------------------
# apply: the files the server reads at start, from the environment
# ------------------------------------------------------------------------------------------------

REGIONS = {"all": None, "exiled-lands": "IsleOfSiptah"}


# ------------------------------------------------------------------------------------------------
# ServerSettings.ini edits the panel queues (the PvP schedule tab): written by `apply` before the
# next start, never under a running server, which writes the file back as it shuts down.
# ------------------------------------------------------------------------------------------------

SETTINGS_PENDING = os.path.join(STATE_DIR, "settings-pending.json")
SETTING_KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{1,63}$")
SETTING_VALUE_RE = re.compile(r"^[^\r\n\"\\]{0,200}$")
WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
SCHEDULE_KEYS = (["RestrictPVPTime", "RestrictPVPBuildingDamageTime"]
                 + [f"PVPEnabled{d}" for d in WEEKDAYS] + [f"PVPTime{d}{e}" for d in WEEKDAYS for e in ("Start", "End")]
                 + [f"PVPBuildingDamageEnabled{d}" for d in WEEKDAYS]
                 + [f"PVPBuildingDamageTime{d}{e}" for d in WEEKDAYS for e in ("Start", "End")])


def cmd_settings(*keys):
    """Values of ServerSettings.ini keys (all the schedule's when none are named), with what is
    queued for the next start on top."""
    lines = ini_read(os.path.join(CONFIG_DIR, "ServerSettings.ini"))
    wanted = keys or SCHEDULE_KEYS
    pending = read_json(SETTINGS_PENDING, {}) or {}
    out({"settings": {k: ini_get(lines, "ServerSettings", k) for k in wanted},
         "pending": {k: v for k, v in pending.items() if k in wanted}})


def cmd_set_settings(raw):
    """Queues ServerSettings.ini values for the next start: {"Key": "value", ...}."""
    try:
        wanted = json.loads(raw)
    except ValueError:
        fail("not JSON", 2)
    if not isinstance(wanted, dict) or not wanted:
        fail("give {\"Key\": \"value\"}", 2)
    for k, v in wanted.items():
        if not SETTING_KEY_RE.match(str(k)) or k.lower() in (x.lower() for x in OWNED_SERVER_SETTINGS):
            fail(f"{k} cannot be set here", 2)
        if not SETTING_VALUE_RE.match(str(v)):
            fail(f"the value of {k} cannot be used", 2)
    pending = read_json(SETTINGS_PENDING, {}) or {}
    pending.update({str(k): str(v) for k, v in wanted.items()})
    write_json(SETTINGS_PENDING, pending, indent=None)
    restarted = bool(game_pids()) and request_restart("requested: server settings")
    out({"ok": True, "pending": len(pending), "serverQuit": restarted, "appliesOn": "restart"})


def apply_pending_settings(settings_ini):
    pending = read_json(SETTINGS_PENDING)
    if not isinstance(pending, dict) or not pending:
        return
    ini_apply(settings_ini, [("ServerSettings", k, v) for k, v in pending.items()])
    os.remove(SETTINGS_PENDING)
    print(f"# server settings from the panel: {len(pending)} value(s) written")


def server_name():
    return clean_text(env("CONAN_SERVER_NAME") or "Conan Exiles on Flux", NAME_MAX) or "Conan Exiles on Flux"


def launch_args(port, query_port, players, name, password):
    args = [f"-Port={port}", f"-QueryPort={query_port}", f"-MaxPlayers={players}", f"-ServerName={name}"]
    if password:
        args.append(f"-ServerPassword={password}")
    return args


def cmd_apply():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    port = port_of("CONAN_PORT", DEFAULT_PORT)
    query_port = port_of("CONAN_QUERY_PORT", DEFAULT_QUERY_PORT)
    rcon_port = port_of("CONAN_RCON_PORT", DEFAULT_RCON_PORT)
    players = max_players()
    name = server_name()
    password = clean_password(env("CONAN_SERVER_PASSWORD") or "")
    admin = clean_password(env("CONAN_ADMIN_PASSWORD") or "")

    # Game.ini: Enhanced does not write one, and RCON keys anywhere else are ignored ("Rcon
    # disabled", measured). MaxPlayers here as well as on the launch line.
    game_ini = os.path.join(CONFIG_DIR, "Game.ini")
    ini_apply(game_ini, [
        ("RconPlugin", "RconEnabled", "1"),
        ("RconPlugin", "RconPassword", rcon_password()),
        ("RconPlugin", "RconPort", str(rcon_port)),
        ("RconPlugin", "RconMaxKarma", str(rcon_max_karma())),
        ("/Script/Engine.GameSession", "MaxPlayers", str(players)),
    ])
    os.chmod(game_ini, 0o600)

    # Engine.ini: the name and join password where Enhanced keeps them, and which half of the map
    # runs. A stale UE4 BuildIdOverride makes every join fail ("Pending Connection Failure").
    region = (env("CONAN_MAP_REGIONS") or "all").lower()
    if region not in REGIONS:
        print(f"# WARN CONAN_MAP_REGIONS={region} is not all or exiled-lands; running both")
        region = "all"
    ini_apply(os.path.join(CONFIG_DIR, "Engine.ini"), [
        ("OnlineSubsystem", "ServerName", name),
        ("OnlineSubsystem", "ServerPassword", password),
        ("OnlineSubsystemSteam", "bUseBuildIdOverride", None),
        ("OnlineSubsystemSteam", "BuildIdOverride", None),
        ("Regions", "ExcludedRegions", REGIONS[region]),
    ])

    # ServerSettings.ini: only the keys this image owns. A file the server has not written yet is
    # started with its section, and the server adds the rest on its first start.
    settings_ini = os.path.join(CONFIG_DIR, "ServerSettings.ini")
    apply_pending_settings(settings_ini)
    apply_pending_bans()
    ini_apply(settings_ini, [
        ("ServerSettings", "AdminPassword", admin),
        ("ServerSettings", "ServerPassword", password),
    ])

    print(f"# {name}: game UDP {port} (+{port + 1}), query UDP {query_port}, RCON TCP {rcon_port}, "
          f"{players} players, {'a join password' if password else 'no join password'}, "
          f"{'an admin password' if admin else 'NO admin password'}, regions {region}")
    for a in launch_args(port, query_port, players, name, password):
        print(a)


# ------------------------------------------------------------------------------------------------
# Mods: a Workshop ID list in load order (flux/mods.json), downloaded with SteamCMD before each
# start; modlist.txt lists each mod's .pak, the first line loading first.
# ------------------------------------------------------------------------------------------------

def parse_ids(raw):
    """Workshop IDs from text: IDs or links, separated by commas, spaces or new lines. Order kept,
    duplicates dropped."""
    seen, ids = set(), []
    for token in re.split(r"[\s,;]+", str(raw or "")):
        m = re.search(r"[?&]id=(\d{6,12})", token) or re.fullmatch(r"(\d{6,12})", token)
        if m and m.group(1) not in seen:
            seen.add(m.group(1))
            ids.append(m.group(1))
    return ids[:MODS_MAX]


def mods_state():
    """flux/mods.json, with CONAN_MODS applied when it CHANGED since it was last seen: a
    deployment's list replaces the panel's when the owner edits it in Deployment Settings, and
    otherwise the panel's list is the one that counts."""
    state = read_json(MODS_FILE, {}) or {}
    ids = [i for i in state.get("mods", []) if WORKSHOP_ID_RE.match(str(i))]
    raw = os.environ.get("CONAN_MODS")
    if raw is not None and raw.strip() != state.get("envSeen", ""):
        ids = parse_ids(raw)
        state = {"mods": ids, "envSeen": raw.strip()}
        write_json(MODS_FILE, state)
    return ids, state


def pak_files(mod_id):
    folder = os.path.join(WORKSHOP_DIR, mod_id)
    found = []
    for root, _dirs, files in os.walk(folder):
        for f in files:
            if f.lower().endswith(".pak") and not f.lower().endswith("-linuxserver.pak"):
                found.append(os.path.relpath(os.path.join(root, f), folder))
    return sorted(found)


def mod_info(mod_id):
    folder = os.path.join(WORKSHOP_DIR, mod_id)
    paks = pak_files(mod_id)
    size = 0
    newest = 0
    for root, _dirs, files in os.walk(folder):
        for f in files:
            try:
                st = os.stat(os.path.join(root, f))
                size += st.st_size
                newest = max(newest, int(st.st_mtime))
            except OSError:
                pass
    return {"id": mod_id, "downloaded": bool(paks), "paks": paks, "size": size, "updated": newest or None}


def modlist_lines(ids):
    """modlist.txt: one line per .pak, `*<id>/<file>` relative to ConanSandbox/Mods (where each
    downloaded mod is linked by its ID). A mod with several paks keeps their sorted order."""
    lines = []
    for mod_id in ids:
        for pak in pak_files(mod_id):
            lines.append(f"*{mod_id}/{pak}")
    return lines


def cmd_mods_sync():
    ids, _ = mods_state()
    os.makedirs(MODS_DIR, exist_ok=True)
    if ids:
        args = ["steamcmd", "+force_install_dir", SERVER_DIR, "+login", "anonymous"]
        for mod_id in ids:
            args += ["+workshop_download_item", WORKSHOP_APP, mod_id]
        args.append("+quit")
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=1800)
            for line in result.stdout.splitlines():
                if "ERROR" in line or "failed" in line.lower():
                    print(f"# WARN steamcmd: {line.strip()[:200]}")
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f"# WARN the Workshop download did not finish ({e}); starting with what is there")
    # The mods folder: a link per mod to its Workshop download, and nothing else of ours.
    for entry in os.listdir(MODS_DIR):
        path = os.path.join(MODS_DIR, entry)
        if os.path.islink(path) and entry not in ids:
            os.remove(path)
    for mod_id in ids:
        link = os.path.join(MODS_DIR, mod_id)
        target = os.path.join(WORKSHOP_DIR, mod_id)
        if os.path.isdir(target) and not os.path.islink(link):
            if os.path.exists(link):
                shutil.rmtree(link, ignore_errors=True)
            os.symlink(target, link)
    lines = modlist_lines(ids)
    with open(os.path.join(MODS_DIR, "modlist.txt"), "w", encoding="utf-8") as f:
        f.write("".join(line + "\n" for line in lines))
    missing = [i for i in ids if not pak_files(i)]
    if missing:
        print(f"# WARN not downloaded (no .pak): {', '.join(missing)}")
    print(f"# mods: {len(ids) - len(missing)} of {len(ids)} loaded, {len(lines)} pak file(s)")
    mods_update_landed()


# ------------------------------------------------------------------------------------------------
# A mod the game refuses. The server logs "You are running incompatible mods ... The following
# mods failed mounting: - <path>/Mods/<id>/<file> (<reason>)" and exits 1 about 3.5 s after launch,
# every time: a restart can never fix it (a UE4 mod on the UE5 game, a mod the author has not
# updated). The supervisor stops restarting and waits for the owner to change the list.
# ------------------------------------------------------------------------------------------------

MOD_FAIL_HEAD = "The following mods failed mounting"
MOD_FAIL_RE = re.compile(r"^\s*-\s+\S*/Mods/(\d{6,12})/(\S+)\s+\((.*)\)\s*$")


def failed_mods(text):
    """[(id, file, reason)] from the game log's failed-mounting block; [] when there is none. Only
    the LAST block counts (the log of one generation has one, but a log file may hold several)."""
    found = []
    inside = False
    for line in text.splitlines():
        if MOD_FAIL_HEAD in line:
            inside = True
            found = []
            continue
        if inside:
            m = MOD_FAIL_RE.match(line)
            if m:
                found.append((m.group(1), m.group(2), m.group(3)))
            elif line.strip() and not line.startswith(" -"):
                inside = False
    seen = set()
    return [x for x in found if not (x[0] in seen or seen.add(x[0]))]


def cmd_mods_failed():
    """Exit 0 and put the mods in state.json (failedMods) when the last generation's log shows the
    game refusing a mod; exit 1 otherwise."""
    # The game's own log, not its stdout: the server exits by force and loses the buffered stdout.
    try:
        with open(ENGINE_LOG, encoding="utf-8", errors="replace") as f:
            text = f.read()
        started = int(open(GENERATION_FILE, encoding="utf-8").read().split()[1])
        if os.path.getmtime(ENGINE_LOG) < started:
            sys.exit(1)  # a log of an earlier generation
    except (OSError, ValueError, IndexError):
        sys.exit(1)
    bad = failed_mods(text)
    if not bad:
        sys.exit(1)
    data = read_json(STATE_FILE, {}) or {}
    data["failedMods"] = [{"id": i, "file": fl, "reason": why} for i, fl, why in bad]
    write_json(STATE_FILE, data, indent=None)
    for i, fl, why in bad:
        print(f"# mod {i} ({fl}) was refused by the game: {why}")


def cmd_mods_fixed():
    """Exit 0 when the owner has dealt with the refused mods: every one is off the list now."""
    data = read_json(STATE_FILE, {}) or {}
    bad = {m.get("id") for m in data.get("failedMods") or []}
    ids, _ = mods_state()
    if bad and bad & set(ids):
        sys.exit(1)
    data.pop("failedMods", None)
    write_json(STATE_FILE, data, indent=None)


def cmd_mods():
    ids, state = mods_state()
    out({"mods": [mod_info(i) for i in ids], "env": state.get("envSeen", ""),
         "loaded": read_lines(os.path.join(MODS_DIR, "modlist.txt"))})


def read_lines(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f if line.strip()]
    except OSError:
        return []


def cmd_set_mods(raw):
    try:
        wanted = json.loads(raw)
    except ValueError:
        fail("the list is not JSON", 2)
    if not isinstance(wanted, list) or not all(WORKSHOP_ID_RE.match(str(i)) for i in wanted):
        fail("the list must be Workshop IDs (6 to 12 digits)", 2)
    ids = list(dict.fromkeys(str(i) for i in wanted))
    if len(ids) > MODS_MAX:
        fail(f"at most {MODS_MAX} mods", 2)
    state = read_json(MODS_FILE, {}) or {}
    state["mods"] = ids
    # Keep envSeen: the deployment's own list counts again only once it is changed there.
    state.setdefault("envSeen", (os.environ.get("CONAN_MODS") or "").strip())
    write_json(MODS_FILE, state)
    out({"ok": True, "mods": ids, "appliesOn": "restart"})


# ------------------------------------------------------------------------------------------------
# RCON (Source RCON over TCP): the server's own admin channel, spoken from inside the container.
# ------------------------------------------------------------------------------------------------

class RconError(Exception):
    pass


class RconRefused(RconError):
    """The server took the connection and dropped it before answering: its anti-flood ("karma")
    denies an address for minutes after too many connections."""


RCON_REFUSED = ("RCON refused the connection (the game's anti-flood \"karma\" limit, Game.ini "
                "RconMaxKarma): wait a few minutes and try again")


class RconClosed(RconError):
    pass


def _rcon_packet(req_id, kind, body):
    data = body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<iii", len(data) + 8, req_id, kind) + data


def _rcon_read(sock):
    def exact(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise RconClosed("the server closed the RCON connection")
            buf += chunk
        return buf
    size = struct.unpack("<i", exact(4))[0]
    if not 10 <= size <= 1 << 20:
        raise RconError("a malformed RCON reply")
    data = exact(size)
    req_id, kind = struct.unpack("<ii", data[:8])
    return req_id, kind, data[8:-2].decode("utf-8", "replace")


def rcon_settings():
    lines = ini_read(os.path.join(CONFIG_DIR, "Game.ini"))
    port = ini_get(lines, "RconPlugin", "RconPort") or str(DEFAULT_RCON_PORT)
    password = ini_get(lines, "RconPlugin", "RconPassword") or ""
    return int(port) if port.isdigit() else DEFAULT_RCON_PORT, password


def rcon(command, timeout=8.0, idle=0.4):
    """One command; the reply text.

    Conan answers a command a game tick or so later (0.5 to 1 s measured) and does NOT answer an
    empty request the usual way: it replies "Couldn't parse the command" with an unrelated id, so
    the common end-of-reply trick (an empty request after the command) shifts every reply by one
    (measured, build 25792439). So: wait up to `timeout` for the first packet, then take whatever
    follows within `idle` seconds, and close."""
    port, password = rcon_settings()
    if not password:
        raise RconError("RCON is not set up yet (no Game.ini): is the server still starting?")
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    except OSError as e:
        raise RconError(f"the server is not answering RCON on port {port} ({e.strerror or e}): is it still starting?")
    sock.settimeout(timeout)
    try:
        # A connection the karma system denies is accepted and closed at once (or reset): the
        # login or the command then meets a closed socket, never an answer.
        sock.sendall(_rcon_packet(1, 3, password))
        while True:
            req_id, kind, _ = _rcon_read(sock)
            if kind == 2:
                if req_id == -1:
                    raise RconError("the RCON password was refused")
                break
        sock.sendall(_rcon_packet(2, 2, command))
        parts = [_rcon_read(sock)[2]]
        sock.settimeout(idle)
        while True:
            try:
                parts.append(_rcon_read(sock)[2])
            except (OSError, RconError):
                break
        return "".join(parts)
    except socket.timeout:
        raise RconError("the server did not answer in time")
    except (RconClosed, BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        raise RconRefused(RCON_REFUSED)
    except OSError as e:
        raise RconError(f"RCON failed ({e.strerror or e})")
    finally:
        sock.close()


def one_line(text):
    return re.sub(r"[\x00-\x1f\x7f]+", " ", str(text or "")).strip()


def cmd_rcon(*words):
    command = one_line(" ".join(words))
    if not command:
        fail("no command", 2)
    try:
        sys.stdout.write(rcon(command))
        sys.stdout.write("\n")
    except RconRefused as e:
        print(str(e))
        sys.exit(3)
    except RconError as e:
        print(f"no server is running: {e}")
        sys.exit(3)


# ------------------------------------------------------------------------------------------------
# Players and bans, read off RCON
# ------------------------------------------------------------------------------------------------

def parse_table(text):
    """Conan's RCON tables: a header row of column names split by `|`, then one row per entry.
    Returns a list of dicts keyed by the header's names."""
    rows = [r for r in str(text or "").splitlines() if "|" in r]
    if not rows:
        return []
    header = [h.strip() for h in rows[0].split("|")]
    result = []
    for row in rows[1:]:
        cells = [c.strip() for c in row.split("|")]
        if len(cells) < 2:
            continue
        result.append({header[i] if i < len(header) else f"col{i}": cells[i] for i in range(len(cells))})
    return result


def player_rows(text):
    players = []
    for row in parse_table(text):
        lower = {k.lower().replace(" ", ""): v for k, v in row.items()}
        idx = lower.get("idx") or lower.get("index") or lower.get("#") or ""
        players.append({
            "idx": idx.strip(),
            "character": lower.get("charname") or lower.get("charactername") or lower.get("character") or "",
            "name": lower.get("playername") or lower.get("player") or "",
            "userId": lower.get("userid") or "",
            "platformId": lower.get("platformid") or lower.get("steamid") or "",
            "platform": lower.get("platformname") or lower.get("platform") or "",
        })
    return [p for p in players if p["character"] or p["name"] or p["platformId"]]


def cmd_players():
    try:
        out({"players": player_rows(rcon("listplayers"))})
    except RconError as e:
        fail(str(e), 3)


def ban_rows(text):
    bans = []
    for line in str(text or "").splitlines():
        s = line.strip()
        if not s or s.lower().startswith(("banned", "there are", "idx", "#")):
            continue
        m = re.search(r"(\d{6,20})", s)
        if m:
            bans.append({"platformId": m.group(1), "line": s})
    return bans


# Bans. `banplayer platformid <id>` works only on a player who is ONLINE ("No player with
# platform ID <id>." otherwise), and the server reads Saved/blacklist.txt (one SteamID64 a line)
# only at start: an id written there while it runs is not banned (measured, build 25792439). So a
# ban of someone offline is queued in flux/bans-pending.json and written into blacklist.txt by
# `apply`, before the next start. `unbanplayer <id>` works live and rewrites the file.

STEAM_ID_RE = re.compile(r"^7656119\d{10}$")
BANS_PENDING = os.path.join(STATE_DIR, "bans-pending.json")
BLACKLIST = os.path.join(SAVED_DIR, "blacklist.txt")


def pending_bans():
    ids = read_json(BANS_PENDING, [])
    return [str(i) for i in ids if STEAM_ID_RE.match(str(i))] if isinstance(ids, list) else []


def write_pending_bans(ids):
    write_json(BANS_PENDING, list(dict.fromkeys(ids)), indent=None)


def blacklist_lines():
    try:
        with open(BLACKLIST, encoding=ini_encoding(BLACKLIST), errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


def write_blacklist(lines):
    ini_write(BLACKLIST, lines, ini_encoding(BLACKLIST))
    try:
        uid = int(os.environ.get("FLUX_GAME_UID", "1000"))
        os.chown(BLACKLIST, uid, uid)
    except (OSError, ValueError):
        pass


def listed_id(line):
    """The SteamID64 a blacklist.txt line is about (the line may carry more after it)."""
    m = re.match(r"\s*(\d{17})", line)
    return m.group(1) if m else None


def cmd_ban(steam_id, *reason):
    if not STEAM_ID_RE.match(str(steam_id)):
        fail("not a SteamID64 (7656119 and 10 more digits)", 2)
    if game_pids():
        why = clean_text(one_line(" ".join(reason)), 120) or "Banned by an admin"
        try:
            reply = rcon(f"banplayer platformid {steam_id} {why}")
            low = reply.lower()
            if "banned" in low and "no player" not in low and "couldn't parse" not in low:
                out({"ok": True, "online": True})
                return
        except RconError:
            pass
    write_pending_bans(pending_bans() + [str(steam_id)])
    out({"ok": True, "online": False, "pending": True, "appliesOn": "restart"})


def cmd_unban(steam_id):
    if not STEAM_ID_RE.match(str(steam_id)):
        fail("not a SteamID64 (7656119 and 10 more digits)", 2)
    write_pending_bans([i for i in pending_bans() if i != steam_id])
    if game_pids():
        try:
            rcon(f"unbanplayer {steam_id}")
        except RconError:
            pass
    else:
        lines = blacklist_lines()
        kept = [line for line in lines if listed_id(line) != steam_id]
        if kept != lines:
            write_blacklist(kept)
    out({"ok": True})


def apply_pending_bans():
    """Before a start: the queued bans into Saved/blacklist.txt (the ones not there yet)."""
    pending = pending_bans()
    if not pending:
        return
    lines = blacklist_lines()
    listed = {listed_id(line) for line in lines}
    new = [i for i in pending if i not in listed]
    if new or not os.path.exists(BLACKLIST):
        write_blacklist([line for line in lines if line.strip()] + new)
    os.remove(BANS_PENDING)
    print(f"# bans from the panel: {len(new)} written to blacklist.txt")


def cmd_bans():
    """The ban list (listbans) and the bans queued for the next start. Without RCON (no server,
    or it refused), bans is empty and `error` says why: the queue is still worth showing."""
    try:
        raw = rcon("listbans")
        out({"bans": ban_rows(raw), "raw": raw, "pending": pending_bans()})
    except RconError as e:
        out({"bans": [], "raw": None, "pending": pending_bans(), "error": str(e)})


# ------------------------------------------------------------------------------------------------
# State for the hub
# ------------------------------------------------------------------------------------------------

def cmd_state(state, message=None):
    data = read_json(STATE_FILE, {}) or {}
    if data.get("state") != state:
        data["since"] = int(time.time())
    data["state"] = state
    if state == "running":
        data.pop("failedMods", None)
    # A stopped server has no restart coming and no update waiting.
    if state == "stopped":
        for key in ("nextRestart", "updateWaiting", "modUpdateWaiting"):
            data.pop(key, None)
    if message:
        data["message"] = message
    else:
        data.pop("message", None)
    write_json(STATE_FILE, data, indent=None)


def cmd_note(key, value=None):
    data = read_json(STATE_FILE, {}) or {}
    if value is None:
        data.pop(key, None)
    else:
        data[key] = int(value) if str(value).isdigit() else value
    write_json(STATE_FILE, data, indent=None)


def installed_build():
    try:
        with open(os.path.join(SERVER_DIR, "steamapps", f"appmanifest_{os.environ.get('FLUX_STEAM_APP', '443030')}.acf"), encoding="utf-8") as f:
            m = re.search(r'"buildid"\s+"(\d+)"', f.read())
            return m.group(1) if m else None
    except OSError:
        return None


def game_version():
    """The project version and engine build the server logs at start ("Set ProjectVersion to 3.0.1",
    "Engine Version: 5.8.2-379176+++exiles+release")."""
    version = engine = None
    try:
        with open(GAME_LOG, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 3000:
                    break
                m = re.search(r"Set ProjectVersion to ([\d.]+)", line)
                if m:
                    version = m.group(1).rstrip(".")
                m = re.search(r"Engine Version: ([\w.+-]+)", line)
                if m:
                    engine = m.group(1)
                if version and engine:
                    break
    except OSError:
        pass
    return version, engine


def generation():
    try:
        with open(GENERATION_FILE, encoding="utf-8") as f:
            n, since = f.read().split()[:2]
            return {"n": int(n), "since": int(since)}
    except (OSError, ValueError):
        return None


def game_pids():
    """PIDs of the running game; a killed one not yet reaped (a zombie) is not running."""
    alive = []
    for pid in subprocess.run(["pgrep", "-x", GAME_COMM], capture_output=True, text=True).stdout.split():
        try:
            with open(f"/proc/{pid}/stat", encoding="utf-8") as f:
                if f.read().rsplit(")", 1)[1].split()[0] == "Z":
                    continue
        except (OSError, IndexError):
            continue
        alive.append(pid)
    return alive


def world_db():
    for name in (WORLD_DB, LEGACY_DB):
        path = os.path.join(SAVED_DIR, name)
        if os.path.isfile(path):
            return path
    return None


def cmd_checkpoint():
    """With the server DEAD: replay the write-ahead log into game_0.db and truncate it, so the world is
    one self-contained file (what Syncthing copies, what a backup reads). Prints the result."""
    if game_pids():
        fail("the server is running; checkpoints go through RCON then (sql pragma wal_checkpoint)", 3)
    db = world_db()
    if not db:
        print("# no world database yet")
        return
    con = sqlite3.connect(db, timeout=10)
    try:
        busy, log, done = con.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()
        quick = con.execute("PRAGMA quick_check").fetchone()[0]
    finally:
        con.close()
    print(f"# world {os.path.basename(db)}: checkpoint busy={busy} wal-pages={log} written={done}, quick_check {quick}")


def cmd_status():
    state = read_json(STATE_FILE, {}) or {}
    version, engine = game_version()
    try:
        with open(PLAYERS_FILE, encoding="utf-8") as f:
            count = int(f.read().strip())
    except (OSError, ValueError):
        count = None
    db = world_db()
    ids, _ = mods_state()
    out({
        "state": state.get("state", "unknown"),
        "since": state.get("since"),
        "message": state.get("message"),
        "running": bool(game_pids()),
        "players": count,
        "maxPlayers": max_players(),
        "name": server_name(),
        "build": installed_build(),
        "version": version,
        "engine": engine,
        "generation": generation(),
        "world": {"file": os.path.basename(db) if db else None, "size": os.path.getsize(db) if db else 0,
                  "modified": int(os.path.getmtime(db)) if db else None},
        "mods": len(ids),
        "nextRestart": state.get("nextRestart"),
        "updateWaiting": state.get("updateWaiting"),
        "modUpdateWaiting": state.get("modUpdateWaiting"),
        "failedMods": state.get("failedMods"),
        "restartPending": os.path.exists(RESTART_MARKER),
        "pending": (read_json(RESTORE_FILE, {}) or {}).get("backup"),
        "lastAction": state.get("lastAction"),
        "worldRestored": state.get("worldRestored"),
        "image": os.environ.get("FLUX_IMAGE_VERSION", "dev"),
    })


def cmd_players_seen(count):
    with open(PLAYERS_FILE + ".tmp", "w", encoding="utf-8") as f:
        f.write(str(int(count)))
    os.replace(PLAYERS_FILE + ".tmp", PLAYERS_FILE)


# ------------------------------------------------------------------------------------------------
# Restarts
# ------------------------------------------------------------------------------------------------

def request_restart(reason):
    if os.path.exists(RESTART_MARKER):
        return False
    tmp = RESTART_MARKER + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(f"{reason}\nnotbefore=0\n")
    os.replace(tmp, RESTART_MARKER)
    return True


def cmd_restart():
    waiting = (read_json(STATE_FILE, {}) or {}).get("state") == "needs-mod-fix"
    if not game_pids() and not waiting:
        fail("the server is not running", 3)
    started = request_restart("requested: from the panel")
    out({"ok": True, "alreadyPending": not started, "generation": generation()})


# ------------------------------------------------------------------------------------------------
# Backups: flux/backups/<UTC>-conan.tar.gz with the world (a consistent copy of game_0.db made with
# SQLite's backup API) and the server's ini files. Made by the supervisor on start and every few
# hours, before a restore and before a new world.
#
# Kept: the FLUX_BACKUP_KEEP newest, AND the newest one older than a day and the newest one older
# than a week, so a server that crash-loops (each start a backup) can never rotate every good copy
# away. A start backup is skipped when the newest is younger than FLUX_BACKUP_MIN_AGE_MINUTES.
# ------------------------------------------------------------------------------------------------

def backup_files():
    try:
        names = [n for n in os.listdir(BACKUP_DIR) if BACKUP_NAME_RE.match(n)]
    except OSError:
        return []
    return sorted(names, reverse=True)


def backup_time(name):
    import calendar
    try:
        return calendar.timegm(time.strptime(name[:15], "%Y%m%d-%H%M%S"))
    except ValueError:
        return 0


def backups_to_keep(names, keep, now):
    """Names newest first. The `keep` newest, the newest older than 1 day, the newest older than 7."""
    kept = set(names[:max(keep, 0)])
    for age in (86400, 7 * 86400):
        older = [n for n in names if now - backup_time(n) >= age]
        if older:
            kept.add(older[0])
    return kept


def sqlite_copy(src, dst):
    """A consistent copy of a live SQLite database (the WAL folded in)."""
    source = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=30)
    try:
        target = sqlite3.connect(dst)
        try:
            source.backup(target)
        finally:
            target.close()
    finally:
        source.close()


def is_conflict(name):
    """A Syncthing conflict copy (name.sync-conflict-<date>-<time>-<device>.ext): never a world,
    never in a backup."""
    return "sync-conflict" in os.path.basename(name)


def local_staging(prefix):
    """A staging folder on the LOCAL volume: a world copy made on the synced one would be copied
    to the other node as it is written."""
    os.makedirs(LOCAL_TMP, exist_ok=True)
    return tempfile.mkdtemp(dir=LOCAL_TMP, prefix=prefix)


class BackupError(Exception):
    pass


def make_backup(why, force=None):
    """The backup itself. Returns its name; None when there is nothing to do (no world yet, or a
    recent one is enough); raises BackupError when it could not be made."""
    db = world_db()
    if not db:
        print("# backup skipped: no world yet")
        return None
    names = backup_files()
    now = int(time.time())
    min_age = int(os.environ.get("FLUX_BACKUP_MIN_AGE_MINUTES", "60")) * 60
    if force not in ("force", "force-quiet") and names and now - backup_time(names[0]) < min_age:
        print(f"# backup ({why}) skipped: the newest is {(now - backup_time(names[0])) // 60} min old")
        return None
    name = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now)) + "-conan.tar.gz"
    if name in names:
        time.sleep(1)
        now = int(time.time())
        name = time.strftime("%Y%m%d-%H%M%S", time.gmtime(now)) + "-conan.tar.gz"
    out_path = os.path.join(BACKUP_DIR, name)
    staging = None
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
        staging = local_staging(".flux-backup-")
        copy = os.path.join(staging, WORLD_DB)
        sqlite_copy(db, copy)
        with tarfile.open(out_path + ".part", "w:gz") as t:
            t.add(copy, arcname=f"Saved/{WORLD_DB}")
            if os.path.isdir(CONFIG_DIR):
                for f in sorted(os.listdir(CONFIG_DIR)):
                    if f.endswith(".ini") and not is_conflict(f):
                        t.add(os.path.join(CONFIG_DIR, f), arcname=f"Saved/Config/LinuxServer/{f}")
            if os.path.isfile(MODS_FILE):
                t.add(MODS_FILE, arcname="flux/mods.json")
        os.replace(out_path + ".part", out_path)
    except (OSError, tarfile.TarError, sqlite3.Error) as e:
        try:
            os.remove(out_path + ".part")
        except OSError:
            pass
        raise BackupError(str(e))
    finally:
        if staging:
            shutil.rmtree(staging, ignore_errors=True)
    index = read_json(BACKUP_INDEX, {}) or {}
    index[name] = why
    keep = int(os.environ.get("FLUX_BACKUP_KEEP", "10"))
    names = backup_files()
    kept = backups_to_keep(names, keep, now)
    for old in names:
        if old not in kept:
            try:
                os.remove(os.path.join(BACKUP_DIR, old))
            except OSError:
                pass
            index.pop(old, None)
    write_json(BACKUP_INDEX, {k: v for k, v in index.items() if k in kept}, indent=None)
    print(f"# backup ({why}): flux/backups/{name}, {os.path.getsize(out_path) // 1024} KB")
    return name


def cmd_backup(why, force=None):
    """The supervisor's and the panel's backup. Exit 1 when it failed; with `force` (the panel's
    "back up now") the outcome is also one JSON line."""
    try:
        name = make_backup(why, force)
    except BackupError as e:
        print(f"# WARN backup ({why}) failed: {e}")
        if force == "force":
            out({"ok": False, "error": f"The backup failed: {e}"})
        sys.exit(1)
    if force == "force":
        if name:
            out({"ok": True, "name": name, "size": os.path.getsize(os.path.join(BACKUP_DIR, name))})
        else:
            out({"ok": False, "error": "There is no world to back up yet: the server makes it on its first start."})


def cmd_backups():
    index = read_json(BACKUP_INDEX, {}) or {}
    rows = [{"name": n, "size": os.path.getsize(os.path.join(BACKUP_DIR, n)), "created": backup_time(n), "reason": index.get(n)}
            for n in backup_files()]
    pending = read_json(RESTORE_FILE, {}) or {}
    out({"backups": rows, "path": "flux/backups", "pending": pending.get("backup") or pending.get("action")})


def cmd_restore(name):
    """Restores a backup (the world and the ini files) on the next start, after a safety backup.
    The server is restarted now when it runs."""
    if not BACKUP_NAME_RE.match(str(name)) or not os.path.isfile(os.path.join(BACKUP_DIR, name)):
        fail("no such backup", 2)
    write_json(RESTORE_FILE, {"backup": name, "at": int(time.time())}, indent=None)
    restarted = bool(game_pids()) and request_restart(f"requested: restore {name}")
    out({"ok": True, "backup": name, "serverQuit": restarted, "appliesOn": "restart"})


def cmd_new_world():
    """A fresh world on the next start: the database is moved out of the way (after a safety
    backup); settings, mods and the ini files stay."""
    write_json(RESTORE_FILE, {"action": "new-world", "at": int(time.time())}, indent=None)
    restarted = bool(game_pids()) and request_restart("requested: a new world")
    out({"ok": True, "serverQuit": restarted, "appliesOn": "restart"})


IMPORT_DIR = os.path.join(STATE_DIR, "import")


def looks_like_sqlite(path):
    try:
        with open(path, "rb") as f:
            return f.read(16) == b"SQLite format 3\x00"
    except OSError:
        return False


def cmd_import_world(name):
    """A world uploaded into flux/import (the hub's Backups tab): checked now, put in place on the
    next start after a safety backup. A file named game.db is an older (UE4) world, which the
    server converts on its first start (Funcom's own migration); anything else becomes game_0.db."""
    base = os.path.basename(str(name))
    path = os.path.join(IMPORT_DIR, base)
    if base != str(name) or not os.path.isfile(path):
        fail("no such upload in flux/import", 2)
    if not looks_like_sqlite(path):
        os.remove(path)
        fail("that file is not a Conan Exiles world: a world is game.db or game_0.db (an SQLite database)", 2)
    write_json(RESTORE_FILE, {"action": "import", "file": base, "at": int(time.time())}, indent=None)
    restarted = bool(game_pids()) and request_restart(f"requested: import the world {base}")
    out({"ok": True, "file": base, "serverQuit": restarted, "appliesOn": "restart"})


def remove_world():
    """The world database and its sidecars. The game's own rotating copies (game_0_backup_N.db)
    stay: they are the game's, and the world guard counts them as a sign a world existed."""
    for f in os.listdir(SAVED_DIR) if os.path.isdir(SAVED_DIR) else []:
        if re.match(r"^game(_\d+)?\.db(-wal|-shm|-journal)?$", f):
            try:
                os.remove(os.path.join(SAVED_DIR, f))
            except OSError:
                pass


def put_world(src, target=WORLD_DB):
    """src becomes Saved/<target>, the old world (both names, their sidecars) gone. Copied next to
    it first and renamed into place, so the world is never missing for longer than a rename."""
    os.makedirs(SAVED_DIR, exist_ok=True)
    tmp = os.path.join(SAVED_DIR, target + ".flux-new")
    shutil.copy2(src, tmp)
    remove_world()
    os.replace(tmp, os.path.join(SAVED_DIR, target))


def iso_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def record_last_action(kind, name, ok, error=None):
    """status.lastAction: the restore / import / new world the panel asked for, as the start that
    applied (or refused) it saw it."""
    data = read_json(STATE_FILE, {}) or {}
    data["lastAction"] = {"kind": kind, "name": name, "ok": bool(ok), "error": error, "at": iso_now()}
    write_json(STATE_FILE, data, indent=None)


def mark_new_world():
    write_json(WORLDS_SEEN, {"newWorld": int(time.time())}, indent=None)


def cmd_do_restore():
    """The supervisor, before a start: the pending restore, import or new world. A safety backup
    first, and NOTHING is changed when it fails (the request is dropped, the reason is in
    status.lastAction and the start's message). The request is removed only once it is done, so a
    stop in the middle runs it again on the next start."""
    pending = read_json(RESTORE_FILE)
    if not isinstance(pending, dict):
        return
    action = pending.get("action") or "restore"
    name = pending.get("backup") or pending.get("file")
    staging = None
    try:
        if action == "import":
            src = os.path.join(IMPORT_DIR, os.path.basename(str(pending.get("file", ""))))
            if not looks_like_sqlite(src):
                raise ValueError(f"{pending.get('file')} is gone or not a world")
            make_backup("before importing a world", "force-quiet")
            target = LEGACY_DB if os.path.basename(src).lower() == LEGACY_DB else WORLD_DB
            put_world(src, target)
            os.remove(src)
            print(f"# imported {os.path.basename(src)} as Saved/{target}"
                  + (" (an older world: the server converts it on this start)" if target == LEGACY_DB else ""))
        elif action == "new-world":
            make_backup("before a new world", "force-quiet")
            # Marked BEFORE the world goes: the world guard lets this missing world through.
            mark_new_world()
            remove_world()
            print("# a new world: the old one is in the backups")
        else:
            src = os.path.join(BACKUP_DIR, name or "")
            if not BACKUP_NAME_RE.match(name or "") or not os.path.isfile(src):
                raise ValueError(f"{name} is not a backup")
            staging = local_staging(".flux-restore-")
            with tarfile.open(src) as t:
                members = [m for m in t.getmembers() if m.isfile() and (m.name.startswith("Saved/") or m.name == "flux/mods.json")]
                if not any(m.name == f"Saved/{WORLD_DB}" for m in members) or any(".." in m.name.split("/") for m in members):
                    raise ValueError("not a Conan Exiles backup")
                t.extractall(staging, members=members, filter="data")
            make_backup("before restoring " + name, "force-quiet")
            put_world(os.path.join(staging, "Saved", WORLD_DB))
            cfg = os.path.join(staging, "Saved", "Config", "LinuxServer")
            if os.path.isdir(cfg):
                os.makedirs(CONFIG_DIR, exist_ok=True)
                for f in os.listdir(cfg):
                    shutil.copy2(os.path.join(cfg, f), os.path.join(CONFIG_DIR, f))
            restored_mods = read_json(os.path.join(staging, "flux", "mods.json"))
            if isinstance(restored_mods, dict):
                # The backup's list, with the deployment's CONAN_MODS as it is NOW counted as seen:
                # an older envSeen would make a CONAN_MODS that differs replace the restored list.
                current = read_json(MODS_FILE, {}) or {}
                seen = current.get("envSeen") if "envSeen" in current else (os.environ.get("CONAN_MODS") or "").strip()
                restored_mods["envSeen"] = seen
                write_json(MODS_FILE, restored_mods)
            print(f"# restored {name}")
    except BackupError as e:
        print(f"# WARN {action} of {name or 'the world'} NOT done: the safety backup failed ({e}); the world is untouched")
        record_last_action(action, name, False, f"the safety backup failed: {e}")
        drop_pending()
        return
    except (OSError, tarfile.TarError, ValueError, sqlite3.Error) as e:
        print(f"# WARN {action} of {name or 'the world'} failed ({e}); nothing changed")
        record_last_action(action, name, False, str(e))
        drop_pending()
        return
    finally:
        if staging:
            shutil.rmtree(staging, ignore_errors=True)
    record_last_action(action, name, True)
    drop_pending()


def drop_pending():
    try:
        os.remove(RESTORE_FILE)
    except OSError:
        pass


# ------------------------------------------------------------------------------------------------
# The world guard (before every start). Flux runs this app on two nodes with the data volume
# synced (Syncthing): a node can start on a volume whose game_0.db has not arrived yet, and the
# game then makes a NEW world without a word, which syncs back over the real one. So: when the
# world is missing but this server had one (flux/worlds.json, a backup, or the game's own
# game_0_backup_N.db), the game is not started on nothing: after FLUX_WORLD_SYNC_GRACE_SECONDS for
# the sync, the newest backup is put back, or, with none, the start keeps waiting. A new world
# the panel asked for (new-world) is let through. Sync-conflict copies are moved aside.
# ------------------------------------------------------------------------------------------------

def quarantine_conflicts():
    moved = []
    for root, _dirs, files in os.walk(SAVED_DIR):
        if os.path.islink(root):
            continue
        for f in files:
            if is_conflict(f):
                os.makedirs(CONFLICTS_DIR, exist_ok=True)
                rel = os.path.relpath(os.path.join(root, f), SAVED_DIR).replace(os.sep, "__")
                try:
                    os.replace(os.path.join(root, f), os.path.join(CONFLICTS_DIR, rel))
                    moved.append(rel)
                except OSError:
                    pass
    return moved


def world_usable(path):
    return bool(path) and os.path.isfile(path) and os.path.getsize(path) > 0 and looks_like_sqlite(path)


def mark_world_seen(db):
    write_json(WORLDS_SEEN, {"seen": int(time.time()), "size": os.path.getsize(db)}, indent=None)


def cmd_world_seen():
    """The watcher, once the server is up: this world is one the server must never silently replace."""
    db = world_db()
    if world_usable(db):
        mark_world_seen(db)


def clear_world_missing():
    try:
        os.remove(WORLD_MISSING)
    except OSError:
        pass


def cmd_world_guard():
    """Exit 0: start the game (the world is there, was put back from a backup, or is a new one on
    purpose). Exit 3: do not start, wait (the reason is the last line)."""
    for rel in quarantine_conflicts():
        print(f"# WARN a Syncthing conflict copy {rel} was moved to flux/sync-conflicts/")
    seen = read_json(WORLDS_SEEN, {})
    seen = seen if isinstance(seen, dict) else {}
    db = world_db()
    if world_usable(db):
        clear_world_missing()
        return 0
    if seen.get("newWorld"):
        print("# a new world, as the panel asked: the game makes one")
        return 0
    evidence = []
    if seen.get("seen"):
        evidence.append(f"this server ran it ({time.strftime('%Y-%m-%d %H:%M UTC', time.gmtime(seen['seen']))})")
    names = backup_files()
    if names:
        evidence.append(f"{len(names)} backup(s)")
    game_copies = sorted(f for f in (os.listdir(SAVED_DIR) if os.path.isdir(SAVED_DIR) else []) if GAME_BACKUP_RE.match(f))
    if game_copies:
        evidence.append(f"the game's own {', '.join(game_copies[:3])}")
    if not evidence:
        return 0
    path = os.path.join(SAVED_DIR, WORLD_DB)
    why = "missing" if not os.path.exists(path) else "unusable"
    # Wait for Syncthing first. The backups are on the synced volume too and can arrive before
    # game_0.db: putting one back at once would give the file a new time, and Syncthing could then
    # send that OLDER world over the real one still on its way. Only a missing world waits.
    if why == "missing" and WORLD_SYNC_GRACE > 0:
        missing = read_json(WORLD_MISSING, {}) or {}
        since = missing.get("since") if isinstance(missing, dict) else None
        if not isinstance(since, (int, float)):
            since = time.time()
            write_json(WORLD_MISSING, {"since": since}, indent=None)
        left = int(WORLD_SYNC_GRACE - (time.time() - since))
        if left > 0:
            print(f"The world is missing on this node, but this server had one ({'; '.join(evidence)}). "
                  f"Waiting for it to sync before putting a backup back (about {max(1, (left + 59) // 60)} min).")
            return 3
    if os.path.exists(path):
        aside = f"{path}.flux-unusable-{time.strftime('%Y%m%d-%H%M%S', time.gmtime())}"
        try:
            os.replace(path, aside)
            print(f"# WARN game_0.db is unusable: kept as {os.path.basename(aside)}")
        except OSError:
            pass
    for name in names:
        staging = local_staging(".flux-restore-")
        try:
            with tarfile.open(os.path.join(BACKUP_DIR, name)) as t:
                member = t.getmember(f"Saved/{WORLD_DB}")
                t.extractall(staging, members=[member], filter="data")
            src = os.path.join(staging, "Saved", WORLD_DB)
            if not world_usable(src):
                raise ValueError("its world is not a database")
            put_world(src)
        except (OSError, KeyError, tarfile.TarError, ValueError) as e:
            print(f"# WARN the backup {name} could not be restored ({e}); trying an older one")
            continue
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        mark_world_seen(os.path.join(SAVED_DIR, WORLD_DB))
        clear_world_missing()
        msg = (f"The world was {why} on this node ({'; '.join(evidence)}): "
               f"restored the newest backup, {name}, instead of starting a new world")
        print(f"# WARN {msg}")
        data = read_json(STATE_FILE, {}) or {}
        data["worldRestored"] = {"backup": name, "at": iso_now(), "reason": why}
        write_json(STATE_FILE, data, indent=None)
        return 0
    print(f"The world is {why} on this node, but this server had one ({'; '.join(evidence)}) "
          f"and no backup could be put back. Not starting a new world over it: waiting for it to sync. "
          f"The panel's New world starts over instead.")
    return 3


# ------------------------------------------------------------------------------------------------
# Game updates that did not land: not retried for 6 hours.
# ------------------------------------------------------------------------------------------------

def cmd_update_target(build):
    write_json(UPDATE_TARGET_FILE, {"target": str(build), "at": int(time.time())}, indent=None)


def cmd_update_check():
    target = read_json(UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(UPDATE_TARGET_FILE)
    except OSError:
        pass
    have = installed_build()
    if have and have != target.get("target"):
        write_json(UPDATE_FAILED_FILE, {"target": target.get("target"), "at": int(time.time()), "installed": have}, indent=None)
        print(f"# WARN the update to build {target.get('target')} did not install (still {have}): not retried for 6 hours")
    else:
        try:
            os.remove(UPDATE_FAILED_FILE)
        except OSError:
            pass


def cmd_update_skip(build):
    failed = read_json(UPDATE_FAILED_FILE, {}) or {}
    recent = failed.get("target") == str(build) and time.time() - int(failed.get("at") or 0) < UPDATE_FAILED_SKIP
    sys.exit(0 if recent else 1)


# ------------------------------------------------------------------------------------------------
# Workshop mod updates. Steam clients update a mod as soon as its author publishes, and a server
# still on the old version refuses them (mod mismatch) until it restarts. The watcher asks Steam
# for each listed mod's time_updated (the public Web API, no key) and compares it with the
# timeupdated SteamCMD recorded when it downloaded the mod; a newer one is a restart (mods-sync
# downloads it). A mod update that did not land is not retried for 6 hours, like a game update.
# ------------------------------------------------------------------------------------------------

def installed_mod_times():
    """{id: timeupdated} from SteamCMD's appworkshop_440900.acf (WorkshopItemsInstalled)."""
    try:
        with open(WORKSHOP_ACF, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return {}
    # The block's text, up to its closing brace (the file is Valve's KeyValues, nested braces).
    start = text.find('"WorkshopItemsInstalled"')
    start = text.find("{", start) if start >= 0 else -1
    depth, end = 0, start
    while 0 <= end < len(text):
        depth += {"{": 1, "}": -1}.get(text[end], 0)
        if depth == 0:
            break
        end += 1
    block = text[start:end] if start >= 0 else ""
    found = {}
    for mid, body in re.findall(r'"(\d{6,12})"\s*\{([^{}]*)\}', block):
        t = re.search(r'"timeupdated"\s+"(\d+)"', body)
        if t:
            found[mid] = int(t.group(1))
    return found


def remote_mod_times(ids, timeout=20):
    """{id: time_updated} from Steam's GetPublishedFileDetails. Raises OSError / ValueError when
    Steam cannot be asked; a mod Steam does not know (removed, private) is left out."""
    import urllib.parse
    import urllib.request
    form = {"itemcount": str(len(ids))}
    for i, mid in enumerate(ids):
        form[f"publishedfileids[{i}]"] = mid
    req = urllib.request.Request(WORKSHOP_API, data=urllib.parse.urlencode(form).encode(), method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        details = json.loads(resp.read().decode("utf-8", "replace"))["response"]["publishedfiledetails"]
    return {str(d.get("publishedfileid")): int(d["time_updated"]) for d in details
            if int(d.get("result", 0)) == 1 and str(d.get("time_updated", "")).isdigit()}


def mods_needing_update(ids, remote, installed, failed, now):
    """The listed mods Steam has a newer version of than the one installed, in list order. A mod
    not installed at all is mods-sync's to fetch, not a restart. failed = {id: {"target", "at"}}:
    the same version that already failed to land within UPDATE_FAILED_SKIP is left alone."""
    wanted = []
    for mid in ids:
        if mid not in remote or mid not in installed or remote[mid] <= installed[mid]:
            continue
        f = failed.get(mid) or {}
        if f.get("target") == remote[mid] and now - int(f.get("at") or 0) < UPDATE_FAILED_SKIP:
            continue
        wanted.append(mid)
    return wanted


def cmd_mods_update_check():
    ids, _ = mods_state()
    if not ids:
        sys.exit(1)
    try:
        remote = remote_mod_times(ids)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print(f"# WARN could not ask Steam about the mods ({e}); trying again later")
        sys.exit(1)
    failed = read_json(MOD_UPDATE_FAILED_FILE, {}) or {}
    wanted = mods_needing_update(ids, remote, installed_mod_times(), failed, int(time.time()))
    if not wanted:
        sys.exit(1)
    write_json(MOD_UPDATE_TARGET_FILE, {mid: remote[mid] for mid in wanted}, indent=None)
    data = read_json(STATE_FILE, {}) or {}
    data["modUpdateWaiting"] = wanted
    write_json(STATE_FILE, data, indent=None)
    print(" ".join(wanted))


def mods_update_landed():
    """After mods-sync: a mod update the restart was for that is still not installed is recorded,
    so it is not retried for 6 hours."""
    target = read_json(MOD_UPDATE_TARGET_FILE)
    if not isinstance(target, dict):
        return
    try:
        os.remove(MOD_UPDATE_TARGET_FILE)
    except OSError:
        pass
    installed = installed_mod_times()
    failed = read_json(MOD_UPDATE_FAILED_FILE, {}) or {}
    now = int(time.time())
    for mid, when in target.items():
        if installed.get(mid, 0) < int(when):
            failed[mid] = {"target": int(when), "at": now}
            print(f"# WARN the update of mod {mid} did not install: not retried for 6 hours")
        else:
            failed.pop(mid, None)
    write_json(MOD_UPDATE_FAILED_FILE, failed, indent=None)


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 64
    cmd, rest = argv[0], argv[1:]
    commands = {
        "apply": (cmd_apply, (0,)),
        "mods-sync": (cmd_mods_sync, (0,)),
        "state": (cmd_state, (1, 2)),
        "note": (cmd_note, (1, 2)),
        "players-seen": (cmd_players_seen, (1,)),
        "status": (cmd_status, (0,)),
        "checkpoint": (cmd_checkpoint, (0,)),
        "players": (cmd_players, (0,)),
        "bans": (cmd_bans, (0,)),
        "unban": (cmd_unban, (1,)),
        "mods": (cmd_mods, (0,)),
        "set-mods": (cmd_set_mods, (1,)),
        "mods-failed": (cmd_mods_failed, (0,)),
        "mods-fixed": (cmd_mods_fixed, (0,)),
        "set-settings": (cmd_set_settings, (1,)),
        "restart": (cmd_restart, (0,)),
        "backup": (cmd_backup, (1, 2)),
        "backups": (cmd_backups, (0,)),
        "restore": (cmd_restore, (1,)),
        "new-world": (cmd_new_world, (0,)),
        "import-world": (cmd_import_world, (1,)),
        "do-restore": (cmd_do_restore, (0,)),
        "update-target": (cmd_update_target, (1,)),
        "update-check": (cmd_update_check, (0,)),
        "update-skip": (cmd_update_skip, (1,)),
        "mods-update-check": (cmd_mods_update_check, (0,)),
        "world-guard": (lambda: sys.exit(cmd_world_guard()), (0,)),
        "world-seen": (cmd_world_seen, (0,)),
    }
    if cmd == "settings":
        cmd_settings(*rest)
        return 0
    if cmd == "rcon":
        cmd_rcon(*rest)
        return 0
    if cmd == "ban" and rest:
        cmd_ban(*rest)
        return 0
    if cmd not in commands or len(rest) not in commands[cmd][1]:
        print(__doc__, file=sys.stderr)
        return 64
    commands[cmd][0](*rest)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
