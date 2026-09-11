# vphone-cli CFW patches (Wawona)

`vphoned_accessibility.*` implements `accessibility_tree` for agent-device
`snapshot -i` `@eN` refs:

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
