{
  description = "wwn-vphone: Nix-automated jailbroken iOS research lab via vphone-cli (Mode B). Never ships a prebuilt iOS VM or IPSW.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      darwinSystems = [ "aarch64-darwin" ];
      forAll = nixpkgs.lib.genAttrs darwinSystems;

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      # Prefer nixpkgs ldid-procursus when present; else plain ldid.
      resolveLdid = pkgs: pkgs.ldid-procursus or pkgs.ldid or null;

      mkVphoneCli =
        pkgs:
        pkgs.callPackage ./nix/vphone-cli-app.nix {
          ldid-procursus =
            let
              l = resolveLdid pkgs;
            in
            if l != null then
              l
            else
              pkgs.writeShellScriptBin "ldid" ''
                echo "wwn-vphone: ldid-procursus missing from nixpkgs; install Procursus ldid" >&2
                exit 127
              '';
        };

      mkVphoneJbLab =
        pkgs:
        pkgs.callPackage ./nix/vphone-jb-lab.nix {
          vphone-cli = mkVphoneCli pkgs;
        };
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
          vphone-cli = mkVphoneCli pkgs;
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
          vphone-cli = {
            type = "app";
            program = "${cli}/bin/vphone-cli";
          };
        }
      );

      # Convenience for Wawona (L4) overlay consumers.
      overlays.default = final: prev: {
        wwn-vphone-cli = mkVphoneCli final;
        wwn-vphone-jb-lab = mkVphoneJbLab final;
      };

      checks = forAll (
        system:
        let
          pkgs = mkPkgs system;
        in
        {
          # Eval/build the wrappers only (no IPSW download).
          vphone-jb-lab = mkVphoneJbLab pkgs;
        }
      );
    };
}
