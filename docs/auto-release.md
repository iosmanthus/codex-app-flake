# Auto Release Flow

This document describes the current GitHub Actions workflows for the Codex DMG mirror.

## Workflows

- `.github/workflows/auto-release.yaml`: scheduled or manual release sync that runs `./update_release.py`
- `.github/workflows/ci.yaml`: validation workflow that runs `nix flake check` on pull requests and pushes to `main`

## Source

- Upstream DMG URL: `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`
- The DMG is fetched into the Nix store with `nix-prefetch-url`
- App version source: `Codex.app/Contents/Info.plist`
- Native module version sources:
  - `node_modules/better-sqlite3/package.json`
  - `node_modules/node-pty/package.json`

## Metadata

The release workflow updates these repository files:

- `meta.json`
- `package.json`
- `package-lock.json`

`meta.json` contains these required fields:

- `version`
- `url`
- `sha256`
- `npmDepsHash`

Important URL behavior:

- The committed `meta.json.url` always points to the mirrored GitHub Release asset URL
- Before the pre-commit build, `update_release.py` temporarily rewrites `meta.json.url` to the prefetched DMG's Nix store URI because the final GitHub Release asset does not exist yet
- If the pre-commit build fails, the script restores the original repository files before exiting

## Naming

Release naming format:

- Tag: `<version>`
- Release name: `Codex <version>`
- Asset name: `Codex-<version>.dmg`

## Auto Release Triggers

The auto-release workflow supports:

- `schedule`: run once per day
- `workflow_dispatch`: manual trigger

## CI Triggers

The CI workflow runs on:

- `pull_request`
- `push` to `main`

## Release Steps

1. Fetch the upstream DMG directly into the Nix store with `nix-prefetch-url`, capturing both the store path and the sha256.
2. Extract the app bundle from the prefetched DMG and read the app version from `Info.plist`.
3. Read the shipped `better-sqlite3` and `node-pty` versions from the unpacked app.
4. Rewrite `package.json` with those versions.
5. Regenerate `package-lock.json`.
6. Recompute `npmDepsHash`.
7. Build the expected next `meta.json` using the GitHub Release asset URL and the sha256 returned by `nix-prefetch-url`.
8. If the expected metadata already matches the committed repository state, leave repository files unchanged, call `ensure_release(...)` to create or repair the GitHub Release if needed, and exit successfully.
9. If the version tag already exists but the metadata changed, fail the workflow.
10. Temporarily rewrite `meta.json.url` to the prefetched DMG's Nix store URI.
11. Build `.#codex-app-bin` with `nix build .#codex-app-bin --no-link`.
12. If the build fails, restore the original `meta.json`, `package.json`, and `package-lock.json`, then abort.
13. Rewrite `meta.json` back to the final GitHub Release asset URL.
14. Commit and push `meta.json`, `package.json`, and `package-lock.json` to `main` using the GitHub Actions bot identity.
15. Create or repair the GitHub Release for that commit and upload `Codex-<version>.dmg`.

## Repair Behavior

When `meta.json`, `package.json`, and `package-lock.json` are already up to date, the workflow still calls `ensure_release(...)`.

That allows a rerun to repair release state after a partial failure, for example when:

- the GitHub Release was never created
- the release exists but the DMG asset is missing

In that path, the repository contents stay unchanged.

## Why The Commit Must Happen Before Tagging

The tag should point at the exact repository state that produced the release metadata.

If the workflow creates the tag or release before committing `meta.json`, the tagged commit will not contain the metadata for that release. That would make the repository state inconsistent with the published artifact.

The correct order for a metadata-changing release is:

1. write `meta.json`, `package.json`, and `package-lock.json`
2. validate the package build against the prefetched store DMG
3. commit and push
4. create the release tag
5. create or repair the GitHub Release
6. upload the DMG asset

## Git Identity

When the workflow commits release metadata, it uses:

- `user.name`: `github-actions[bot]`
- `user.email`: `41898282+github-actions[bot]@users.noreply.github.com`

## Failure Behavior

- If fetching the upstream DMG into the Nix store fails, fail the workflow.
- If extracting the app bundle or reading version metadata fails, fail the workflow.
- If package metadata regeneration fails, fail the workflow.
- If the pre-commit package build against the staged store DMG fails, restore the original repository files and fail before committing.
- If git push fails, fail the workflow.
- If GitHub Release creation or asset upload fails, fail the workflow.
- If no metadata update is needed, exit successfully after optionally repairing the GitHub Release state.

## Notes

- The upstream DMG URL is mutable, so the workflow derives the version from the downloaded artifact, not from the URL.
- The committed `meta.json.url` always points to the mirrored GitHub Release asset for reproducibility.
- `meta.json`, `package.json`, and `package-lock.json` change only when the upstream DMG metadata changes.
- `npmDepsHash` is derived from the regenerated `package-lock.json` and stored in `meta.json`.
- The release asset keeps a stable, versioned file name even though the upstream source URL is not versioned.
