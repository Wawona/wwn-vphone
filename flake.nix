{
  description = "wwn-vphone: Nix-automated jailbroken iOS research lab via vphone-cli (Mode B). Never ships a prebuilt iOS VM or IPSW.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Source pin for the lab. The runnable binary is the matching GitHub
    # release bundle (VPhone-<version>.zip), installed by nix/vphone-cli-app.nix.
    # 1.x VMs (schemaVersion absent, ~/.vphone/VMs) do not boot on this pin.
    vphone-cli.url = "github:Lakr233/vphone-cli/2.6.0";
    vphone-cli.flake = false;
  };

  outputs =
    { self, nixpkgs, vphone-cli }:
    let
      darwinSystems = [ "aarch64-darwin" ];
      forAll = nixpkgs.lib.genAttrs darwinSystems;

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      mkVphoneCli =
        pkgs:
        pkgs.callPackage ./nix/vphone-cli-app.nix {
          vphoneCliVersion = "2.6.0";
          vphoneCliRev = vphone-cli.rev or "2.6.0";
        };

      mkVphoneJbLab =
        pkgs:
        pkgs.callPackage ./nix/vphone-jb-lab.nix {
          vphone-cli = mkVphoneCli pkgs;
        };

      # Same lab script. --ipad selects iPad16,1 / iPadOS 26.1 and rootless bootstrap.
      mkVphoneIpadLab =
        pkgs:
        pkgs.writeShellScriptBin "vphone-ipad-lab" ''
          exec ${mkVphoneJbLab pkgs}/bin/vphone-jb-lab --ipad "$@"
        '';

      mkVphoneSock = pkgs: pkgs.callPackage ./nix/vphone-sock.nix { };
    in
    {
      packages = forAll (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          default = mkVphoneJbLab pkgs;
          vphone-jb-lab = mkVphoneJbLab pkgs;
          vphone-ipad-lab = mkVphoneIpadLab pkgs;
          vphone-cli = mkVphoneCli pkgs;
          vphone-sock = mkVphoneSock pkgs;
        }
      );

      apps = forAll (
        system:
        let
          pkgs = mkPkgs system;
          lab = mkVphoneJbLab pkgs;
          cli = mkVphoneCli pkgs;
        in
        {
          default = {
            type = "app";
            program = "${lab}/bin/vphone-jb-lab";
          };
          vphone-jb-lab = {
            type = "app";
            program = "${lab}/bin/vphone-jb-lab";
          };
          vphone-ipad-lab = {
            type = "app";
            program = "${mkVphoneIpadLab pkgs}/bin/vphone-ipad-lab";
          };
          vphone-cli = {
            type = "app";
            program = "${cli}/bin/vphone-cli";
          };
          vphone-sock = {
            type = "app";
            program = "${mkVphoneSock pkgs}/bin/vphone-sock";
          };
        }
      );

      # Convenience for Wawona (L4) overlay consumers.
      overlays.default = final: prev: {
        wwn-vphone-cli = mkVphoneCli final;
        wwn-vphone-jb-lab = mkVphoneJbLab final;
        wwn-vphone-ipad-lab = mkVphoneIpadLab final;
        wwn-vphone-sock = mkVphoneSock final;
      };

      checks = forAll (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          # Eval/build the wrappers only (no IPSW download).
          vphone-jb-lab = mkVphoneJbLab pkgs;
          vphone-ipad-lab = mkVphoneIpadLab pkgs;
          vphone-sock = mkVphoneSock pkgs;
        }
      );
    };
}
