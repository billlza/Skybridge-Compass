"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const {
  extractTarBinary,
  isAllowedRedirect,
  loadEmbeddedAssetRecord,
  validateBaseUrl,
  verifyChecksum,
} = require("../lib/install");


function temporaryRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "skybridge-cli-install-test-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}


function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}


test("release base URL is HTTPS-only and credential-free", () => {
  assert.equal(
    validateBaseUrl("https://github.com/billlza/Skybridge-Compass/releases/download/v1/"),
    "https://github.com/billlza/Skybridge-Compass/releases/download/v1",
  );
  assert.throws(() => validateBaseUrl("http://example.com/releases"), /must use HTTPS/);
  assert.throws(
    () => validateBaseUrl("https://token@example.com/releases"),
    /must not contain credentials/,
  );
  assert.equal(
    isAllowedRedirect(
      new URL("https://github.com/owner/repo/releases/download/v1/file"),
      new URL("https://release-assets.githubusercontent.com/file"),
    ),
    true,
  );
  assert.equal(
    isAllowedRedirect(
      new URL("https://github.com/owner/repo/releases/download/v1/file"),
      new URL("https://attacker.invalid/file"),
    ),
    false,
  );
});


test("embedded asset manifest covers the exact four archives", (t) => {
  const root = temporaryRoot(t);
  const manifestPath = path.join(root, "release-assets.json");
  const assets = [
    "skybridge-aarch64-apple-darwin.tar.gz",
    "skybridge-aarch64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-unknown-linux-gnu.tar.gz",
    "skybridge-x86_64-pc-windows-msvc.zip",
  ].map((name, index) => ({
    name,
    sha256: String(index).repeat(64),
    sizeBytes: index + 1,
  }));
  fs.writeFileSync(
    manifestPath,
    JSON.stringify({ schemaVersion: 1, version: "1.2.3", sourceSha: "a".repeat(40), assets }),
  );
  const record = loadEmbeddedAssetRecord(
    manifestPath,
    {
      archiveName: "skybridge-aarch64-apple-darwin.tar.gz",
    },
    "1.2.3",
  );
  assert.equal(record.sizeBytes, 1);

  const incomplete = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  incomplete.assets.pop();
  fs.writeFileSync(manifestPath, JSON.stringify(incomplete));
  assert.throws(
    () => loadEmbeddedAssetRecord(manifestPath, { archiveName: assets[0].name }, "1.2.3"),
    /exact platform set/,
  );
});


test("checksum must agree with both npm-embedded and downloaded bytes", (t) => {
  const root = temporaryRoot(t);
  const archiveName = "skybridge-aarch64-apple-darwin.tar.gz";
  const archivePath = path.join(root, archiveName);
  const checksumPath = path.join(root, "SHA256SUMS.txt");
  const bytes = Buffer.from("archive-bytes\n");
  const digest = sha256(bytes);
  fs.writeFileSync(archivePath, bytes);
  fs.writeFileSync(checksumPath, `${digest}  ${archiveName}\n`);
  verifyChecksum(archivePath, archiveName, checksumPath, {
    name: archiveName,
    sha256: digest,
    sizeBytes: bytes.length,
  });
  assert.throws(
    () =>
      verifyChecksum(archivePath, archiveName, checksumPath, {
        name: archiveName,
        sha256: "0".repeat(64),
        sizeBytes: bytes.length,
      }),
    /does not match the embedded npm digest/,
  );
});


test("tar extraction accepts one regular top-level binary", (t) => {
  const root = temporaryRoot(t);
  const stage = path.join(root, "stage");
  fs.mkdirSync(stage);
  fs.writeFileSync(path.join(stage, "skybridge"), "binary\n", { mode: 0o755 });
  const archive = path.join(root, "skybridge.tar.gz");
  const created = spawnSync("tar", ["-czf", archive, "-C", stage, "skybridge"], {
    encoding: "utf8",
  });
  assert.equal(created.status, 0, created.stderr);
  const output = path.join(root, "output");
  extractTarBinary(archive, output, "skybridge");
  assert.equal(fs.readFileSync(output, "utf8"), "binary\n");
});


test("tar extraction rejects a symlink masquerading as the binary", (t) => {
  const root = temporaryRoot(t);
  const stage = path.join(root, "stage");
  fs.mkdirSync(stage);
  fs.symlinkSync("/etc/passwd", path.join(stage, "skybridge"));
  const archive = path.join(root, "linked.tar.gz");
  const created = spawnSync("tar", ["-czf", archive, "-C", stage, "skybridge"], {
    encoding: "utf8",
  });
  assert.equal(created.status, 0, created.stderr);
  assert.throws(
    () => extractTarBinary(archive, path.join(root, "output"), "skybridge"),
    /must be a regular file/,
  );
});
