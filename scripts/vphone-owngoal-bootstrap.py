#!/usr/bin/env python3
"""Drive Irisin OwnGoal Bootstrap Install on a live vphone guest.

Prereq: Irisin already planted (`bootstrap.install`). VM already running.
Never calls `vm launch`. Recovery for a failed first pass is
`bootstrap.uninstall` then `bootstrap.install`, then this script.

  python3 scripts/vphone-owngoal-bootstrap.py
  python3 scripts/vphone-owngoal-bootstrap.py --wipe   # uninstall+replant first
"""
from __future__ import annotations

import argparse
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

SOCK = Path(__file__).resolve().parent / "vphone-sock.py"


def run(*args: str, timeout: float = 40) -> dict:
    p = subprocess.run(
        [sys.executable, str(SOCK), "--timeout", str(timeout), *args],
        capture_output=True,
        text=True,
    )
    try:
        return json.loads(p.stdout, strict=False)
    except Exception:
        print(p.stdout or p.stderr, file=sys.stderr)
        return {"ok": False, "error": "bad sock reply"}


def rpc(method: str, params: dict | None = None, timeout: float = 40) -> dict:
    args = ["rpc", method]
    if params is not None:
        args.append(json.dumps(params))
    return run(*args, timeout=timeout)


def tree(timeout: float = 20) -> list[tuple[str, dict]]:
    d = run("tree", timeout=timeout)
    els = (d.get("result") or {}).get("elements") or []
    return [((e.get("text") or e.get("label") or ""), e.get("frame") or {}) for e in els]


def wait_label(pred, tries: int = 30, sleep_s: float = 2.0) -> list[tuple[str, dict]]:
    labs: list[tuple[str, dict]] = []
    for _ in range(tries):
        labs = tree()
        texts = [t for t, _ in labs]
        if pred(texts):
            return labs
        time.sleep(sleep_s)
    return labs


def guest_ip() -> str:
    d = rpc("device.network")
    for a in (d.get("result") or {}).get("addresses") or []:
        if a.startswith("en0 ") and "192.168." in a:
            return a.split()[-1]
    return "192.168.64.251"


def ssh_open(host: str, port: int = 22222) -> bool:
    s = socket.socket()
    s.settimeout(2)
    try:
        s.connect((host, port))
        s.close()
        return True
    except OSError:
        return False


def ensure_procursus() -> None:
    """Procursus needs suite+component. Flat URL is Unreachable."""
    run("open-url", "irisin://repository/add?url=https%3A%2F%2Fapt.procurs.us%2F")
    time.sleep(2)
    labs = tree()
    texts = [t for t, _ in labs]
    if any("Procursus" in t and "Already" not in t for t in texts) and any(
        "Repositories:" in t for t in texts
    ):
        return
    if "Add Advanced Source" not in texts and "Advanced Source" not in texts:
        # may already be on Repositories list
        if any(t.startswith("Procursus") for t in texts):
            return
        run("open-url", "irisin://repository/add?url=https%3A%2F%2Fapt.procurs.us%2F")
        time.sleep(2)
        labs = tree()
        texts = [t for t, _ in labs]
    if "Add Advanced Source" in texts:
        rpc("ui.tap_element", {"text": "Add Advanced Source", "match": "contains"})
        time.sleep(1)

        def fill(x: float, y: float, text: str) -> None:
            rpc("input.tap", {"x": x, "y": y})
            rpc("clipboard.set", {"text": text})
            rpc("input.key", {"name": "cmd+a"})
            rpc("input.key", {"name": "cmd+v"})

        fill(215, 210, "https://apt.procurs.us/")
        fill(215, 318, "3000")
        fill(215, 454, "main")
        rpc("input.key", {"name": "return"})
        rpc("input.tap", {"x": 372, "y": 484})
        time.sleep(2)


def bootstrap_install() -> None:
    run("open-url", "irisin://package/owngoal-bootstrap-vphone")
    time.sleep(2)
    labs = wait_label(lambda t: "INSTALL" in t or "OPEN QUEUE" in t or "Execute" in t)
    texts = [t for t, _ in labs]
    if "Execute" in texts:
        pass
    elif "OPEN QUEUE" in texts:
        rpc("ui.tap_element", {"text": "OPEN QUEUE", "match": "contains"})
        time.sleep(2)
    else:
        rpc("ui.tap_element", {"text": "INSTALL", "match": "contains"})
        labs = wait_label(
            lambda t: "Confirm" in t and "In progress" not in "".join(t) and "Empty list" not in "".join(t),
            tries=40,
            sleep_s=2,
        )
        if any(t == "Confirm" for t, _ in labs):
            rpc("ui.tap_element", {"text": "Confirm", "match": "contains"})
            time.sleep(2)
        labs = wait_label(lambda t: "OPEN QUEUE" in t or "Execute" in t or "Queue" in t)
        if any("OPEN QUEUE" in t for t, _ in labs):
            rpc("ui.tap_element", {"text": "OPEN QUEUE", "match": "contains"})
            time.sleep(2)
        elif any(t == "Queue" for t, _ in labs):
            rpc("ui.tap_element", {"text": "Queue", "match": "contains"})
            time.sleep(2)

    labs = wait_label(lambda t: "Execute" in t, tries=20)
    frames = [f for t, f in labs if t == "Execute"]
    if not frames:
        raise SystemExit("Queue Execute button not found")
    f = frames[0]
    x = f["x"] + f["width"] / 2
    y = f["y"] + f["height"] / 2
    run("longpress", str(x), str(y), "--seconds", "1.8")
    time.sleep(1)
    labs = tree()
    if not any("Bootstrap Install" in t for t, _ in labs):
        raise SystemExit("Bootstrap Install menu missing after long-press Execute")
    rpc("ui.tap_element", {"text": "Bootstrap Install", "match": "contains"})


def wait_done(timeout: float = 720) -> int:
    """First Bootstrap Install often unpacks then fails configure (no jb sh yet).

    On Irisin Failed, tap the bottom **Try Again** button by label equality.
    Never match Done's value text ("Operation failed. Try again.").
    """
    ip = guest_ip()
    start = time.time()
    tried_again = False
    while time.time() - start < timeout:
        procs = rpc("processes.list", {"filter": "irisin"})
        names = [p.get("name") for p in ((procs.get("result") or {}).get("processes") or [])]
        installing = "irisin-install" in names
        st = run("read", "/var/jb/Library/dpkg/status", timeout=60)
        text = (st.get("result") or {}).get("content") or ""
        pkgs = {}
        for block in text.split("\n\n"):
            name = status = None
            for ln in block.splitlines():
                if ln.startswith("Package:"):
                    name = ln.split(":", 1)[1].strip()
                if ln.startswith("Status:"):
                    status = ln.split(":", 1)[1].strip()
            if name:
                pkgs[name] = status
        unpacked = sum(1 for s in pkgs.values() if s and "unpacked" in s)
        ok = all(pkgs.get(p) == "install ok installed" for p in ("apt", "dpkg", "bash"))
        print(
            f"t={int(time.time()-start)}s installing={installing} pkgs={len(pkgs)} "
            f"unpacked={unpacked} apt={pkgs.get('apt')} ssh={ssh_open(ip)}",
            flush=True,
        )
        if not installing and ok and unpacked == 0:
            print("SUCCESS")
            return 0
        if not installing:
            labs = tree(timeout=15)
            texts = [t for t, _ in labs]
            if "Try Again" in texts and not tried_again:
                # Exact label only. Done.value also contains "Try again".
                frames = [f for t, f in labs if t == "Try Again"]
                if frames:
                    f = frames[0]
                    x = f["x"] + f["width"] / 2
                    y = f["y"] + f["height"] / 2
                    print(f"TRY_AGAIN tap points {x},{y}", flush=True)
                    rpc("input.tap", {"x": x, "y": y})
                    tried_again = True
                    time.sleep(3)
                    continue
            if any(t == "Failed" for t in texts) and tried_again:
                print("FAILED_AFTER_RETRY", texts[:20])
                return 1
        time.sleep(12)
    print("TIMEOUT")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--wipe", action="store_true", help="bootstrap.uninstall + install first")
    ap.add_argument("--layout", default="rootless", choices=("rootless", "roothide"))
    args = ap.parse_args()

    if run("ping").get("ok") is not True:
        print("guest sock dead. Recover with wawona-vphone-lab-recover.", file=sys.stderr)
        return 2
    run("unlock", timeout=40)
    rpc("settings.set", {
        "domain": "com.apple.springboard",
        "key": "SBAutoLockTime",
        "value": 2147483647,
    })

    if args.wipe:
        insp = rpc("bootstrap.inspect")
        roots = (insp.get("result") or {}).get("roots") or []
        if roots:
            print("uninstall", roots)
            rpc("bootstrap.uninstall", {"roots": roots, "force": True}, timeout=180)
            for _ in range(60):
                if run("ping", timeout=8).get("ok") and rpc("bootstrap.inspect").get("ok"):
                    break
                time.sleep(5)
            run("unlock", timeout=40)
        print("bootstrap.install", args.layout)
        print(rpc("bootstrap.install", {"layout": args.layout}, timeout=300))

    launch = run("launch", "wiki.qaq.irisin")
    if launch.get("ok") is not True:
        # bootstrap.inspect can say installed while Applications is gone.
        print("Irisin missing; bootstrap.install", args.layout)
        print(rpc("bootstrap.install", {"layout": args.layout}, timeout=300))
        rpc("apps.refresh", {})
        launch = run("launch", "wiki.qaq.irisin")
        if launch.get("ok") is not True:
            print("Irisin still missing", launch, file=sys.stderr)
            return 2
    time.sleep(2)
    ensure_procursus()
    run("launch", "wiki.qaq.irisin")
    bootstrap_install()
    return wait_done()


if __name__ == "__main__":
    sys.exit(main())
