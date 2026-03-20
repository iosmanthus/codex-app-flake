#! /usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 gitMinimal gh p7zip nodePackages.asar nodejs_20 -I nixpkgs=channel:nixos-unstable

from __future__ import annotations

import json
import os
import plistlib
import shlex
import shutil
import subprocess
import tempfile
from pathlib import Path


# Repository root used for all generated release metadata files.
ROOT = Path(__file__).resolve().parent
# Generated flake metadata consumed by package.nix.
META_PATH = ROOT / "meta.json"
# Native module manifest rewritten from the upstream app bundle.
PACKAGE_JSON_PATH = ROOT / "package.json"
# Lockfile used to derive npmDepsHash reproducibly.
PACKAGE_LOCK_PATH = ROOT / "package-lock.json"
# Mutable upstream DMG URL; the real version is read from the downloaded app.
UPSTREAM_URL = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"

BOT_NAME = "github-actions[bot]"
BOT_EMAIL = "41898282+github-actions[bot]@users.noreply.github.com"
PACKAGE_NAME = "codex-app-bin-native-build"
RELEASE_NOTES = f"Mirror of {UPSTREAM_URL}"
NATIVE_MODULES = (
    "better-sqlite3",
    "node-pty",
)


def release_asset_name(version: str) -> str:
    return f"Codex-{version}.dmg"


def release_asset_url(repo: str, version: str) -> str:
    return f"https://github.com/{repo}/releases/download/{version}/{release_asset_name(version)}"


def run(*args: str, cwd: Path | None = None, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess[str]:
    print(f"+ {shlex.join(args)}")
    return subprocess.run(
        list(args),
        cwd=cwd,
        text=True,
        check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )


def read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text())


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n")


def prefetch_upstream_dmg() -> tuple[Path, str]:
    print("Fetching the upstream DMG into the Nix store")
    result = run(
        "nix-prefetch-url",
        "--type",
        "sha256",
        "--print-path",
        UPSTREAM_URL,
        capture=True,
    )
    lines = result.stdout.strip().splitlines()
    nix_base32_hash = lines[-2]
    store_path = Path(lines[-1])
    sri_hash = run(
        "nix",
        "hash",
        "to-sri",
        "--type",
        "sha256",
        nix_base32_hash,
        capture=True,
    ).stdout.strip().splitlines()[-1]
    return store_path, sri_hash


def extract_dmg(dmg_path: Path, workdir: Path) -> tuple[Path, Path]:
    extract_root = workdir / "dmg"
    run("7z", "x", "-y", str(dmg_path), f"-o{extract_root}", check=False)

    app_dir = extract_root / "Codex Installer" / "Codex.app"
    if not app_dir.exists():
        raise RuntimeError(f"failed to extract app bundle from {dmg_path}")

    app_root = workdir / "app"
    run("asar", "extract", str(app_dir / "Contents" / "Resources" / "app.asar"), str(app_root))
    return app_dir, app_root


def read_version(app_dir: Path) -> str:
    with (app_dir / "Contents" / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    return str(info["CFBundleShortVersionString"])


def read_native_module_versions(app_root: Path) -> dict[str, str]:
    versions: dict[str, str] = {}
    for module_name in NATIVE_MODULES:
        package_json = app_root / "node_modules" / module_name / "package.json"
        versions[module_name] = json.loads(package_json.read_text())["version"]
    return versions


def write_package_json(versions: dict[str, str]) -> None:
    package_json = {
        "name": PACKAGE_NAME,
        "private": True,
        "dependencies": {
            "better-sqlite3": versions["better-sqlite3"],
            "node-pty": versions["node-pty"],
        },
    }
    write_json(PACKAGE_JSON_PATH, package_json)


def compute_npm_deps_hash() -> str:
    tool_path = run(
        "nix",
        "build",
        "nixpkgs#prefetch-npm-deps",
        "--no-link",
        "--print-out-paths",
        capture=True,
    ).stdout.strip().splitlines()[-1]
    result = run(
        f"{tool_path}/bin/prefetch-npm-deps",
        str(PACKAGE_LOCK_PATH),
        capture=True,
    )
    return result.stdout.strip().splitlines()[-1]


def refresh_package_lock() -> None:
    run(
        "npm",
        "install",
        "--package-lock-only",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        cwd=ROOT,
    )


def build_release_package() -> None:
    print("Building the release package before committing metadata")
    run("nix", "build", ".#codex-app-bin", "--no-link", cwd=ROOT)


def git_configure_bot() -> None:
    run("git", "config", "user.name", BOT_NAME, cwd=ROOT)
    run("git", "config", "user.email", BOT_EMAIL, cwd=ROOT)


def git_has_staged_changes() -> bool:
    result = run("git", "diff", "--cached", "--quiet", cwd=ROOT, check=False)
    return result.returncode != 0


def git_commit_and_push(version: str) -> str:
    git_configure_bot()
    run("git", "add", META_PATH.name, PACKAGE_JSON_PATH.name, PACKAGE_LOCK_PATH.name, cwd=ROOT)
    if not git_has_staged_changes():
        return run("git", "rev-parse", "HEAD", cwd=ROOT, capture=True).stdout.strip()

    run("git", "commit", "-m", f"update Codex {version}", cwd=ROOT)
    run("git", "push", "origin", "main", cwd=ROOT)
    return run("git", "rev-parse", "HEAD", cwd=ROOT, capture=True).stdout.strip()


def remote_tag_exists(tag: str) -> bool:
    result = run("git", "ls-remote", "--tags", "origin", tag, cwd=ROOT, capture=True)
    return bool(result.stdout.strip())


def read_release_info(tag: str, repo: str) -> dict | None:
    result = run(
        "gh",
        "release",
        "view",
        tag,
        "--repo",
        repo,
        "--json",
        "tagName,assets",
        cwd=ROOT,
        capture=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


def ensure_release(version: str, dmg_path: Path, target_commit: str, repo: str) -> None:
    tag = version
    asset_name = release_asset_name(version)

    release_info = read_release_info(tag, repo)
    if release_info is None:
        with tempfile.TemporaryDirectory() as tmpdir_name:
            asset_path = Path(tmpdir_name) / asset_name
            shutil.copy2(dmg_path, asset_path)
            run(
                "gh",
                "release",
                "create",
                tag,
                str(asset_path),
                "--repo",
                repo,
                "--target",
                target_commit,
                "--title",
                f"Codex {version}",
                "--notes",
                RELEASE_NOTES,
                cwd=ROOT,
            )
        return

    asset_names = {asset["name"] for asset in release_info.get("assets", [])}
    if asset_name not in asset_names:
        with tempfile.TemporaryDirectory() as tmpdir_name:
            asset_path = Path(tmpdir_name) / asset_name
            shutil.copy2(dmg_path, asset_path)
            run(
                "gh",
                "release",
                "upload",
                tag,
                str(asset_path),
                "--repo",
                repo,
                "--clobber",
                cwd=ROOT,
            )

def main() -> int:
    github_repo = os.environ.get("GITHUB_REPOSITORY", "").strip() or None
    if github_repo is None:
        raise RuntimeError("GITHUB_REPOSITORY must be set")

    current_meta = read_json(META_PATH)
    original_meta_text = META_PATH.read_text()
    original_package_json_text = PACKAGE_JSON_PATH.read_text()
    original_package_lock_text = PACKAGE_LOCK_PATH.read_text()

    with tempfile.TemporaryDirectory() as tmpdir_name:
        tmpdir = Path(tmpdir_name)
        dmg_path, sha256 = prefetch_upstream_dmg()

        app_dir, app_root = extract_dmg(dmg_path, tmpdir)
        version = read_version(app_dir)
        release_url = release_asset_url(github_repo, version)

        module_versions = read_native_module_versions(app_root)
        write_package_json(module_versions)
        refresh_package_lock()
        npm_deps_hash = compute_npm_deps_hash()

        next_meta = {
            "version": version,
            "url": release_url,
            "sha256": sha256,
            "npmDepsHash": npm_deps_hash,
        }

        if current_meta == next_meta:
            print(f"Codex {version} is up to date")
            ensure_release(
                version=version,
                dmg_path=dmg_path,
                target_commit=run("git", "rev-parse", "HEAD", cwd=ROOT, capture=True).stdout.strip(),
                repo=github_repo,
            )
            return 0

        if remote_tag_exists(version):
            raise RuntimeError(f"tag {version} already exists but upstream sha256 changed")

        staged_meta = dict(next_meta)
        staged_meta["url"] = dmg_path.as_uri()
        write_json(META_PATH, staged_meta)

        try:
            build_release_package()
        except Exception:
            META_PATH.write_text(original_meta_text)
            PACKAGE_JSON_PATH.write_text(original_package_json_text)
            PACKAGE_LOCK_PATH.write_text(original_package_lock_text)
            raise

        write_json(META_PATH, next_meta)
        target_commit = git_commit_and_push(version)
        # The metadata update is now committed, so publish the matching GitHub
        # release state for this exact repository revision.
        ensure_release(version=version, dmg_path=dmg_path, target_commit=target_commit, repo=github_repo)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
