#!/usr/bin/python3
"""A stand-in for ConanSandboxServer-Linux-Shipping in the image test (tests/image/in-container.sh).

Behaves like the real server where the supervisor cares (build 25792439, measured):
  - refuses to run as root ("Refusing to run with the root privileges.")
  - logs ProjectVersion, then "Started SourceServerQueries on port <QueryPort>", then a
    "LogServerStats: Status report. ... Players=0 ..." line every few seconds
  - reads RCON's port and password from Saved/Config/LinuxServer/Game.ini and answers Source RCON:
    listplayers (empty), broadcast, help, banplayer (of an offline player: "No player with
    platform ID"); replies arrive a moment later, as the game's do
  - SIGINT / SIGTERM: "Engine exit requested", then exits 130 / 143 after a short teardown
  - "crash" over RCON: exits 139 at once
"""
import os
import re
import signal
import socket
import struct
import sys
import threading
import time

if os.geteuid() == 0:
    print("Refusing to run with the root privileges.", flush=True)
    sys.exit(1)

args = " ".join(sys.argv[1:])
print(f"LogInit: Command Line: {args}", flush=True)
print("LogNetVersion: Set ProjectVersion to 3.0.1. Version Checksum will be recalculated on next use.", flush=True)
query = re.search(r"-QueryPort=(\d+)", args)
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.abspath(os.path.join(here, "..", "..", ".."))
saved = os.path.join(root, "ConanSandbox", "Saved")
cfg = open(os.path.join(saved, "Config", "LinuxServer", "Game.ini")).read()
port = int(re.search(r"RconPort=(\d+)", cfg).group(1))
password = re.search(r"RconPassword=(\S+)", cfg).group(1)

# The world: a database the server writes as it goes.
import sqlite3  # noqa: E402
db = sqlite3.connect(os.path.join(saved, "game_0.db"))
db.execute("create table if not exists t(v)")
db.execute("insert into t values ('tick')")
db.commit()
db.close()

# A mod the game refuses (the real one logs this block to Saved/Logs/ConanSandbox.log and exits 1
# about 3.5 s after launch, its stdout lost).
ml = os.path.join(root, "ConanSandbox", "Mods", "modlist.txt")
bad = [l.strip() for l in (open(ml).read().splitlines() if os.path.exists(ml) else []) if "Mod999999" in l]
if bad:
    mid, _, fn = bad[0].lstrip("*").partition("/")
    os.makedirs(os.path.join(saved, "Logs"), exist_ok=True)
    with open(os.path.join(saved, "Logs", "ConanSandbox.log"), "w") as f:
        f.write("[2026.10.19-15.33.05:646][  0]LogModManager: Error: You are running incompatible mods with this version of the game. The following mods failed mounting:\n\n"
                f" - /mnt/conan/server/ConanSandbox/Mods/{mid}/{fn} (Mod is too old and needs to be updated for this game version)\n\n"
                "These mods cannot be loaded and could lead to crashes for the client or server.\n")
    sys.exit(1)

stop = {"code": None}


def on_signal(signum, _frame):
    print("LogCore: Engine exit requested (reason: EngineExit() was called)", flush=True)
    stop["code"] = 130 if signum == signal.SIGINT else 143


signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)


def read_packet(conn):
    head = conn.recv(4)
    if len(head) < 4:
        raise EOFError
    size = struct.unpack("<i", head)[0]
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    req_id, kind = struct.unpack("<ii", data[:8])
    return req_id, kind, data[8:-2].decode()


def packet(req_id, kind, body):
    b = body.encode() + b"\x00\x00"
    return struct.pack("<iii", len(b) + 8, req_id, kind) + b


def client(conn):
    try:
        req_id, kind, body = read_packet(conn)
        conn.sendall(packet(req_id if body == password else -1, 2, ""))
        while True:
            req_id, kind, body = read_packet(conn)
            time.sleep(0.3)
            if body == "crash":
                os._exit(139)
            if body == "listplayers":
                reply = ""
            elif body.startswith("broadcast "):
                reply = ""
                print(f"LogRcon: broadcast: {body[10:]}", flush=True)
            elif body.startswith("sql pragma wal_checkpoint"):
                reply = "   busy |  log |  checkpointed |\n#0    0 |    0 |             0 |\n"
            elif body.startswith("banplayer platformid "):
                # Measured: an offline player cannot be banned over RCON.
                reply = f"No player with platform ID {body.split()[2]}."
            elif body == "help":
                reply = "Commands:\n\tlistplayers\n\tbroadcast\n"
            else:
                reply = f'Couldn\'t parse the command: {body}. Try "help"'
            conn.sendall(packet(req_id, 0, reply))
    except (EOFError, OSError):
        pass
    finally:
        conn.close()


def rcon_server():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", port))
    s.listen(4)
    print(f"LogRcon: Display: Rcon is ready for client connections on 0.0.0.0:{port}!", flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=client, args=(conn,), daemon=True).start()


threading.Thread(target=rcon_server, daemon=True).start()
time.sleep(1)
print(f"SourceServerQueries: Warning: Started SourceServerQueries on port {query.group(1) if query else 27015}", flush=True)
n = 0
while stop["code"] is None:
    time.sleep(0.2)
    n += 1
    if n % 10 == 0:
        print(f"[x]LogServerStats: Status report. Uptime={n // 5} Mem=1:2:3:4 CPU=1:2 Players=0 FPS=30:30:30", flush=True)
# The real teardown takes minutes and writes nothing; /tmp/slow-teardown makes this one slow too.
time.sleep(600 if os.path.exists("/tmp/slow-teardown") else 1)
print("LogExit: Exiting.", flush=True)
sys.exit(stop["code"])
