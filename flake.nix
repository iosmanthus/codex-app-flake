{
  description = "Nix flake for the unofficial Codex Desktop Linux port";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem = lib.genAttrs systems;
      overlay = final: prev: {
        codex-app-bin = final.callPackage ./package.nix {
          codex = final.codex;
        };
      };
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ overlay ];
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "codex-app-bin"
            ];
        };
    in
    {
      overlays = {
        default = overlay;
        codex-app-bin = overlay;
      };

      packages = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          codex-app-bin = pkgs.codex-app-bin;
        in
        {
          inherit codex-app-bin;
          default = codex-app-bin;
        }
      );

      apps = forEachSystem (
        system:
        let
          package = self.packages.${system}.codex-app-bin;
          app = {
            type = "app";
            program = "${package}/bin/codex-app-bin";
            meta = {
              description = "Launch the Codex Desktop Linux wrapper";
            };
          };
        in
        {
          codex-app-bin = app;
          default = app;
        }
      );

      checks = forEachSystem (
        system:
        let
          package = self.packages.${system}.codex-app-bin;
        in
        {
          codex-app-bin-check = package;
        }
      );
    };
}
