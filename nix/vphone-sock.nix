# Thin Unix-socket client for a *running* vphone-cli guest.
#   nix run github:Wawona/wwn-vphone#vphone-sock -- ping
# Does not launch the VM. Skill: wawona-vphone-cli.
{
  writeShellApplication,
  python3,
}:

writeShellApplication {
  name = "vphone-sock";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${python3}/bin/python3 ${../scripts/vphone-sock.py} "$@"
  '';
}
