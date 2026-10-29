"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { Transform } = require("node:stream");
const { pipeline } = require("node:stream/promises");

const { getPlatformArtifact } = require("./platform");

const pkg = require(path.join(__dirname, "..", "package.json"));
const rootDir = path.join(__dirname, "..");
const distDir = path.join(rootDir, "dist");
const binaryName = process.platform === "win32" ? "skybridge.exe" : "skybridge";
const MAX_ARCHIVE_BYTES = 512 * 1024 * 1024;
const MAX_BINARY_BYTES = 256 * 1024 * 1024;
const MAX_CHECKSUM_BYTES = 1024 * 1024;
const MAX_REDIRECTS = 5;
const REQUEST_TIMEOUT_MS = 30_000;

async function main() {
  const artifact = getPlatformArtifact();
  const embeddedAsset = loadEmbeddedAssetRecord(
    path.join(rootDir, "release-assets.json"),
    artifact,
    pkg.version,
  );
  const releaseTag = `skybridge-cli-v${pkg.version}`;
  const configuredBaseUrl =
    process.env.SKYBRIDGE_NPM_BASE_URL ||
    `https://github.com/billlza/Skybridge-Compass/releases/download/${releaseTag}`;
  const baseUrl = validateBaseUrl(configuredBaseUrl);

  const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "skybridge-cli-"));
  const archivePath = path.join(tempDir, artifact.archiveName);
  const checksumPath = path.join(tempDir, "SHA256SUMS.txt");
  const extractedBinaryPath = path.join(tempDir, binaryName);
  try {
    await downloadToFile(
      `${baseUrl}/${artifact.archiveName}`,
      archivePath,
      embeddedAsset.sizeBytes,
    );
    await downloadToFile(`${baseUrl}/SHA256SUMS.txt`, checksumPath, MAX_CHECKSUM_BYTES);
    verifyChecksum(archivePath, artifact.archiveName, checksumPath, embeddedAsset);
    extractBinary(archivePath, extractedBinaryPath, artifact);

    fs.mkdirSync(distDir, { recursive: true, mode: 0o700 });
    const distMetadata = fs.lstatSync(distDir);
    if (!distMetadata.isDirectory() || distMetadata.isSymbolicLink()) {
      throw new Error("npm package dist path must be a real directory");
    }
    const finalPath = path.join(distDir, binaryName);
    fs.copyFileSync(extractedBinaryPath, finalPath, fs.constants.COPYFILE_EXCL);
    if (process.platform !== "win32") {
      fs.chmodSync(finalPath, 0o755);
    }
    console.log(`skybridge npm wrapper: installed ${artifact.archiveName} to ${finalPath}`);
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true });
  }
}

function validateBaseUrl(value) {
  let parsed;
  try {
    parsed = new URL(value);
  } catch (error) {
    throw new Error(`invalid SKYBRIDGE_NPM_BASE_URL: ${error.message}`);
  }
  if (parsed.protocol !== "https:") {
    throw new Error("SKYBRIDGE_NPM_BASE_URL must use HTTPS");
  }
  if (parsed.username || parsed.password || parsed.search || parsed.hash) {
    throw new Error("SKYBRIDGE_NPM_BASE_URL must not contain credentials, a query, or a fragment");
  }
  parsed.pathname = parsed.pathname.replace(/\/+$/, "");
  if (!parsed.pathname) {
    throw new Error("SKYBRIDGE_NPM_BASE_URL must include a path");
  }
  return parsed.toString().replace(/\/$/, "");
}

function isAllowedRedirect(current, redirected) {
  if (current.origin === redirected.origin) {
    return true;
  }
  const currentIsGitHub =
    current.hostname === "github.com" || current.hostname.endsWith(".githubusercontent.com");
  const redirectedIsGitHubAsset = redirected.hostname.endsWith(".githubusercontent.com");
  return currentIsGitHub && redirectedIsGitHubAsset;
}

function loadEmbeddedAssetRecord(manifestPath, artifact, version) {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  if (
    manifest.schemaVersion !== 1 ||
    manifest.version !== version ||
    !/^[0-9a-f]{40}$/.test(manifest.sourceSha) ||
    !Array.isArray(manifest.assets)
  ) {
    throw new Error("embedded release asset manifest has an invalid identity");
  }
  const expectedNames = new Set([
    "skybridge-aarch64-apple-darwin.tar.gz",
    "skybridge-aarch64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-pc-windows-msvc.zip",
  ]);
  const byName = new Map();
  for (const record of manifest.assets) {
    if (
      !record ||
      typeof record !== "object" ||
      !expectedNames.has(record.name) ||
      byName.has(record.name) ||
      !/^[0-9a-f]{64}$/.test(record.sha256) ||
      !Number.isSafeInteger(record.sizeBytes) ||
      record.sizeBytes <= 0 ||
      record.sizeBytes > MAX_ARCHIVE_BYTES ||
      Object.keys(record).sort().join(",") !== "name,sha256,sizeBytes"
    ) {
      throw new Error("embedded release asset manifest contains an invalid record");
    }
    byName.set(record.name, record);
  }
  if (byName.size !== expectedNames.size) {
    throw new Error("embedded release asset manifest does not cover the exact platform set");
  }
  const selected = byName.get(artifact.archiveName);
  if (!selected) {
    throw new Error(`embedded release asset manifest does not support ${artifact.archiveName}`);
  }
  return selected;
}

class ByteLimitTransform extends Transform {
  constructor(limit, description) {
    super();
    this.limit = limit;
    this.description = description;
    this.received = 0;
  }

  _transform(chunk, encoding, callback) {
    this.received += chunk.length;
    if (this.received > this.limit) {
      callback(new Error(`${this.description} exceeds ${this.limit} bytes`));
      return;
    }
    callback(null, chunk);
  }
}

function downloadToFile(url, destination, maximumBytes, redirectCount = 0) {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    return Promise.reject(new Error("download size limit must be a positive safe integer"));
  }
  const parsed = new URL(url);
  if (parsed.protocol !== "https:" || parsed.username || parsed.password) {
    return Promise.reject(new Error(`refusing insecure download URL: ${url}`));
  }
  return new Promise((resolve, reject) => {
    const request = https.get(parsed, async (response) => {
      try {
        if (
          response.statusCode &&
          response.statusCode >= 300 &&
          response.statusCode < 400 &&
          response.headers.location
        ) {
          response.resume();
          if (redirectCount >= MAX_REDIRECTS) {
            throw new Error(`too many redirects while downloading ${url}`);
          }
          const redirected = new URL(response.headers.location, parsed);
          if (
            redirected.protocol !== "https:" ||
            redirected.username ||
            redirected.password ||
            !isAllowedRedirect(parsed, redirected)
          ) {
            throw new Error(`refusing insecure redirect while downloading ${url}`);
          }
          await downloadToFile(
            redirected.toString(),
            destination,
            maximumBytes,
            redirectCount + 1,
          );
          resolve();
          return;
        }
        if (response.statusCode !== 200) {
          response.resume();
          throw new Error(`download failed for ${url}: status ${response.statusCode}`);
        }
        const contentLength = response.headers["content-length"];
        if (contentLength !== undefined) {
          if (!/^(0|[1-9][0-9]*)$/.test(contentLength)) {
            throw new Error(`invalid Content-Length while downloading ${url}`);
          }
          if (Number(contentLength) > maximumBytes) {
            throw new Error(`download exceeds the size limit for ${url}`);
          }
        }
        const output = fs.createWriteStream(destination, { flags: "wx", mode: 0o600 });
        await pipeline(
          response,
          new ByteLimitTransform(maximumBytes, path.basename(destination)),
          output,
        );
        resolve();
      } catch (error) {
        let reportedError = error;
        try {
          fs.rmSync(destination, { force: true });
        } catch (cleanupError) {
          reportedError = new AggregateError(
            [error, cleanupError],
            `download failed and partial-file cleanup also failed for ${destination}`,
          );
        }
        reject(reportedError);
      }
    });
    request.setTimeout(REQUEST_TIMEOUT_MS, () => {
      request.destroy(new Error(`download timed out for ${url}`));
    });
    request.on("error", (error) => {
      try {
        fs.rmSync(destination, { force: true });
        reject(error);
      } catch (cleanupError) {
        reject(
          new AggregateError(
            [error, cleanupError],
            `request failed and partial-file cleanup also failed for ${destination}`,
          ),
        );
      }
    });
  });
}

function verifyChecksum(archivePath, archiveName, checksumPath, embeddedAsset) {
  const lines = fs.readFileSync(checksumPath, "utf8").split(/\r?\n/);
  const checksums = new Map();
  for (const line of lines) {
    if (line === "") {
      continue;
    }
    const match = /^([0-9a-f]{64})  ([A-Za-z0-9_.+-]+)$/.exec(line);
    if (!match) {
      throw new Error("SHA256SUMS.txt contains a non-canonical entry");
    }
    const [, digest, name] = match;
    if (checksums.has(name)) {
      throw new Error(`SHA256SUMS.txt contains a duplicate entry for ${name}`);
    }
    checksums.set(name, digest);
  }
  const expected = checksums.get(archiveName);
  if (!expected) {
    throw new Error(`SHA256SUMS.txt did not contain an entry for ${archiveName}`);
  }
  if (expected !== embeddedAsset.sha256) {
    throw new Error(`public checksum does not match the embedded npm digest for ${archiveName}`);
  }
  const metadata = fs.lstatSync(archivePath);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size !== embeddedAsset.sizeBytes) {
    throw new Error(`downloaded size does not match the embedded npm record for ${archiveName}`);
  }
  const actual = crypto.createHash("sha256").update(fs.readFileSync(archivePath)).digest("hex");
  if (expected !== actual) {
    throw new Error(`checksum mismatch for ${archiveName}`);
  }
}

function extractBinary(archivePath, destination, artifact) {
  if (artifact.archiveExtension === "zip") {
    extractZipBinary(archivePath, destination, artifact.binaryName);
  } else if (artifact.archiveExtension === "tar.gz") {
    extractTarBinary(archivePath, destination, artifact.binaryName);
  } else {
    throw new Error(`unsupported archive extension: ${artifact.archiveExtension}`);
  }
  const metadata = fs.lstatSync(destination);
  if (!metadata.isFile() || metadata.isSymbolicLink() || metadata.size <= 0) {
    throw new Error(`archive did not produce one regular ${artifact.binaryName} binary`);
  }
  if (metadata.size > MAX_BINARY_BYTES) {
    throw new Error(`extracted ${artifact.binaryName} exceeds the binary size limit`);
  }
}

function extractTarBinary(archivePath, destination, expectedName) {
  const listing = spawnSync("tar", ["-tzf", archivePath], {
    encoding: "utf8",
    maxBuffer: MAX_CHECKSUM_BYTES,
  });
  if (listing.status !== 0) {
    throw new Error(listing.stderr?.trim() || "failed to inspect tar archive");
  }
  const members = listing.stdout.split(/\r?\n/).filter(Boolean);
  if (members.length !== 1 || members[0] !== expectedName) {
    throw new Error(`tar archive must contain exactly one top-level ${expectedName}`);
  }
  const verbose = spawnSync("tar", ["-tvzf", archivePath], {
    encoding: "utf8",
    maxBuffer: MAX_CHECKSUM_BYTES,
  });
  if (verbose.status !== 0 || !verbose.stdout.trimStart().startsWith("-")) {
    throw new Error(`tar archive member ${expectedName} must be a regular file`);
  }
  const extraction = spawnSync("tar", ["-xOzf", archivePath, expectedName], {
    encoding: null,
    maxBuffer: MAX_BINARY_BYTES,
  });
  if (extraction.status !== 0) {
    throw new Error(extraction.stderr?.toString("utf8").trim() || "failed to read tar binary");
  }
  if (!Buffer.isBuffer(extraction.stdout) || extraction.stdout.length <= 0) {
    throw new Error(`tar archive contained an empty ${expectedName}`);
  }
  fs.writeFileSync(destination, extraction.stdout, { flag: "wx", mode: 0o700 });
}

function extractZipBinary(archivePath, destination, expectedName) {
  const command = [
    "$ErrorActionPreference = 'Stop'",
    "Add-Type -AssemblyName System.IO.Compression.FileSystem",
    `$zip = [System.IO.Compression.ZipFile]::OpenRead('${escapePowerShell(archivePath)}')`,
    "try {",
    `  if ($zip.Entries.Count -ne 1) { throw 'zip archive must contain exactly one entry' }`,
    "  $entry = $zip.Entries[0]",
    `  if ($entry.FullName -cne '${escapePowerShell(expectedName)}') { throw 'unexpected zip entry name' }`,
    `  if ($entry.Length -le 0 -or $entry.Length -gt ${MAX_BINARY_BYTES}) { throw 'invalid zip entry size' }`,
    "  $input = $entry.Open()",
    `  $output = [System.IO.File]::Open('${escapePowerShell(destination)}', [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)`,
    "  try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }",
    "} finally { $zip.Dispose() }",
  ].join("; ");
  const extraction = spawnSync(
    "powershell",
    ["-NoLogo", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command],
    { encoding: "utf8", maxBuffer: MAX_CHECKSUM_BYTES },
  );
  if (extraction.status !== 0) {
    throw new Error(extraction.stderr?.trim() || "failed to extract zip binary");
  }
}

function escapePowerShell(value) {
  return value.replace(/'/g, "''");
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`skybridge npm wrapper install failed: ${error.message}`);
    process.exit(1);
  });
}

module.exports = {
  ByteLimitTransform,
  downloadToFile,
  extractBinary,
  extractTarBinary,
  extractZipBinary,
  loadEmbeddedAssetRecord,
  isAllowedRedirect,
  validateBaseUrl,
  verifyChecksum,
};
