# Runnable lab wrapper for Lakr233/vphone-cli.
# The flake input pins the 2.6.0 source. The binary that actually runs is the
# matching GitHub release bundle: a source build needs Xcode, an iPhoneOS SDK,
# and a per-signature AMFI allow, and the nix sandbox cannot boot a VM.
# IPSWs and VM disks stay under ~/.vphone. Never copied into the nix store.
{
  lib,
  writeShellApplication,
  curl,
  unzip,
  coreutils,
  vphoneCliVersion ? "2.6.0",
  vphoneCliRev ? "2.6.0",
}:

writeShellApplication {
  name = "vphone-cli";
  runtimeInputs = [
    curl
    unzip
    coreutils
  ];
  text = ''
    set -euo pipefail
    VER="${vphoneCliVersion}"
    REV="${vphoneCliRev}"
    ROOT="''${VPHONE_ROOT:-$HOME/.vphone}"
    DEST="$ROOT/bundles/$VER"
    STAMP="$DEST/REV"
    CLI="$DEST/VPhone.bundle/Contents/MacOS/vphone-cli"
    VM="$DEST/VPhone.bundle/Contents/MacOS/vphone-vm"
    ESC="$DEST/VPhone.bundle/Contents/MacOS/vphone-escalator"
    ZIP="$ROOT/bundles/VPhone-$VER.zip"
    URL="https://github.com/Lakr233/vphone-cli/releases/download/$VER/VPhone-$VER.zip"
    mkdir -p "$ROOT/bundles"

    need_bundle=0
    if [[ ! -x "$CLI" ]]; then
      need_bundle=1
    elif [[ "$(cat "$STAMP" 2>/dev/null || true)" != "$REV" ]]; then
      need_bundle=1
    fi

    if [[ "$need_bundle" == 1 ]]; then
      echo "vphone-cli: installing VPhone.bundle $VER ($REV)" >&2
      rm -rf "$DEST"
      mkdir -p "$DEST"
      curl -fL --retry 3 -o "$ZIP" "$URL"
      unzip -q "$ZIP" -d "$DEST"
      printf '%s\n' "$REV" >"$STAMP"
    fi

    if [[ ! -x "$CLI" ]]; then
      echo "vphone-cli: bundle missing $CLI" >&2
      exit 1
    fi

    # A new bundle signature is refused until its cdhash is on the AMFI
    # allowlist. Passwordless sudo is the lab host. Do not prompt.
    maybe_allow() {
      local sub="''${1:-}" verb="''${2:-}"
      case "$sub $verb" in
        "boot "*|"vm launch"|"vm create"|"host preflight")
          ;;
        *)
          return 0
          ;;
      esac
      if "$CLI" host preflight >/dev/null 2>&1; then
        return 0
      fi
      if [[ -x "$ESC" ]] && sudo -n "$ESC" allow "$VM" >/dev/null 2>&1; then
        "$CLI" host preflight >/dev/null 2>&1 && return 0
      fi
      echo "vphone-cli: AMFI blocked vphone-vm. Run:" >&2
      echo "  sudo '$ESC' allow '$VM'" >&2
      exit 1
    }
    maybe_allow "''${1:-}" "''${2:-}"

    exec "$CLI" "$@"
  '';
  meta = {
    description = "Virtual iPhone CLI ${vphoneCliVersion} (Lakr233/vphone-cli release bundle)";
    homepage = "https://github.com/Lakr233/vphone-cli";
    platforms = [ "aarch64-darwin" ];
    license = lib.licenses.unfreeRedistributable;
  };
}
