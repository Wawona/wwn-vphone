# One-shot jailbroken vphone lab: gate → create/CFW(jb) → launch → SSH smoke.
#   nix run github:Wawona/wwn-vphone#vphone-jb-lab
# Never downloads IPSWs into the nix store; never ships Disk.img.
{
  lib,
  writeShellApplication,
  vphone-cli,
  sshpass,
  coreutils,
  gnugrep,
  gnused,
  gawk,
}:

writeShellApplication {
  name = "vphone-jb-lab";
  runtimeInputs = [
    vphone-cli
    sshpass
    coreutils
    gnugrep
    gnused
    gawk
  ];
  # Embed the repo script so `nix run` works from any cwd once built.
  # Host /usr/bin/nc (macOS) is used for port probes.
  text = builtins.readFile ../scripts/vphone-jb-lab.sh;
}
