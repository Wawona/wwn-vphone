#!/usr/bin/env python3
"""One-line Unix-socket client for a live vphone-cli 2.6 guest.

Agents use this instead of a new Python blob each turn. The VM must already
be launched (visible window). Never call `vphone-cli vm launch` from here.

  vphone-sock ping
  vphone-sock unlock
  vphone-sock screenshot /tmp/guest.png
  vphone-sock launch wiki.qaq.irisin
  vphone-sock open-url 'irisin://repository/add?url=https%3A%2F%2Frepo.wawona.io%2F'
  vphone-sock ls /var/jb/usr/bin
  vphone-sock write /var/jb/etc/apt/sources.list.d/wawona.list ./wawona.list
  vphone-sock rpc apps.list
  vphone-sock tap 215 880 --points
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path

DEFAULT_VM = os.environ.get("VPHONE_VM_NAME", "wawona-jb")
DEFAULT_ROOT = Path(os.environ.get("VPHONE_ROOT", Path.home() / ".vphone"))


def sock_path(vm: str) -> Path:
    return DEFAULT_ROOT / "machines" / vm / "vphone.sock"


def send(path: Path, obj: dict, timeout: float) -> dict:
    payload = (json.dumps(obj) + "\n").encode()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect(str(path))
        sock.sendall(payload)
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    finally:
        sock.close()
    if not buf:
        raise SystemExit(f"empty sock reply for {obj.get('t') or obj.get('method')}")
    data = json.loads(buf.split(b"\n", 1)[0])
    data.pop("image", None)
    return data


def rpc(path: Path, method: str, params: dict, timeout: float) -> dict:
    return send(
        path,
        {"t": "rpc", "method": method, "params": params, "screen": False},
        timeout,
    )


def dump(data: dict) -> int:
    print(json.dumps(data, indent=2, sort_keys=True))
    if data.get("ok") is False:
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument("--vm", default=DEFAULT_VM)
    parser.add_argument("--timeout", type=float, default=40.0)
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("ping")
    sub.add_parser("unlock")
    sub.add_parser("tree")
    sub.add_parser("screen")
    sub.add_parser("foreground")
    p_shot = sub.add_parser("screenshot")
    p_shot.add_argument("path")
    p_launch = sub.add_parser("launch")
    p_launch.add_argument("bundle_id")
    p_url = sub.add_parser("open-url")
    p_url.add_argument("url")
    p_ls = sub.add_parser("ls")
    p_ls.add_argument("path")
    p_read = sub.add_parser("read")
    p_read.add_argument("path")
    p_write = sub.add_parser("write")
    p_write.add_argument("guest_path")
    p_write.add_argument("host_path", help="local file, or - for stdin")
    p_mkdir = sub.add_parser("mkdir")
    p_mkdir.add_argument("path")
    p_tap = sub.add_parser("tap")
    p_tap.add_argument("x", type=float)
    p_tap.add_argument("y", type=float)
    p_tap.add_argument(
        "--points",
        action="store_true",
        help="multiply by device.screen.scale (ui.tree frames are points)",
    )
    p_lp = sub.add_parser("longpress")
    p_lp.add_argument("x", type=float)
    p_lp.add_argument("y", type=float)
    p_lp.add_argument(
        "--seconds",
        type=float,
        default=1.5,
        help="hold duration for input.long_press (screen points)",
    )
    p_lp.add_argument(
        "--pixels",
        action="store_true",
        help="coords are pixels; divide by device.screen.scale for input.long_press",
    )
    p_rpc = sub.add_parser("rpc")
    p_rpc.add_argument("method")
    p_rpc.add_argument("params_json", nargs="?", default="{}")

    args = parser.parse_args()
    path = sock_path(args.vm)
    if not path.exists():
        print(f"missing sock {path}. Recover with skill wawona-vphone-lab-recover.", file=sys.stderr)
        return 2

    t = args.timeout
    if args.cmd == "ping":
        return dump(send(path, {"t": "ping", "screen": False}, min(t, 8)))
    if args.cmd == "unlock":
        return dump(rpc(path, "screen.unlock", {"timeout": int(t)}, max(t, 25)))
    if args.cmd == "tree":
        return dump(rpc(path, "ui.tree", {"max_elements": 200, "visible_only": True}, t))
    if args.cmd == "screen":
        return dump(rpc(path, "device.screen", {}, t))
    if args.cmd == "foreground":
        return dump(rpc(path, "apps.foreground", {}, t))
    if args.cmd == "screenshot":
        return dump(send(path, {"t": "screenshot", "path": args.path, "screen": False}, t))
    if args.cmd == "launch":
        return dump(rpc(path, "apps.launch", {"bundle_id": args.bundle_id}, t))
    if args.cmd == "open-url":
        return dump(rpc(path, "apps.open_url", {"url": args.url}, t))
    if args.cmd == "ls":
        return dump(rpc(path, "files.list", {"path": args.path}, t))
    if args.cmd == "read":
        return dump(rpc(path, "files.read", {"path": args.path}, t))
    if args.cmd == "mkdir":
        return dump(rpc(path, "files.mkdir", {"path": args.path}, t))
    if args.cmd == "write":
        if args.host_path == "-":
            content = sys.stdin.buffer.read()
        else:
            content = Path(args.host_path).read_bytes()
        import base64

        return dump(
            rpc(
                path,
                "files.write",
                {
                    "path": args.guest_path,
                    "content": base64.b64encode(content).decode("ascii"),
                    "encoding": "base64",
                },
                t,
            )
        )
    if args.cmd == "tap":
        x, y = args.x, args.y
        if args.points:
            scale = float((rpc(path, "device.screen", {}, 15).get("result") or {}).get("scale") or 3)
            x, y = x * scale, y * scale
        return dump(send(path, {"t": "tap", "x": int(x), "y": int(y), "screen": False}, t))
    if args.cmd == "longpress":
        # input.long_press uses screen points (unlike sock tap pixels).
        x, y = args.x, args.y
        if args.pixels:
            scale = float((rpc(path, "device.screen", {}, 15).get("result") or {}).get("scale") or 3)
            x, y = x / scale, y / scale
        return dump(
            rpc(
                path,
                "input.long_press",
                {"x": float(x), "y": float(y), "seconds": float(args.seconds)},
                t,
            )
        )
    if args.cmd == "rpc":
        try:
            params = json.loads(args.params_json)
        except json.JSONDecodeError as exc:
            print(f"params JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(params, dict):
            print("params must be a JSON object", file=sys.stderr)
            return 2
        return dump(rpc(path, args.method, params, t))
    return 2


if __name__ == "__main__":
    sys.exit(main())
