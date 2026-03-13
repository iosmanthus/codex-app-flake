# codex-app-flake

Nix flake for running the official Codex desktop app on Linux, including NixOS.

This repository mirrors the upstream macOS DMG into GitHub Releases, repackages it with the Linux Electron runtime, and rebuilds the native modules that must match the target Linux/Electron ABI.

This repository also builds on code from [ilysenko/codex-desktop-linux](https://github.com/ilysenko/codex-desktop-linux).
