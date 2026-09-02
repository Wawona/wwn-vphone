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

## agent-device

Lab writes `vphone-<name>.json` (sock + SSH). Prefer device name
`vphone wawona-jb`. Tipa/deb iteration: `agent-device packages …`.
