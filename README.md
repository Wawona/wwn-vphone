# wwn-vphone

Nix-automated **jailbroken iOS research lab** for Wawona Mode B development.
Wraps [Lakr233/vphone-cli](https://github.com/Lakr233/vphone-cli) the same way
upstream expects: download IPSW + cloudOS, create VM, CFW `jb`, launch, SSH
smoke.

**L3′** in the Wawona repo DAG (nixpkgs-only). Peer of `wwn-iowatchdog`.
Consumers: Wawona (L4) and the Wawona `agent-device` fork.

## Hard policy

| Allowed in this repo | Forbidden |
|---|---|
| Flake, scripts, patches, docs, profile **templates** | Prebuilt iOS VM / `Disk.img` |
| Catalog IPSW **URLs** (downloaded at runtime) | IPSW blobs, SEP/nvram dumps in git or Releases |
| Agent-device JSON **templates** | Machine-specific guest IPs committed as truth |

GitHub does not allow redistributing a prebuilt iOS virtual machine. Every
developer runs create/CFW locally after host gates.

## Quick start (any Darwin aarch64 developer)

Operator-owned once (Recovery; this flake never flips them):

1. `csrutil disable` (SIP fully disabled)
2. `csrutil allow-research-guests enable`
3. `nvram boot-args="amfi_get_out_of_my_way=1"` (then reboot)

Then:

```bash
nix run github:Wawona/wwn-vphone#vphone-jb-lab
```

Flags:

```bash
nix run github:Wawona/wwn-vphone#vphone-jb-lab -- --gate-only
nix run github:Wawona/wwn-vphone#vphone-jb-lab -- --smoke-only
```

Apps:

| App | Purpose |
|---|---|
| `vphone-jb-lab` | Full automated lab (default) |
| `vphone-cli` | Raw upstream CLI with nix PATH/tools |

Guest SSH default (research image): `mobile` / `alpine`, port `22222`.
Artifacts + agent-device profile: `~/.vphone/artifacts/…` and
`$WAWONA_ROOT/.agent-device/vphone-wawona-jb.json` when `WAWONA_ROOT` is set.

## Mode B packaging (agent-device)

After the lab is READY:

```bash
agent-device packages status --device "vphone wawona-jb"
agent-device packages tipa install path/to/App.tipa --open --jit
agent-device packages apt install path/to/pkg.deb
agent-device packages debug attach com.example.app
```

See Wawona `docs/testing/vphone-jailbreak-lab.md` (pointer) and agent-device
`help vphone-packages`.

## What this is not

- Not Desktop / LockScreen Mode B on macOS (`wwn-iowatchdog`)
- Not App Store / Mode A
- Not a place to store IPSWs or VM disks
