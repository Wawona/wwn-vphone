# vphone-cli CFW patches (Wawona)

vphone-cli **2.6.0** serves accessibility on the host socket as
`{"t":"rpc","method":"ui.tree"}` (alias `accessibility.tree`). Frames are
screen points. `device.screen` `scale` converts them to the pixel coordinates
`tap` uses. Do not apply this 1.x overlay onto a 2.x bundle.

`vphoned_accessibility.*` is the **1.x** `accessibility_tree` overlay for
agent-device `snapshot -i` `@eN` refs:

1. AXRuntime (`_AXUIElementCreateWithPid` + attribute walk)
2. AccessibilityUtilities `AXElement` (system-wide)
3. LSApplicationWorkspace icon-grid fallback

`apply-vphoned-ax.sh` copies the sources into a vphone-cli checkout, adds
weak UIKit/AXRuntime link flags, and merges AX entitlements.

```bash
# Lab does this automatically. Manual:
bash patches/apply-vphoned-ax.sh "${VPHONE_ROOT:-$HOME/.vphone}/src/vphone-cli"
```

Host sock `{"t":"ax"}` (VPhoneHostControl) prefers guest `accessibility_tree`
and falls back to `app_list` if the capability is missing.
