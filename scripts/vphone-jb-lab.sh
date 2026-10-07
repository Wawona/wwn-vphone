#!/usr/bin/env bash
# vphone-jb-lab.sh: one-shot jailbroken iOS VM for Wawona Mode B proof.
#
# Automates: host gate → vphone-cli ensure → create/restore/CFW(jb) → launch
# → setup.skip → Irisin bootstrap → Wawona APT source (Irisin URL + apt list)
# → wait SSH → apt-get update → verify Sileo + TrollStore Lite.
#
# Operator owns Recovery/nvram. This script never flips csrutil/nvram.
#
# Usage (via nix):
#   nix run github:Wawona/wwn-vphone#vphone-jb-lab
#   nix run github:Wawona/wwn-vphone#vphone-jb-lab -- --smoke-only
#   nix run github:Wawona/wwn-vphone#vphone-jb-lab -- --gate-only
#   nix run github:Wawona/wwn-vphone#vphone-ipad-lab
#   nix run .#vphone-jb-lab   # from a Wawona or wwn-vphone checkout
#   nix run .#vphone-jb-lab -- --ipad
#
# Never commits or ships Disk.img / IPSW. Follows upstream vphone-cli create/CFW.
#
# Env:
#   VPHONE_ROOT          default ~/.vphone
#   VPHONE_VM_NAME       default wawona-jb
#   VPHONE_DISK_GB       default 32
#   VPHONE_IOS_URL       optional iPhone IPSW URL (default: catalog iOS 26.1)
#   VPHONE_CLOUDOS_URL   optional cloudOS URL (default: catalog cloudOS 26.1)
#   VPHONE_ARTIFACTS     default ~/.vphone/artifacts/vphone-jb (or WAWONA_ROOT/.agent-device/…)
set -euo pipefail

ROOT="${VPHONE_ROOT:-$HOME/.vphone}"
VM_NAME="${VPHONE_VM_NAME:-wawona-jb}"
DISK_GB="${VPHONE_DISK_GB:-32}"
SRC="$ROOT/src/vphone-cli"
# vphone-cli 2.x library. 1.x disks live in $ROOT/VMs and do not boot.
VM_DIR="$ROOT/machines/$VM_NAME"
BUNDLE_CLI="$ROOT/bundles/2.6.0/VPhone.bundle/Contents/MacOS/vphone-cli"
# Artifacts: prefer an explicit path, then a Wawona checkout, then ~/.vphone.
if [[ -n "${VPHONE_ARTIFACTS:-}" ]]; then
  ART="$VPHONE_ARTIFACTS"
elif [[ -n "${WAWONA_ROOT:-}" ]]; then
  ART="$WAWONA_ROOT/.agent-device/test-artifacts/dmabuf/vphone-jb"
elif [[ -d "$PWD/.agent-device" || -f "$PWD/flake.nix" ]]; then
  ART="$PWD/.agent-device/test-artifacts/dmabuf/vphone-jb"
else
  ART="$ROOT/artifacts/vphone-jb"
fi
mkdir -p "$ART" "$ROOT"

# Catalog pairing: iOS 26.1 ↔ cloudOS 26.1 (iPhone17,3). Override via env.
IPHONE_URL="${VPHONE_IOS_URL:-https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw}"
CLOUDOS_URL="${VPHONE_CLOUDOS_URL:-https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349}"

SMOKE_ONLY=0
GATE_ONLY=0
CREATE_FORCE=0
IPAD=0
# Irisin + Wawona APT source are required, same class as setup.skip.
BOOTSTRAP=1
for arg in "$@"; do
  case "$arg" in
    --smoke-only) SMOKE_ONLY=1 ;;
    --gate-only) GATE_ONLY=1 ;;
    --force-create) CREATE_FORCE=1 ;;
    --ipad) IPAD=1 ;;
    --bootstrap) BOOTSTRAP=1; BOOTSTRAP_SET=1 ;;
    --no-bootstrap) BOOTSTRAP=0; BOOTSTRAP_SET=1 ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# iPadOS uses an iPad restore IPSW plus the same cloudOS as the iPhone lab.
# iPad16,1 is the iPad mini (A17 Pro), iPadOS 26.1 build 23B85.
if [[ "$IPAD" == 1 && -z "${VPHONE_VM_NAME:-}" ]]; then
  VM_NAME=wawona-ipad
fi
if [[ "$IPAD" == 1 && -z "${BOOTSTRAP_SET:-}" ]]; then
  BOOTSTRAP=1
fi
VM_DIR="$ROOT/machines/$VM_NAME"
if [[ "$IPAD" == 1 ]]; then
  DEVICE_TYPE="${VPHONE_DEVICE:-iPad16,1}"
  API_PORT="${VPHONE_API_PORT:-8766}"
  if [[ -z "${VPHONE_IOS_URL:-}" ]]; then
    IPHONE_URL="https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-12753/0AC11D64-550A-4C49-A257-7EC00EE9551A/iPad16,1,iPad16,2_26.1_23B85_Restore.ipsw"
  fi
  if [[ -z "${VPHONE_ARTIFACTS:-}" ]]; then
    ART="$ROOT/artifacts/vphone-ipad"
    mkdir -p "$ART"
  fi
else
  DEVICE_TYPE="${VPHONE_DEVICE:-}"
  API_PORT="${VPHONE_API_PORT:-8765}"
fi

log() { printf '[vphone-jb-lab] %s\n' "$*"; }
die() { printf '[vphone-jb-lab] ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# ── Host gate (never mutate Recovery / nvram) ───────────────────
check_gate() {
  local sip research args arch nested
  arch="$(uname -m)"
  [[ "$arch" == "arm64" ]] || die "Apple Silicon required (got $arch)"

  nested="$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)"
  [[ "$nested" == "0" ]] || die "host is nested (kern.hv_vmm_present=$nested); PV=3 cannot nest"

  sip="$(csrutil status 2>/dev/null || true)"
  echo "$sip" | grep -qi 'status: disabled' \
    || die "SIP must be fully disabled (csrutil disable in Recovery). Got: $sip"

  research="$(csrutil allow-research-guests status </dev/null 2>/dev/null || true)"
  echo "$research" | grep -qi 'status: enabled' \
    || die "allow-research-guests must be enabled (Recovery: csrutil allow-research-guests enable). Got: $research"

  # /usr/sbin is not on the nix app PATH.
  args="$(/usr/sbin/nvram boot-args 2>/dev/null || true)"
  echo "$args" | grep -q 'amfi_get_out_of_my_way=1' \
    || die "nvram boot-args must include amfi_get_out_of_my_way=1 (operator sets after SIP off)"

  # Optional: warn if sysctl lagging after research-guests enable (reboot usually fixes).
  local sr
  sr="$(sysctl -n hw.features.allows_security_research 2>/dev/null || echo '?')"
  if [[ "$sr" != "1" ]]; then
    log "warn: hw.features.allows_security_research=$sr (research-guests text says enabled; reboot if DFU start fails)"
  fi

  local free_g
  # Prefer BSD df (-g); nix runtimeInputs may put GNU df first.
  if free_g="$(/bin/df -g / 2>/dev/null | awk 'NR==2{print $4}')"; then
    :
  else
    free_g="$(df -BG / 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}')"
  fi
  if [[ -n "$free_g" && "$free_g" =~ ^[0-9]+$ && "$free_g" -lt 40 ]]; then
    log "warn: only ${free_g}G free on /; prefer ≥64G (128G+ for cold IPSW create)"
  fi

  {
    echo "=== host-gate $(date) ==="
    echo "$sip"
    echo "$research"
    echo "boot-args: $args"
    echo "allows_security_research: $sr"
    echo "free_g: ${free_g:-unknown}"
  } | tee "$ART/host-gate.txt" >/dev/null

  log "host gate OK"
}

# ── Resolve vphone-cli ──────────────────────────────────────────
resolve_vphone() {
  if [[ -n "${VPHONE_CLI:-}" && -x "$VPHONE_CLI" ]]; then
    VPHONE="$VPHONE_CLI"
  elif [[ -x "$BUNDLE_CLI" ]]; then
    VPHONE="$BUNDLE_CLI"
  elif command -v vphone-cli >/dev/null 2>&1; then
    VPHONE="$(command -v vphone-cli)"
  elif [[ -x "$SRC/.build/release/vphone-cli" ]]; then
    VPHONE="$SRC/.build/release/vphone-cli"
  elif [[ -x "$SRC/.build/vphone-cli.app/Contents/MacOS/vphone-cli" ]]; then
    VPHONE="$SRC/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
  else
    die "vphone-cli not on PATH; run via: nix run github:Wawona/wwn-vphone#vphone-jb-lab"
  fi
  log "vphone-cli: $VPHONE"
  PATH="$(dirname "$VPHONE"):${PATH}"
  export PATH
  if [[ -x "$SRC/.venv/bin/python3" ]]; then
    export VPHONE_PYTHON="$SRC/.venv/bin/python3"
  fi
}

# Apply Wawona accessibility_tree sources into the local vphone-cli tree
# before CFW / launch so guest vphoned can emit snapshot -i @eN nodes.
apply_vphoned_ax() {
  local here patches apply
  # 2.x vphoned already walks AX (ui.tree / accessibility.tree on vphone.sock).
  # The 1.x overlay targets scripts/vphoned, which the release bundle does not have.
  if [[ "$VPHONE" == *"/VPhone.bundle/"* ]]; then
    log "vphone 2.x bundle: guest AX is ui.tree; skip 1.x vphoned overlay"
    return 0
  fi
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -n "${VPHONE_PATCHES:-}" && -d "$VPHONE_PATCHES" ]]; then
    patches="$VPHONE_PATCHES"
  elif [[ -d "$here/../patches" ]]; then
    patches="$here/../patches"
  elif [[ -d "$here/patches" ]]; then
    patches="$here/patches"
  else
    log "warn: vphoned AX patches not found (set VPHONE_PATCHES); guest AX stays icon-grid"
    return 0
  fi
  apply="$patches/apply-vphoned-ax.sh"
  if [[ ! -x "$apply" && -f "$apply" ]]; then
    chmod +x "$apply" 2>/dev/null || true
  fi
  if [[ -x "$apply" || -f "$apply" ]]; then
    bash "$apply" "$SRC" || log "warn: apply-vphoned-ax failed (guest AX may stay icon-grid)"
  fi
}

# Run under a pseudo-TTY so CFW sudo can use NOPASSWD without --sudo-password
# (sudo -A / askpass fails when NOPASSWD is set but askpass returns a dummy).
with_tty() {
  if [[ -t 0 ]]; then
    "$@"
  else
    script -q /dev/null "$@"
  fi
}

schema_ok() {
  [[ -f "$VM_DIR/config.plist" ]] || return 1
  local v
  v="$(/usr/bin/plutil -extract schemaVersion raw "$VM_DIR/config.plist" 2>/dev/null || echo 0)"
  [[ "$v" == "2" ]]
}

vm_exists() { [[ -f "$VM_DIR/Disk.img" ]] && schema_ok; }

cfw_done() {
  # 2.x `vm create` installs CFW and writes schemaVersion 2. There is no -V jb.
  vm_exists
}

guest_ips() {
  # Prefer live iPhone DHCP leases; fall back to scanning the VZ NAT range.
  local ips
  ips="$(awk '
    /name=iPhone/ { want=1; next }
    want && /ip_address=/ {
      gsub(/ip_address=|;/, "", $1); print $1; want=0
    }
  ' /var/db/dhcpd_leases 2>/dev/null || true)"
  if [[ -n "$ips" ]]; then
    printf '%s\n' "$ips"
  else
    # VZ NAT often assigns mid/high .64.x; cover the common lease range.
    printf '%s\n' 192.168.64.{2..120}
  fi
}

ssh_ready() {
  local ip port=22222
  for ip in $(guest_ips); do
    if nc -z -G 1 "$ip" "$port" 2>/dev/null; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

# SSH to guest: lab credentials via sshpass. Never interactive askpass
# (nix OpenSSH sets SSH_ASKPASS to a missing binary). Guest dropbear rejects
# pubkey today; password alpine is the paired lab auth.
guest_ssh() {
  local ip="$1"
  shift
  env -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE -u DISPLAY SSH_ASKPASS_REQUIRE=never \
    sshpass -p alpine ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts=1 \
      -o ConnectTimeout=15 \
      -p 22222 "mobile@$ip" "$@"
}

# Auto-lock Must Be Off for agent-device / tipa demos. Otherwise SpringBoard
# locks mid-run and sock taps hit the lock screen. Idempotent bootstrap step.
disable_autolock() {
  local ip="$1"
  local plist_host="$ART/springboard-nolock.plist"
  local b64
  log "disabling guest auto-lock (SBAutoLockTime=0)…"
  cat >"$ART/springboard-minimal.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>SBAutoLockTime</key>
  <integer>0</integer>
  <key>SBAutoLockDisabled</key>
  <true/>
</dict>
</plist>
XML
  if command -v plutil >/dev/null 2>&1; then
    /usr/bin/plutil -convert binary1 "$ART/springboard-minimal.xml" -o "$plist_host"
  else
    cp "$ART/springboard-minimal.xml" "$plist_host"
  fi
  b64="$(/usr/bin/base64 -i "$plist_host" 2>/dev/null | tr -d '\n' || base64 <"$plist_host" | tr -d '\n')"
  # Merge via defaults when available; always stamp the two keys; never leave a 0-byte plist.
  guest_ssh "$ip" "export PATH=\"/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:\$PATH\"
    set -e
    # Ensure Procursus defaults exists (best path for future boots).
    if ! command -v defaults >/dev/null 2>&1; then
      echo alpine | sudo -S apt-get install -y defaults >/dev/null 2>&1 || true
    fi
    if command -v defaults >/dev/null 2>&1; then
      defaults write com.apple.springboard SBAutoLockTime -int 0
      defaults write com.apple.springboard SBAutoLockDisabled -bool true
    else
      printf '%s' '$b64' | base64 -d > /var/mobile/Library/Preferences/com.apple.springboard.plist.tmp
      sz=\$(wc -c < /var/mobile/Library/Preferences/com.apple.springboard.plist.tmp | tr -d ' ')
      if [[ \"\$sz\" -lt 20 ]]; then
        echo 'autolock plist too small; abort' >&2
        exit 12
      fi
      mv /var/mobile/Library/Preferences/com.apple.springboard.plist.tmp \\
         /var/mobile/Library/Preferences/com.apple.springboard.plist
      chmod 600 /var/mobile/Library/Preferences/com.apple.springboard.plist
    fi
    killall -9 SpringBoard 2>/dev/null || true
    sleep 2
    if command -v defaults >/dev/null 2>&1; then
      echo \"SBAutoLockTime=\$(defaults read com.apple.springboard SBAutoLockTime 2>/dev/null || echo ?)\"
      echo \"SBAutoLockDisabled=\$(defaults read com.apple.springboard SBAutoLockDisabled 2>/dev/null || echo ?)\"
    fi
    echo autolock=never
  " 2>&1 | tee "$ART/autolock.txt"
  grep -q 'autolock=never' "$ART/autolock.txt" || die "failed to disable guest auto-lock"
  log "guest auto-lock disabled"
}

# Procursus debugserver for agent-device `packages debug attach` → user-lldb.
# Physical iOS uses Xcode DDI debugserver over lockdown; vphone-jb uses apt.
# Same package Theos / Procursus device debugging already expects.
ensure_debugserver() {
  local ip="$1"
  log "ensuring guest Procursus debugserver (apt)…"
  # shellcheck disable=SC2016
  guest_ssh "$ip" '
      export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:$PATH"
      set -e
      if command -v debugserver >/dev/null 2>&1; then
        echo "debugserver=present path=$(command -v debugserver)"
        exit 0
      fi
      echo alpine | sudo -S -p "" apt-get update -qq || true
      echo alpine | sudo -S -p "" apt-get install -y debugserver
      command -v debugserver >/dev/null
      echo "debugserver=installed path=$(command -v debugserver)"
    ' 2>&1 | tee "$ART/debugserver.txt"
  grep -q 'debugserver=' "$ART/debugserver.txt" || die "failed to install guest debugserver"
  log "guest debugserver ready"
}

launch_vm() {
  if pgrep -f "${VM_DIR}/config.plist" >/dev/null 2>&1; then
    log "VM already running"
    return 0
  fi
  log "launching $VM_NAME (vphone 2.x, visible window, API on 127.0.0.1:${API_PORT})..."
  # Keep display awake so the GUI VM is less likely to power-gate.
  caffeinate -dims -t 7200 >/dev/null 2>&1 &
  # No -V jb and no -p project root. Those are 1.x flags. 2.x rejects them.
  # VPHONE_API_TOKEN makes the guest HTTP token stable for tipa upload.
  nohup env VPHONE_API_TOKEN="${VPHONE_API_TOKEN:-}" "$VPHONE" vm launch "$VM_NAME" \
    --api-listen "127.0.0.1:${API_PORT}" -v \
    >"$ART/launch.serial" 2>&1 &
  echo $! >"$ART/launch.pid"
  disown || true
  sleep 3
}

wait_sock() {
  local timeout="${1:-240}" waited=0
  log "waiting for vphoned ping on $VM_DIR/vphone.sock (timeout=${timeout}s)"
  while (( waited < timeout )); do
    if [[ -S "$VM_DIR/vphone.sock" ]]; then
      if printf '%s\n' '{"t":"ping","screen":false}' | nc -U "$VM_DIR/vphone.sock" 2>/dev/null | grep -q '"ok":true'; then
        log "vphoned ping ok"
        return 0
      fi
    fi
    sleep 5
    waited=$((waited + 5))
  done
  return 1
}

# Fresh guests boot into Setup.app. setup.skip writes the three purplebuddy
# keys through cfprefsd and resprings. Tapping the language list does not.
# screen.unlock then passes the Lock Screen. ui.tree still needs a launched
# app: SpringBoard on the Home Screen is not a verified frontmost process.
skip_setup() {
  log "checking Setup Assistant (setup.status)"
  /usr/bin/python3 - "$VM_DIR/vphone.sock" "$ART" <<'PY' || return 1
import json, socket, sys
sock_path, art = sys.argv[1], sys.argv[2]

def rpc(method, params, timeout=30):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps({"t": "rpc", "method": method, "params": params, "screen": False}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    line = buf.split(b"\n", 1)[0]
    if not line:
        raise SystemExit("empty sock reply for " + method)
    data = json.loads(line)
    if data.get("ok") is False:
        raise SystemExit(method + " failed: " + str(data.get("error")))
    return data

never = 2147483647
for key in ("SBAutoLockTime", "SBMinimumLockscreenIdleTime"):
    rpc("settings.set", {
        "domain": "com.apple.springboard",
        "key": key,
        "value": never,
        "type": "int",
    })
rpc("settings.set", {
    "domain": "com.apple.springboard",
    "key": "SBAutoLockDisabled",
    "value": True,
    "type": "bool",
})
print("auto-lock set to never")
status = rpc("setup.status", {})
result = status.get("result") or {}
print("setup.status pending=%s running=%s done=%s" % (
    result.get("pending"), result.get("running"), result.get("setup_done")))
if result.get("pending") or result.get("running"):
    skipped = rpc("setup.skip", {"force": True}, timeout=120)
    open(art + "/setup-skip.json", "w").write(json.dumps(skipped))
    done = skipped.get("result") or {}
    print("setup.skip pending=%s done=%s version=%s" % (
        done.get("pending"), done.get("setup_done"), done.get("setup_version")))
screen = rpc("device.screen", {})
view = screen.get("result") or {}
if view.get("locked") or view.get("screen_off"):
    unlocked = rpc("screen.unlock", {"timeout": 20}, timeout=45)
    open(art + "/screen-unlock.json", "w").write(json.dumps(unlocked))
    print("screen.unlock", (unlocked.get("result") or {}).get("locked"))
PY
  wait_sock 120 || log "warn: sock quiet after setup.skip"
}

ensure_api_token() {
  if [[ -z "${API_TOKEN:-}" && -f "$ART/api-token" ]]; then
    API_TOKEN="$(tr -d '\n' <"$ART/api-token")"
  fi
  if [[ -z "${API_TOKEN:-}" ]]; then
    API_TOKEN="$(/usr/bin/python3 -c 'import secrets; print(secrets.token_hex(16))')"
    printf '%s\n' "$API_TOKEN" >"$ART/api-token"
    chmod 600 "$ART/api-token"
  fi
  export VPHONE_API_TOKEN="$API_TOKEN"
  API_URL="http://127.0.0.1:${API_PORT}"
}

harvest_api() {
  local url token
  url="$(grep 'HTTP/WebSocket API:' "$ART/launch.serial" 2>/dev/null | tail -1 | sed 's/.*API: //' || true)"
  token="$(grep '\[api\] token:' "$ART/launch.serial" 2>/dev/null | tail -1 | sed 's/.*token: //' || true)"
  if [[ -n "$url" ]]; then API_URL="$url"; fi
  if [[ -n "$token" ]]; then API_TOKEN="$token"; fi
  if [[ -n "${API_URL:-}" && -n "${API_TOKEN:-}" ]]; then
    log "guest API $API_URL"
  else
    log "warn: API url/token not in $ART/launch.serial yet"
  fi
}

# Rootless (/var/jb) is the Wawona Sileo deb layout (iphoneos-arm64).
# bootstrap.install fetches Irisin. The OwnGoal meta package (apt, dpkg,
# openssh, sudo) is still installed from Irisin after this returns.
bootstrap_rootless() {
  log "installing rootless Irisin bootstrap for deb/JIT (layout=rootless)"
  /usr/bin/python3 - "$VM_DIR/vphone.sock" "$ART" <<'PY' || return 1
import json, socket, sys
sock_path, art = sys.argv[1], sys.argv[2]

def rpc(method, params, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps({"t": "rpc", "method": method, "params": params, "screen": False}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    line = buf.split(b"\n", 1)[0]
    if not line:
        raise SystemExit("empty sock reply for " + method)
    data = json.loads(line)
    if data.get("ok") is False:
        raise SystemExit(method + " failed: " + str(data.get("error")))
    return data

status = rpc("bootstrap.status", {})
open(art + "/bootstrap-status.json", "w").write(json.dumps(status))
phase = str((status.get("result") or {}).get("phase") or "")
print("bootstrap.status phase=%s" % phase)
if phase == "completed":
    sys.exit(0)
installed = rpc("bootstrap.install", {"layout": "rootless"}, timeout=1800)
open(art + "/bootstrap-install.json", "w").write(json.dumps(installed))
done = installed.get("result") or {}
print("bootstrap.install phase=%s layout=%s" % (done.get("phase"), done.get("layout")))
PY
}

# Same class as setup.skip: sock RPC, no language-list taps.
# 1) Write Procursus/apt sources.list.d (CLI path once apt exists).
# 2) Open irisin://repository/add so Irisin lists Wawona without HID search.
ensure_wawona_repo() {
  log "adding Wawona APT source (https://repo.wawona.io/)"
  /usr/bin/python3 - "$VM_DIR/vphone.sock" "$ART" <<'PY' || return 1
import json, socket, sys, time
sock_path, art = sys.argv[1], sys.argv[2]
LIST_PATH = "/var/jb/etc/apt/sources.list.d/wawona.list"
LIST_BODY = "deb https://repo.wawona.io/ ./\n"
IRISIN_ADD = "irisin://repository/add?url=https%3A%2F%2Frepo.wawona.io%2F"
record = {"apt_list": None, "irisin": None}

def rpc(method, params, timeout=40):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps({"t": "rpc", "method": method, "params": params, "screen": False}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    line = buf.split(b"\n", 1)[0]
    if not line:
        raise SystemExit("empty sock reply for " + method)
    data = json.loads(line)
    if data.get("ok") is False:
        raise SystemExit(method + " failed: " + str(data.get("error")))
    return data

def tap_label(text, y_min=0.0):
    tree = rpc("ui.tree", {"max_elements": 150, "visible_only": True})
    els = (tree.get("result") or {}).get("elements") or []
    screen = rpc("device.screen", {})
    scale = float((screen.get("result") or {}).get("scale") or 3)
    for el in els:
        lab = el.get("label") or ""
        fr = el.get("frame") or {}
        if lab != text:
            continue
        y = float(fr.get("y") or 0)
        if y < y_min:
            continue
        x = int((float(fr.get("x") or 0) + float(fr.get("width") or 0) / 2) * scale)
        ty = int((y + float(fr.get("height") or 0) / 2) * scale)
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(15)
        s.connect(sock_path)
        s.sendall((json.dumps({"t": "tap", "x": x, "y": ty, "screen": False}) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        s.close()
        return True
    return False

rpc("files.mkdir", {"path": "/var/jb/etc/apt/sources.list.d"})
wrote = rpc("files.write", {
    "path": LIST_PATH,
    "content": LIST_BODY,
    "encoding": "utf8",
})
record["apt_list"] = wrote.get("result") or wrote
print("wrote", LIST_PATH)
try:
    rpc("apps.open_url", {"url": IRISIN_ADD})
    time.sleep(1.5)
    tree = rpc("ui.tree", {"max_elements": 150, "visible_only": True})
    labels = [(el.get("label") or "") for el in ((tree.get("result") or {}).get("elements") or [])]
    if any("Already Added" == lab for lab in labels) or any("repo.wawona.io" in lab for lab in labels):
        record["irisin"] = "already-added"
        print("Irisin: Wawona source already added")
        tap_label("Done")
    elif tap_label("Add", y_min=600):
        time.sleep(1.0)
        record["irisin"] = "added"
        print("Irisin: tapped Add on Wawona row")
        tap_label("Done")
    else:
        record["irisin"] = "sheet-missing"
        print("Irisin add sheet missing (open_url still issued)")
except BaseException as exc:
    if isinstance(exc, KeyboardInterrupt):
        raise
    record["irisin"] = "error"
    print("Irisin URL skipped:", exc)
open(art + "/wawona-repo.json", "w").write(json.dumps(record))
print("wawona-repo.json written")
PY
}

# Once OwnGoal/openssh/apt exist: refresh Packages from repo.wawona.io.
ensure_wawona_apt_cli() {
  local ip="$1"
  log "apt-get update against https://repo.wawona.io/ on $ip"
  guest_ssh "$ip" '
      export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:$PATH"
      set -e
      list=/var/jb/etc/apt/sources.list.d/wawona.list
      if [[ ! -f "$list" ]] || ! grep -q repo.wawona.io "$list" 2>/dev/null; then
        echo alpine | sudo -S -p "" mkdir -p /var/jb/etc/apt/sources.list.d
        echo alpine | sudo -S -p "" sh -c 'printf "deb https://repo.wawona.io/ ./\n" > /var/jb/etc/apt/sources.list.d/wawona.list'
      fi
      echo alpine | sudo -S -p "" apt-get update -qq || apt-get update -qq || true
      echo "WawonaAptList=$(tr -d "\n" < "$list" 2>/dev/null || echo missing)"
      if command -v apt-cache >/dev/null 2>&1; then
        apt-cache policy wawona-launch-tools 2>/dev/null | head -8 || echo "wawona-launch-tools=not-in-cache"
      else
        echo "apt-cache=missing"
      fi
    ' 2>&1 | tee "$ART/wawona-apt-cli.txt"
}

ax_smoke() {
  local out
  out="$ART/ui-tree.json"
  printf '%s\n' '{"t":"rpc","method":"ui.tree","params":{"max_elements":50,"visible_only":true},"screen":false}' \
    | nc -U "$VM_DIR/vphone.sock" >"$out" 2>/dev/null || true
  if ! grep -q '"elements"' "$out"; then
    log "ui.tree has no elements (Home Screen is unverified). Launching Settings."
    printf '%s\n' '{"t":"rpc","method":"apps.launch","params":{"bundle_id":"com.apple.Preferences"},"screen":false}' \
      | nc -U -w 40 "$VM_DIR/vphone.sock" >/dev/null || true
    sleep 2
    printf '%s\n' '{"t":"rpc","method":"ui.tree","params":{"max_elements":50,"visible_only":true},"screen":false}' \
      | nc -U "$VM_DIR/vphone.sock" >"$out" 2>/dev/null || return 1
  fi
  grep -q '"elements"' "$out" || return 1
  log "ui.tree saved $out"
}

smoke() {
  local ip
  need_cmd sshpass
  need_cmd nc
  ip="$(cat "$ART/guest-ip.txt" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(ssh_ready || true)"
  fi
  if [[ -z "$ip" ]]; then
    log "no guest SSH; writing sock profile only"
    ip=""
  else
  log "smoke SSH mobile@$ip"
  # Remote body must stay single-quoted so it runs on the guest, not the host.
  # shellcheck disable=SC2016
  guest_ssh "$ip" '
      export PATH="/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin:/var/binpack/usr/bin:$PATH"
      set -e
      echo "uname: $(uname -a)"
      echo "sw_vers: $(sw_vers 2>/dev/null | tr "\n" " ")"
      test -d /var/jb/Applications/Sileo.app && echo Sileo=ok || echo Sileo=missing
      if command -v debugserver >/dev/null 2>&1; then
        echo "debugserver=ok path=$(command -v debugserver)"
      else
        echo "debugserver=missing"
      fi
      if grep -q "TrollStore Lite installed\|vphone_jb_setup.sh complete\|Already completed" /var/log/vphone_jb_setup.log 2>/dev/null; then
        echo TrollStore=ok
      else
        echo "TrollStore=missing (2.6.0 CFW does not install it; use apps.install or a bootstrap)"
        tail -20 /var/log/vphone_jb_setup.log 2>/dev/null || true
      fi
      echo "SBAutoLockTime=$(defaults read com.apple.springboard SBAutoLockTime 2>/dev/null || echo unset)"
      echo jb_root=/var/jb
      if grep -q repo.wawona.io /var/jb/etc/apt/sources.list.d/wawona.list 2>/dev/null; then
        echo WawonaApt=ok
      else
        echo WawonaApt=missing
      fi
    ' 2>&1 | tee "$ART/ssh-smoke.txt"
  fi

  {
    echo "=== ready $(date) ==="
    echo "guest: $ip"
    echo "SSH:   ssh -p 22222 mobile@$ip   # password alpine"
    echo "VNC:   vnc://$ip:5901"
    echo "vm:    $VM_NAME"
    echo "Sileo + TrollStore Lite + debugserver: verified"
  } | tee "$ART/ready.txt"

  # agent-device connection profile (Wawona fork discovers vphone:* devices).
  local profile_dir profile_path sock
  if [[ -n "${WAWONA_ROOT:-}" ]]; then
    profile_dir="$WAWONA_ROOT/.agent-device"
  elif [[ -d "$PWD/.agent-device" || -f "$PWD/flake.nix" ]]; then
    profile_dir="$PWD/.agent-device"
  else
    profile_dir="$ROOT/artifacts"
  fi
  mkdir -p "$profile_dir"
  sock="$VM_DIR/vphone.sock"
  profile_path="$profile_dir/vphone-${VM_NAME}.json"
  cat >"$profile_path" <<EOF
{
  "vmName": "$VM_NAME",
  "sockPath": "$sock",
  "sshHost": "$ip",
  "sshPort": 22222,
  "sshUser": "mobile",
  "sshPassword": "alpine",
  "variant": "jb",
  "vnc": "vnc://${ip}:5901",
  "vmDir": "$VM_DIR",
  "apiUrl": "${API_URL:-}",
  "apiToken": "${API_TOKEN:-}",
  "guestProductType": "${DEVICE_TYPE:-iPhone17,3}",
  "form": "$([[ "$IPAD" == 1 ]] && echo ipad || echo iphone)"
}
EOF
  log "wrote agent-device profile: $profile_path"
  log "READY"
}

ensure_create() {
  if vm_exists && [[ "$CREATE_FORCE" != 1 ]]; then
    log "VM bundle exists: $VM_DIR"
    return 0
  fi
  if vm_exists && [[ "$CREATE_FORCE" == 1 ]]; then
    die "--force-create with existing VM: delete $VM_DIR manually first"
  fi
  need_cmd aria2c
  need_cmd ldid
  local iphone_src cloudos_src
  iphone_src="$IPHONE_URL"
  cloudos_src="$CLOUDOS_URL"
  if [[ "$IPAD" == 1 ]]; then
    if [[ -f "$ROOT/ipsws/iPad16,1,iPad16,2_26.1_23B85_Restore.ipsw" ]]; then
      iphone_src="$ROOT/ipsws/iPad16,1,iPad16,2_26.1_23B85_Restore.ipsw"
    fi
  elif [[ -f "$ROOT/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw" ]]; then
    iphone_src="$ROOT/ipsws/iPhone17,3_26.1_23B85_Restore.ipsw"
  fi
  if [[ -f "$ROOT/ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw" ]]; then
    cloudos_src="$ROOT/ipsws/399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw"
  fi
  log "1.x VMs under $ROOT/VMs do not boot on this CLI"
  log "this may take a long time even when IPSWs are cached"
  # 2.6.0 cfw install refuses unless the process is root. It does not prompt.
  if [[ -n "$DEVICE_TYPE" ]]; then
    log "creating $VM_NAME (vphone 2.6 schema 2, disk=${DISK_GB}G, device=$DEVICE_TYPE)…"
    with_tty sudo -n "$VPHONE" vm create "$VM_NAME" --disk-size "$DISK_GB" \
      -i "$iphone_src" -c "$cloudos_src" --ipsw-cache "$ROOT/ipsws" \
      --device "$DEVICE_TYPE" -v \
      | tee "$ART/create.log"
  else
    log "creating $VM_NAME (vphone 2.6 schema 2, disk=${DISK_GB}G, iOS 26.1)…"
    with_tty sudo -n "$VPHONE" vm create "$VM_NAME" --disk-size "$DISK_GB" \
      -i "$iphone_src" -c "$cloudos_src" --ipsw-cache "$ROOT/ipsws" -v \
      | tee "$ART/create.log"
  fi
  cfw_done || die "vm create finished but schemaVersion 2 config is missing"
}

ensure_restored_cfw() {
  if cfw_done; then
    log "schema 2 VM present: $VM_DIR"
    return 0
  fi
  if [[ -d "$ROOT/VMs/$VM_NAME" ]]; then
    log "found 1.x VM at $ROOT/VMs/$VM_NAME; vphone 2.6 cannot boot it"
  fi
  die "no schemaVersion 2 VM at $VM_DIR. Run without --smoke-only so vm create can build one."
}

# ── Main ────────────────────────────────────────────────────────
check_gate
[[ "$GATE_ONLY" == 1 ]] && { log "gate-only done"; exit 0; }

resolve_vphone
apply_vphoned_ax
need_cmd nc

if [[ "$SMOKE_ONLY" == 1 ]]; then
  ip="$(ssh_ready)" || die "guest SSH not up; run without --smoke-only"
  echo "$ip" >"$ART/guest-ip.txt"
  disable_autolock "$ip"
  ensure_wawona_apt_cli "$ip" || log "warn: apt-get update for repo.wawona.io failed"
  ensure_debugserver "$ip"
  smoke
  exit 0
fi

if ! cfw_done; then
  if ! vm_exists; then
    # Prefer full upstream create (prepare→patch→restore→CFW→first boot).
    ensure_create
  else
    ensure_restored_cfw
  fi
fi

ensure_api_token
launch_vm
wait_sock 240 || die "vphoned did not answer ping on $VM_DIR/vphone.sock"
skip_setup || log "warn: Setup Assistant skip failed"
if [[ "$BOOTSTRAP" == 1 ]]; then
  bootstrap_rootless || log "warn: rootless bootstrap failed (tipa via apps.install still works; deb needs Irisin)"
fi
ensure_wawona_repo || log "warn: Wawona APT source not written (need /var/jb from Irisin bootstrap)"
harvest_api
ax_smoke || log "warn: ui.tree did not return elements yet"
if ip="$(ssh_ready)"; then
  echo "$ip" >"$ART/guest-ip.txt"
  disable_autolock "$ip" || true
  ensure_wawona_apt_cli "$ip" || log "warn: apt-get update for repo.wawona.io failed (need OwnGoal apt)"
  ensure_debugserver "$ip" || log "warn: debugserver not installed (no apt yet)"
  smoke || log "warn: SSH smoke incomplete"
else
  log "SSH is down. vphone 2.6 standard CFW does not install dropbear or TrollStore."
  log "AX is ui.tree on vphone.sock. Install the tipa with apps.install once the API token is up."
  ip=""
  smoke || true
fi
exit 0
