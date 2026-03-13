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
      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfreePredicate =
            pkg:
            builtins.elem (lib.getName pkg) [
              "codex-app-bin"
            ];
        };
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = pkgsFor system;
          codex-app-bin = pkgs.callPackage ./package.nix {
            codex = pkgs.codex;
          };
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
          inherit (package.passthru.tests) codex-app-bin-check;
        }
      );
    };
}
