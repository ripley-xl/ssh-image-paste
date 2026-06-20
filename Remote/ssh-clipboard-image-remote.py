#!/usr/bin/env python3
"""Remote helper for writing uploaded images into the remote system clipboard."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
from pathlib import Path


def default_socket_path() -> Path:
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    if runtime_dir:
        return Path(runtime_dir) / "ssh-image-paste" / "clipboard.sock"
    return Path.home() / ".ssh-image-paste" / "clipboard.sock"


def write_image(path: Path, mime_type: str, socket_path: Path | None = None) -> int:
    socket_path = socket_path or default_socket_path()
    if os.environ.get("SSH_IMAGE_PASTE_DISABLE_SOCKET") != "1" and socket_path.exists():
        return forward_to_daemon(path, mime_type, socket_path)
    return direct_write_image(path, mime_type)


def direct_write_image(path: Path, mime_type: str) -> int:
    if not path.is_file():
        print(f"not a file: {path}", file=sys.stderr)
        return 2

    if shutil.which("wl-copy") and os.environ.get("WAYLAND_DISPLAY"):
        with path.open("rb") as input_file:
            return subprocess.call(["wl-copy", "--type", mime_type], stdin=input_file)

    if shutil.which("xclip") and os.environ.get("DISPLAY"):
        with path.open("rb") as input_file:
            return subprocess.call(
                ["xclip", "-selection", "clipboard", "-t", mime_type, "-i"],
                stdin=input_file,
            )

    if platform.system() == "Darwin" and shutil.which("osascript"):
        script = """
on run argv
  set imageFile to POSIX file (item 1 of argv)
  set the clipboard to (read imageFile as «class PNGf»)
end run
"""
        return subprocess.run(
            ["osascript", "-", str(path)],
            input=script.encode("utf-8"),
            check=False,
        ).returncode

    print(
        "no remote image clipboard backend found; install wl-copy or xclip, "
        "or run this helper from a desktop session with WAYLAND_DISPLAY/DISPLAY",
        file=sys.stderr,
    )
    return 127


def forward_to_daemon(path: Path, mime_type: str, socket_path: Path) -> int:
    payload = json.dumps({"path": str(path), "mime": mime_type}).encode("utf-8") + b"\n"
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(5)
        with client:
            client.connect(str(socket_path))
            client.sendall(payload)
            response = client.recv(4096)
    except OSError as exc:
        print(f"remote clipboard daemon unavailable: {exc}", file=sys.stderr)
        return 125

    try:
        result = json.loads(response.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        print("remote clipboard daemon returned an invalid response", file=sys.stderr)
        return 126

    if result.get("ok") is True:
        return 0
    print(result.get("error") or "remote clipboard daemon failed", file=sys.stderr)
    return int(result.get("code") or 1)


def run_daemon(socket_path: Path) -> int:
    socket_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if socket_path.exists():
        socket_path.unlink()

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    with server:
        server.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        server.listen(8)
        print(f"ssh-image-paste remote daemon listening on {socket_path}", file=sys.stderr)
        while True:
            connection, _ = server.accept()
            with connection:
                response = handle_daemon_connection(connection)
                connection.sendall(json.dumps(response).encode("utf-8") + b"\n")


def handle_daemon_connection(connection: socket.socket) -> dict[str, object]:
    try:
        data = b""
        while not data.endswith(b"\n") and len(data) < 8192:
            chunk = connection.recv(8192 - len(data))
            if not chunk:
                break
            data += chunk

        request = json.loads(data.decode("utf-8"))
        path = Path(str(request["path"]))
        mime = str(request.get("mime") or "image/png")
        code = direct_write_image(path, mime)
        if code == 0:
            return {"ok": True}
        return {"ok": False, "code": code, "error": f"clipboard backend exited {code}"}
    except Exception as exc:  # noqa: BLE001 - this is a daemon boundary.
        return {"ok": False, "code": 1, "error": str(exc)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    write_parser = subparsers.add_parser("write-image")
    write_parser.add_argument("path")
    write_parser.add_argument("--mime", default="image/png")
    write_parser.add_argument("--socket", default=None)

    daemon_parser = subparsers.add_parser("daemon")
    daemon_parser.add_argument("--socket", default=None)

    args = parser.parse_args(argv)
    if args.command == "write-image":
        socket_path = Path(args.socket) if args.socket else None
        return write_image(Path(args.path), args.mime, socket_path)
    if args.command == "daemon":
        socket_path = Path(args.socket) if args.socket else default_socket_path()
        return run_daemon(socket_path)

    parser.error(f"unknown command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
