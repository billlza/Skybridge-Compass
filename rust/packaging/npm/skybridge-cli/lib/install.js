"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const https = require("node:https");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const { getPlatformArtifact } = require("./platform");

const pkg = require(path.join(__dirname, "..", "package.json"));
const rootDir = path.join(__dirname, "..");
const distDir = path.join(rootDir, "dist");
const binaryName = process.platform === "win32" ? "skybridge.exe" : "skybridge";

async function main() {
  if (process.env.SKYBRIDGE_NPM_SKIP_DOWNLOAD === "1") {
    console.log("skybridge npm wrapper: skipping binary download because SKYBRIDGE_NPM_SKIP_DOWNLOAD=1");
    return;
  }

  const artifact = getPlatformArtifact();
  const releaseTag = `skybridge-cli-v${pkg.version}`;
  const baseUrl =
    process.env.SKYBRIDGE_NPM_BASE_URL ||
    `https://github.com/billlza/Skybridge-Compass/releases/download/${releaseTag}`;

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "skybridge-cli-"));
  const archivePath = path.join(tempDir, artifact.archiveName);
  const checksumPath = path.join(tempDir, "SHA256SUMS.txt");
  const skipChecksum = process.env.SKYBRIDGE_NPM_SKIP_CHECKSUM === "1";
  try {
    await downloadToFile(`${baseUrl}/${artifact.archiveName}`, archivePath);
    if (!skipChecksum) {
      await downloadToFile(`${baseUrl}/SHA256SUMS.txt`, checksumPath);
      verifyChecksum(archivePath, artifact.archiveName, checksumPath);
    }

    const extractDir = path.join(tempDir, "extract");
    fs.mkdirSync(extractDir, { recursive: true });
    extractArchive(archivePath, extractDir, artifact.archiveExtension);
    const extractedBinary = findFile(extractDir, artifact.binaryName);
    if (!extractedBinary) {
      throw new Error(`archive ${artifact.archiveName} did not contain ${artifact.binaryName}`);
    }

    fs.mkdirSync(distDir, { recursive: true });
    const finalPath = path.join(distDir, binaryName);
    fs.copyFileSync(extractedBinary, finalPath);
    if (process.platform !== "win32") {
      fs.chmodSync(finalPath, 0o755);
    }
    console.log(`skybridge npm wrapper: installed ${artifact.archiveName} to ${finalPath}`);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function downloadToFile(url, destination) {
  return new Promise((resolve, reject) => {
    const client = url.startsWith("https:") ? https : http;
    const request = client.get(url, (response) => {
      if (
        response.statusCode &&
        response.statusCode >= 300 &&
        response.statusCode < 400 &&
        response.headers.location
      ) {
        const redirected = new URL(response.headers.location, url).toString();
        response.resume();
        downloadToFile(redirected, destination).then(resolve).catch(reject);
        return;
      }
      if (response.statusCode !== 200) {
        reject(new Error(`download failed for ${url}: status ${response.statusCode}`));
        response.resume();
        return;
      }
      const output = fs.createWriteStream(destination);
      output.on("finish", () => {
        output.close(resolve);
      });
      output.on("error", reject);
      response.on("error", reject);
      response.pipe(output);
    });
    request.on("error", reject);
  });
}

function verifyChecksum(archivePath, archiveName, checksumPath) {
  const sums = fs.readFileSync(checksumPath, "utf8");
  const expectedLine = sums
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.endsWith(` ${archiveName}`) || line.endsWith(` *${archiveName}`));
  if (!expectedLine) {
    throw new Error(`SHA256SUMS.txt did not contain an entry for ${archiveName}`);
  }
  const expected = expectedLine.split(/\s+/)[0].toLowerCase();
  const actual = crypto
    .createHash("sha256")
    .update(fs.readFileSync(archivePath))
    .digest("hex");
  if (expected !== actual) {
    throw new Error(`checksum mismatch for ${archiveName}`);
  }
}

function extractArchive(archivePath, extractDir, archiveExtension) {
  const result =
    archiveExtension === "zip"
      ? spawnSync(
          "powershell",
          [
            "-NoLogo",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-Command",
            `Expand-Archive -LiteralPath '${escapePowerShell(archivePath)}' -DestinationPath '${escapePowerShell(extractDir)}' -Force`,
          ],
          { stdio: "pipe" },
        )
      : spawnSync("tar", ["-xzf", archivePath, "-C", extractDir], { stdio: "pipe" });

  if (result.status !== 0) {
    const stderr = result.stderr?.toString("utf8").trim();
    throw new Error(stderr || `failed to extract ${path.basename(archivePath)}`);
  }
}

function findFile(root, expectedName) {
  const entries = fs.readdirSync(root, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      const nested = findFile(fullPath, expectedName);
      if (nested) {
        return nested;
      }
      continue;
    }
    if (entry.isFile() && entry.name === expectedName) {
      return fullPath;
    }
  }
  return null;
}

function escapePowerShell(value) {
  return value.replace(/'/g, "''");
}

main().catch((error) => {
  console.error(`skybridge npm wrapper install failed: ${error.message}`);
  process.exit(1);
});
