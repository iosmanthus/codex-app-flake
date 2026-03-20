# Auto Release Flow

This document describes the expected GitHub Actions release flow for the Codex DMG mirror.

## Source

- Download URL: `https://persistent.oaistatic.com/codex-app-prod/Codex.dmg`
- Primary version sources:
  - `Codex.app/Contents/Info.plist`
  - `Codex.app/Contents/Resources/app.asar/package.json`

## Metadata

The workflow writes a `meta.json` file at the repository root for `package.nix` to read.

Required fields:

- `version`
- `url`
- `sha256`
- `npmDepsHash`

`meta.json.url` should point to the mirrored GitHub Release asset, not the mutable upstream DMG URL.

## Naming

Release naming format:

- Tag: `<version>`
- Release name: `Codex <version>`
- Asset name: `Codex-<version>.dmg`

## Workflow Triggers

The workflow should support:

- `schedule`: run once per day
- `workflow_dispatch`: manual trigger

## Release Steps

1. Download the current DMG from the upstream URL.
2. Extract the DMG and read the version metadata from `Info.plist` and `app.asar/package.json`.
3. Calculate the DMG sha256 and derive the final mirrored release metadata for that version.
4. If the resulting `meta.json`, `package.json`, and `package-lock.json` would be unchanged, exit successfully.
5. If the upstream build has changed, extract the shipped `better-sqlite3` and `node-pty` versions from the app bundle.
6. Rewrite `package.json` with those exact versions.
7. Regenerate `package-lock.json`.
8. Recompute `npmDepsHash`.
9. Write the new `meta.json`, with `url` set to the GitHub Release asset URL for that version.
10. Run `nix flake check`; if it fails, abort the release without committing or publishing anything.
11. Commit and push `meta.json`, `package.json`, and `package-lock.json` to `main` using the GitHub Actions bot identity.
12. Create a git tag from that commit using the upstream `version`.
13. Create a GitHub Release from that tag and upload the downloaded DMG as `Codex-<version>.dmg`.

## Why The Commit Must Happen Before Tagging

The tag should point at the exact repository state that produced the release metadata.

If the workflow creates the tag or release before committing `meta.json`, the tagged commit will not contain the metadata for that release. That would make the repository state inconsistent with the published artifact.

The correct order is:

1. write `meta.json`, `package.json`, and `package-lock.json`
2. commit and push
3. create tag
4. create release
5. upload DMG

## Git Identity

When the workflow commits `meta.json`, it should use:

- `user.name`: `github-actions[bot]`
- `user.email`: `41898282+github-actions[bot]@users.noreply.github.com`

## Failure Behavior

- If the DMG download fails, fail the workflow.
- If the metadata extraction fails, fail the workflow.
- If package metadata regeneration fails, fail the workflow.
- If `nix flake check` fails, fail the workflow before committing or publishing a release.
- If the release upload fails, fail the workflow.
- If no upstream update is detected, exit with success and leave the repository unchanged.

## Notes

- The upstream DMG URL is mutable, so the workflow must derive the release version from the downloaded artifact, not from the URL.
- `meta.json.url` should always point at the mirrored GitHub Release asset for reproducibility.
- `meta.json`, `package.json`, and `package-lock.json` should only change when the upstream DMG changes.
- `npmDepsHash` is derived from the regenerated `package-lock.json` and is stored in `meta.json`.
- The release asset keeps a stable, versioned file name even though the source URL is not versioned.
