# Runnable lab wrapper for Lakr233/vphone-cli (Swift + Makefile).
# Clones into $VPHONE_ROOT/src, builds via scripts/build.sh, execs the binary.
# Nix supplies CFW/DFU host tools (ldid-procursus, libusb, aria2, …). Brew is optional.
# IPSWs stay under ~/.vphone. See docs/testing/vphone-jailbreak-lab.md.
{
  lib,
  writeShellApplication,
  writeShellScriptBin,
  git,
  python3,
  aria2,
  wget,
  gnutar,
  openssl,
  cmake,
  libusb1,
  zstd,
  coreutils,
  findutils,
  gnused,
  gnugrep,
  gnumake,
  ldid-procursus,
  sshpass,
}:

let
  # Upstream insert_dylib prompts on LC_CODE_SIGNATURE; CFW must stay noninteractive.
  insertDylibAllYes = writeShellScriptBin "insert_dylib" ''
    set -euo pipefail
    ROOT="''${VPHONE_ROOT:-$HOME/.vphone}"
    REAL="$ROOT/src/vphone-cli/.tools/bin/insert_dylib.real"
    if [[ ! -x "$REAL" ]]; then
      REAL="$ROOT/src/vphone-cli/scripts/repos/insert_dylib/insert_dylib/insert_dylib"
    fi
    if [[ ! -x "$REAL" ]]; then
      echo "insert_dylib: missing binary under $ROOT/src/vphone-cli" >&2
      exit 127
    fi
    exec "$REAL" --all-yes "$@"
  '';
in
writeShellApplication {
  name = "vphone-cli";
  runtimeInputs = [
    git
    python3
    aria2
    wget
    gnutar
    openssl
    cmake
    libusb1
    zstd
    coreutils
    findutils
    gnused
    gnugrep
    gnumake
    ldid-procursus
    sshpass
    insertDylibAllYes
  ];
  text = ''
    set -euo pipefail
    ROOT="''${VPHONE_ROOT:-$HOME/.vphone}"
    SRC="$ROOT/src/vphone-cli"
    BIN_APP="$SRC/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
    BIN_REL="$SRC/.build/release/vphone-cli"
    TOOLS="$SRC/.tools"
    mkdir -p "$ROOT" "$TOOLS/bin" "$TOOLS/lib"

    # libusb for pymobiledevice3 / irecv DFU restore (pyusb backend).
    export DYLD_LIBRARY_PATH="${libusb1}/lib''${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
    export DYLD_FALLBACK_LIBRARY_PATH="${libusb1}/lib:/usr/lib''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"

    # Prefer nix ldid-procursus over brew/plain ldid (PKCS12 empty-password CFW signing).
    export PATH="${ldid-procursus}/bin:$TOOLS/bin:$PATH"

    if [[ ! -d "$SRC/.git" ]]; then
      echo "vphone-cli: cloning Lakr233/vphone-cli (recurse-submodules) into $SRC" >&2
      git clone --recurse-submodules --depth 1 \
        https://github.com/Lakr233/vphone-cli.git "$SRC"
    fi

    # Symlink nix tools into the project's expected .tools/bin layout.
    ln -sfn "${ldid-procursus}/bin/ldid" "$TOOLS/bin/ldid"
    ln -sfn "${ldid-procursus}/bin/ldid" "$TOOLS/bin/ldid2"
    ln -sfn "${aria2}/bin/aria2c" "$TOOLS/bin/aria2c"
    ln -sfn "${wget}/bin/wget" "$TOOLS/bin/wget"
    ln -sfn "${gnutar}/bin/tar" "$TOOLS/bin/gtar"
    ln -sfn "${gnutar}/bin/tar" "$TOOLS/bin/tar"
    ln -sfn "${zstd}/bin/zstd" "$TOOLS/bin/zstd"
    ln -sfn "${libusb1}/lib/libusb-1.0.0.dylib" "$TOOLS/lib/libusb-1.0.0.dylib"
    ln -sfn "${libusb1}/lib/libusb-1.0.dylib" "$TOOLS/lib/libusb-1.0.dylib"

    # Keep a real insert_dylib next to the --all-yes wrapper on PATH.
    if [[ -x "$TOOLS/bin/insert_dylib" && ! -x "$TOOLS/bin/insert_dylib.real" ]]; then
      mv "$TOOLS/bin/insert_dylib" "$TOOLS/bin/insert_dylib.real"
    fi

    pick_bin() {
      if [[ -x "$BIN_APP" ]]; then echo "$BIN_APP"; return; fi
      if [[ -x "$BIN_REL" ]]; then echo "$BIN_REL"; return; fi
      echo ""
    }

    BIN="$(pick_bin)"
    if [[ -z "$BIN" ]]; then
      echo "vphone-cli: building (scripts/setup_tools.sh + scripts/build.sh)" >&2
      echo "vphone-cli: needs Xcode, network, and tens of GB free for later IPSWs" >&2
      cd "$SRC"
      if [[ ! -x .venv/bin/python3 ]]; then
        ./scripts/setup_tools.sh || {
          echo "vphone-cli: setup_tools.sh failed (brew deps may be missing; nix PATH has substitutes)" >&2
          ${python3}/bin/python3 -m venv .venv
          .venv/bin/pip install -U pip
          .venv/bin/pip install 'pymobiledevice3' 'pyusb' 'typer' 'pyimg4' 'capstone' 'keystone-engine' || true
        }
      fi
      ./scripts/build.sh || true
      BIN="$(pick_bin)"
    fi

    if [[ -z "$BIN" || ! -x "$BIN" ]]; then
      echo "vphone-cli: no runnable binary under $SRC/.build" >&2
      exit 1
    fi

    if [[ -x "$SRC/.venv/bin/python3" ]]; then
      export VPHONE_PYTHON="$SRC/.venv/bin/python3"
    fi

    exec "$BIN" "$@"
  '';
}
