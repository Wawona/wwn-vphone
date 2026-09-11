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

## Recover a stuck lab

`wait_ssh` pgrep does not match live argv
(`vphone-cli --config …/wawona-jb/config.plist --variant jb`). A
`no vphone process` line is not proof the VM is down. `agent-device`
`booted=true` is also stale when the sock refuses.

If the sock file exists and connect is `ECONNREFUSED` and that process
is gone: `nohup` `vphone-cli vm launch wawona-jb -V jb` with a visible
window. Never attach `vm launch` to a cancellable foreground agent
Shell. If a waiter is scanning SSH while the VM is live, kill only the
waiter. Never `pkill -f vphone`.

Wawona product skill: `wawona-vphone-lab-recover`.

## agent-device

Lab writes `vphone-<name>.json` (sock + SSH). Prefer device name
`vphone wawona-jb`. Same MCP/CLI surface as the Simulator:

```bash
agent-device devices
agent-device snapshot -i --device "vphone wawona-jb"
agent-device press @e12
agent-device packages tipa install path/to/App.tipa --open --jit
```

`snapshot -i` maps guest `accessibility_tree` (AXRuntime, then icon-grid) to
`@eN`. Sock screenshot/tap needs a visible VM window. Tipa/deb iteration:
`agent-device packages …`.

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