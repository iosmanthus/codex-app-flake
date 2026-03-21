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
