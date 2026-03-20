{
  lib,
  stdenvNoCC,
  buildNpmPackage,
  fetchurl,
  electron_40,
  p7zip,
  libicns,
  nodePackages,
  nodejs_20,
  gcc,
  gnumake,
  pkg-config,
  coreutils,
  findutils,
  procps,
  python3,
  codex,
  dconf,
  gtk3,
  gtk4,
  gsettings-desktop-schemas,
  librsvg,
}:
let
  meta = builtins.fromJSON (builtins.readFile ./meta.json);
  pname = "codex-app-bin";
  version = meta.version;

  codexDmg = fetchurl {
    url = meta.url;
    hash = meta.sha256;
  };

  nativeModules = buildNpmPackage {
    pname = "${pname}-native-modules";
    inherit version;
    src = ./.;
    npmDepsHash = meta.npmDepsHash;
    nodejs = nodejs_20;
    dontNpmBuild = true;
    npmRebuildFlags = [ "--ignore-scripts" ];
    nativeBuildInputs = [
      gcc
      gnumake
      pkg-config
    ];

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      export npm_config_nodedir="${electron_40.headers}"
      export npm_config_runtime=electron
      export npm_config_target="${electron_40.version}"
      export npm_config_build_from_source=true
      export npm_config_offline=true

      pushd node_modules/better-sqlite3
      npm run install
      popd

      pushd node_modules/node-pty
      npm run install
      popd

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/node_modules"
      cp -a node_modules/better-sqlite3 "$out/node_modules/"
      cp -a node_modules/node-pty "$out/node_modules/"

      runHook postInstall
    '';
  };

  xdgDataDirs = lib.concatStringsSep ":" [
    "${gtk4}/share/gsettings-schemas/${gtk4.name}"
    "${gtk3}/share/gsettings-schemas/${gtk3.name}"
    "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}"
  ];
in
stdenvNoCC.mkDerivation (finalAttrs: {
  inherit pname version;
  src = codexDmg;
  dontUnpack = true;

  nativeBuildInputs = [
    p7zip
    libicns
    nodePackages.asar
  ];

  buildPhase = ''
    runHook preBuild

    workDir="$TMPDIR/codex-build"
    appDir="$workDir/dmg/Codex Installer/Codex.app"
    resourcesDir="$appDir/Contents/Resources"

    mkdir -p "$workDir"
    7z x -y "$src" -o"$workDir/dmg" >/dev/null || true

    asar extract "$resourcesDir/app.asar" "$workDir/app"

    if [ -d "$resourcesDir/app.asar.unpacked" ]; then
      cp -a "$resourcesDir/app.asar.unpacked/." "$workDir/app/"
    fi

    cat > "$workDir/app/.vite/build/linux-window-icon.cjs" <<'EOF'
if (process.platform === "linux" && process.type === "browser") {
  const fs = require("node:fs");
  const path = require("node:path");
  const electron = require("electron");

  const iconPath = path.join(process.resourcesPath, "codex-app-icon.png");

  if (fs.existsSync(iconPath)) {
    const icon = electron.nativeImage.createFromPath(iconPath);

    if (!icon.isEmpty()) {
      const setWindowIcon = (window) => {
        if (typeof window?.setIcon === "function") {
          window.setIcon(icon);
        }
      };

      electron.app.on("browser-window-created", (_event, window) => {
        setWindowIcon(window);
        window.once("ready-to-show", () => {
          setWindowIcon(window);
        });
      });

      for (const window of electron.BrowserWindow.getAllWindows()) {
        setWindowIcon(window);
      }
    }
  }
}
EOF

    BOOTSTRAP_FILE="$workDir/app/.vite/build/bootstrap.js" ${python3}/bin/python3 - <<'PY'
import os
import pathlib
import re

path = pathlib.Path(os.environ["BOOTSTRAP_FILE"])
text = path.read_text()

if 'require("./linux-window-icon.cjs");' not in text:
    pattern = re.compile(r'require\((["\'])\./bootstrap-[^"\']+\.js\1\);')

    def inject(match):
        return 'require("./linux-window-icon.cjs");\n' + match.group(0)

    text, replacements = pattern.subn(inject, text, count=1)
    if replacements != 1:
        raise SystemExit(f"failed to patch {path}: expected 1 bootstrap chunk require, got {replacements}")
    path.write_text(text)
PY

    rm -rf "$workDir/app/node_modules/sparkle-darwin"
    find "$workDir/app" -name sparkle.node -delete

    rm -rf "$workDir/app/node_modules/better-sqlite3" "$workDir/app/node_modules/node-pty"
    cp -a "${nativeModules}/node_modules/better-sqlite3" "$workDir/app/node_modules/"
    cp -a "${nativeModules}/node_modules/node-pty" "$workDir/app/node_modules/"

    mkdir -p "$workDir/webview"
    if [ -d "$workDir/app/webview" ]; then
      cp -a "$workDir/app/webview/." "$workDir/webview/"
    fi

    mkdir -p "$workDir/icons"
    if [ -f "$resourcesDir/electron.icns" ]; then
      icns2png -x -o "$workDir/icons" "$resourcesDir/electron.icns" >/dev/null
    fi

    asar pack "$workDir/app" "$workDir/app.asar" --unpack "{*.node,*.so,*.dylib}" >/dev/null

    if [ -f "$workDir/app/node_modules/node-pty/build/Release/spawn-helper" ]; then
      mkdir -p "$workDir/app.asar.unpacked/node_modules/node-pty/build/Release"
      cp -a \
        "$workDir/app/node_modules/node-pty/build/Release/spawn-helper" \
        "$workDir/app.asar.unpacked/node_modules/node-pty/build/Release/"
      chmod +x "$workDir/app.asar.unpacked/node_modules/node-pty/build/Release/spawn-helper"
    fi

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    workDir="$TMPDIR/codex-build"
    installRoot="$out/libexec/${pname}"

    mkdir -p "$installRoot/resources" "$out/share/${pname}/webview" "$out/bin"
    cp -a "${electron_40.dist}/." "$installRoot/"
    chmod -R u+w "$installRoot"
    rm -f "$installRoot/resources/default_app.asar"

    cp "$workDir/app.asar" "$installRoot/resources/app.asar"
    if [ -d "$workDir/app.asar.unpacked" ]; then
      cp -a "$workDir/app.asar.unpacked" "$installRoot/resources/"
    fi

    if [ -d "$workDir/webview" ]; then
      cp -a "$workDir/webview/." "$out/share/${pname}/webview/"
    fi

    mkdir -p "$out/share/icons/hicolor"
    if [ -d "$workDir/icons" ]; then
      for icon in "$workDir"/icons/*.png; do
        [ -e "$icon" ] || continue
        size="$(basename "$icon" | sed -E 's/.*_([0-9]+)x.*/\1/')"
        install -Dm644 "$icon" "$out/share/icons/hicolor/$size"x"$size/apps/${pname}.png"
      done
    fi

    if [ -f "$out/share/icons/hicolor/512x512/apps/${pname}.png" ]; then
      cp "$out/share/icons/hicolor/512x512/apps/${pname}.png" \
        "$installRoot/resources/codex-app-icon.png"
    fi

    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/${pname}.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Codex
Comment=Codex Desktop for Linux
Exec=$out/bin/${pname}
Icon=${pname}
Terminal=false
Categories=Development;
StartupWMClass=Codex
EOF

    cat > "$out/bin/${pname}" <<'EOF'
#!@bash@
set -euo pipefail

APP_DIR="@appDir@"
WEBVIEW_DIR="@webviewDir@"
DEFAULT_GIO_EXTRA_MODULES="@gioExtraModules@"
DEFAULT_GDK_PIXBUF_MODULE_FILE="@gdkPixbufModuleFile@"
DEFAULT_XDG_DATA_DIRS="@xdgDataDirs@"
DEFAULT_CHROME_DEVEL_SANDBOX="@chromeSandbox@"
DEFAULT_CODEX_CLI_PATH="@defaultCodexCliPath@"

CURRENT_GIO_EXTRA_MODULES="''${GIO_EXTRA_MODULES-}"
CURRENT_XDG_DATA_DIRS="''${XDG_DATA_DIRS-}"
CURRENT_PATH="''${PATH-}"

export GDK_PIXBUF_MODULE_FILE="$DEFAULT_GDK_PIXBUF_MODULE_FILE"
export CHROME_DEVEL_SANDBOX="$DEFAULT_CHROME_DEVEL_SANDBOX"

if [ -n "$CURRENT_GIO_EXTRA_MODULES" ]; then
  export GIO_EXTRA_MODULES="$DEFAULT_GIO_EXTRA_MODULES:$CURRENT_GIO_EXTRA_MODULES"
else
  export GIO_EXTRA_MODULES="$DEFAULT_GIO_EXTRA_MODULES"
fi

if [ -n "$CURRENT_XDG_DATA_DIRS" ]; then
  export XDG_DATA_DIRS="$DEFAULT_XDG_DATA_DIRS:$CURRENT_XDG_DATA_DIRS"
else
  export XDG_DATA_DIRS="$DEFAULT_XDG_DATA_DIRS"
fi

@pkill@ -f '@python@ -m http.server 5175' 2>/dev/null || true
@sleep@ 0.3

if [ -d "$WEBVIEW_DIR" ] && [ -n "$(@find@ "$WEBVIEW_DIR" -mindepth 1 -print -quit)" ]; then
  cd "$WEBVIEW_DIR"
  @python@ -m http.server 5175 >/dev/null 2>&1 &
  HTTP_PID=$!
  trap 'kill "$HTTP_PID" 2>/dev/null || true' EXIT INT TERM
fi

if [ ! -x "$DEFAULT_CODEX_CLI_PATH" ]; then
  echo "Error: bundled codex is not executable: $DEFAULT_CODEX_CLI_PATH" >&2
  exit 1
fi

CODEX_CLI_PATH="$DEFAULT_CODEX_CLI_PATH"
export CODEX_CLI_PATH
if [ -n "$CURRENT_PATH" ]; then
  export PATH="$(@dirname@ "$CODEX_CLI_PATH"):$CURRENT_PATH"
else
  export PATH="$(@dirname@ "$CODEX_CLI_PATH")"
fi

exec "$APP_DIR/electron" --no-sandbox "$@"
EOF

    substituteInPlace "$out/bin/${pname}" \
      --replace-fail "@bash@" "${stdenvNoCC.shell}" \
      --replace-fail "@appDir@" "$out/libexec/${pname}" \
      --replace-fail "@webviewDir@" "$out/share/${pname}/webview" \
      --replace-fail "@gioExtraModules@" "${lib.makeSearchPath "lib/gio/modules" [ dconf.lib ]}" \
      --replace-fail "@gdkPixbufModuleFile@" "${librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
      --replace-fail "@xdgDataDirs@" "${xdgDataDirs}" \
      --replace-fail "@chromeSandbox@" "$out/libexec/${pname}/chrome-sandbox" \
      --replace-fail "@defaultCodexCliPath@" "${lib.getExe codex}" \
      --replace-fail "@pkill@" "${procps}/bin/pkill" \
      --replace-fail "@sleep@" "${coreutils}/bin/sleep" \
      --replace-fail "@dirname@" "${coreutils}/bin/dirname" \
      --replace-fail "@find@" "${findutils}/bin/find" \
      --replace-fail "@python@" "${python3}/bin/python3"

    chmod +x "$out/bin/${pname}"

    runHook postInstall
  '';

  meta = {
    description = "Run the official Codex desktop app on Linux and NixOS";
    homepage = "https://openai.com/codex/";
    license = lib.licenses.unfree;
    mainProgram = pname;
    platforms = lib.platforms.linux;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
