# vphone-jb lab (canonical)

Authority lives in this repo (`wwn-vphone`). Wawona’s
`docs/testing/vphone-jailbreak-lab.md` is a short product pointer.

## Host gates (operator)

- Apple Silicon, macOS 15+, Xcode + iOS SDK
- Non-nested host
- SIP fully disabled (`csrutil disable`)
- `csrutil allow-research-guests enable` (Recovery)
- `nvram boot-args` includes `amfi_get_out_of_my_way=1`

The lab script **checks** these and never mutates Recovery/nvram.

## One command

```bash
nix run github:Wawona/wwn-vphone#vphone-jb-lab
```

From a Wawona checkout that pins this flake:

```bash
nix run .#vphone-jb-lab
```

No prebuilt VM is distributed. IPSWs download into `~/.vphone` at runtime
(same model as upstream vphone-cli).

## iPadOS (same ease as iOS)

```bash
nix run github:Wawona/wwn-vphone#vphone-ipad-lab
```

That is `vphone-jb-lab --ipad`. Defaults:

| | iPhone lab | iPad lab |
|---|---|---|
| VM | `wawona-jb` | `wawona-ipad` (`VPHONE_VM_NAME` overrides) |
| Device | iPhone17,3 | `iPad16,1` (mini A17 Pro). Override `VPHONE_DEVICE` |
| Restore | iPhone 26.1 / 23B85 | iPad16,1,iPad16,2 26.1 / 23B85 |
| cloudOS | cached 26.1 IPSW | same cached 26.1 IPSW |
| API | `127.0.0.1:8765` | `127.0.0.1:8766` |
| Sock scale | 3 | 2 (from `device.screen`) |
| Artifacts | `~/.vphone/artifacts/vphone-jb` | `~/.vphone/artifacts/vphone-ipad` |

The iPad guest reuses the cloudOS IPSW. It does not reuse the iPhone restore
IPSW. `cfw install` skips the iPhone17,3 identity rewrite. After setup skip,
the iPad lab calls `bootstrap.install` with `layout: rootless` (`/var/jb`,
Wawona `iphoneos-arm64` debs). iPhone lab now does the same by default
(`--no-bootstrap` skips Irisin). Pass `--no-bootstrap` to skip that. Irisin
does not install apt or openssh. Deb and JIT debugserver need the OwnGoal
meta package `owngoal-bootstrap-vphone` from Irisin (`ui.tree` /
`ui.tap_element`). Do not install those packages one by one. The Wawona
APT list file is still written under `/var/jb/etc/apt/sources.list.d/`
so `apt-get update` works once apt exists.

agent-device name: `vphone wawona-ipad`. Tipa install uses the unix socket
(`files.write` base64, then `apps.install`) when TrollStore SSH is absent.
Do not stop `wawona-jb` to boot the iPad. Do not foreground `vm create` or
`vm launch`.

## Setup Assistant

A new guest boots into Setup.app. The lab does not tap that UI. After
vphoned answers ping it calls `setup.skip` (`force: true`), which writes
`SetupDone`, `SetupFinishedAllSteps`, and `SetupVersion` through cfprefsd
and resprings, then `screen.unlock` if the Lock Screen is up.

The same pass writes the Wawona APT source. That is required, not optional:

1. Sock `files.mkdir` + `files.write` of
   `/var/jb/etc/apt/sources.list.d/wawona.list`
   (`deb https://repo.wawona.io/ ./`). Apt CLI reads this after OwnGoal.
2. `apps.open_url` `irisin://repository/add?url=https://repo.wawona.io/`
   then Add / Already Added. Same URL as repo.wawona.io `/jailbreak/`.
3. When guest SSH is up: `apt-get update` and `apt-cache policy
   wawona-launch-tools`.

Do not type the source URL through Irisin Search HID. Do not wait for a
human to tap Add Repository.

`ui.tree` still fails on the Home Screen (`frontmost application could
not be verified`). Launch an app with `apps.launch` before AX taps.

## Recover a stuck lab

Live process is `vphone-vm` with `~/.vphone/machines/wawona-jb/config.plist`.
A `no vphone process` line is not proof the VM is down. `agent-device`
`booted=true` is also stale when the sock refuses.

If the sock file exists and connect is `ECONNREFUSED` and that process
is gone: `nohup` `vphone-cli vm launch wawona-jb --api-listen 127.0.0.1:8765 -v`
with a visible window. Do not pass 1.x `-V jb`. Never attach `vm launch`
to a cancellable foreground agent Shell. If a waiter is scanning SSH
while the VM is live, kill only the waiter. Never `pkill -f vphone`.

Wawona product skill: `wawona-vphone-lab-recover`.

## Sock helper (live guest)

Do not type into `vphone-cli`. After the VM is up:

```bash
nix run .#vphone-sock -- ping
nix run .#vphone-sock -- ls /var/jb/etc/apt/sources.list.d
nix run .#vphone-sock -- open-url \
  'irisin://repository/add?url=https%3A%2F%2Frepo.wawona.io%2F'
```

Python without Nix: `python3 scripts/vphone-sock.py ping`. Skill
`wawona-vphone-cli`. `packages apt` still needs SSH.

## agent-device

Lab writes `vphone-<name>.json` (sock + SSH). Prefer device name
`vphone wawona-jb`. Same MCP/CLI surface as the Simulator:

```bash
agent-device devices
agent-device snapshot -i --device "vphone wawona-jb"
agent-device press @e12
agent-device packages tipa install path/to/App.tipa --open --jit
```

`snapshot -i` calls vphone 2.6 `ui.tree` on `vphone.sock` (AX frames scaled
by `device.screen`), then the SSH icon-grid. Sock screenshot/tap needs a
visible VM window. Library path is `~/.vphone/machines/<name>` (`schemaVersion`
2). 1.x disks under `~/.vphone/VMs` do not boot. Tipa/deb iteration:
`agent-device packages …`. Without TrollStore, tipa install writes the
archive with sock `files.write` and calls `apps.install`. The guest HTTP
API is the fallback when the profile has `apiUrl` and `apiToken`.

Replay: Wawona `.agent-device/wawona-ios-vphone-smoke.ad`.

### Guest debugserver (lldb)

Bootstrap installs Procursus `debugserver` via apt (idempotent). That is what
`agent-device packages debug attach` starts before handing `connect://` to
**user-lldb**.

| Path | debugserver source |
|---|---|
| Physical / stock iOS | Xcode Developer Disk Image over lockdown |
| **vphone-jb research guest** | **Procursus apt** `debugserver` (LLVM 16 meta package) |

Same role Theos / Procursus device debugging already uses. Not a Wawona
invention; the lab just refuses to leave it optional.