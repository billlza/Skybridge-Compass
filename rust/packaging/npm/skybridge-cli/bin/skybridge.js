#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const binaryName = process.platform === "win32" ? "skybridge.exe" : "skybridge";
const binaryPath = path.join(__dirname, "..", "dist", binaryName);

if (!fs.existsSync(binaryPath)) {
  console.error(
    [
      "skybridge binary is not installed for this npm package yet.",
      "Reinstall the package or run `node ./lib/install.js` inside the package directory.",
    ].join(" "),
  );
  process.exit(1);
}

const result = spawnSync(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
});

if (result.error) {
  console.error(`failed to launch ${binaryName}: ${result.error.message}`);
  process.exit(1);
}

if (typeof result.status === "number") {
  process.exit(result.status);
}

process.exit(1);
