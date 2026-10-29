"use strict";

const PLATFORM_MATRIX = {
  darwin: {
    arm64: {
      targetTriple: "aarch64-apple-darwin",
      archiveExtension: "tar.gz",
      binaryName: "skybridge",
    },
  },
  linux: {
    arm64: {
      targetTriple: "aarch64-unknown-linux-gnu",
      archiveExtension: "tar.gz",
      binaryName: "skybridge",
    },
    x64: {
      targetTriple: "x86_64-unknown-linux-gnu",
      archiveExtension: "tar.gz",
      binaryName: "skybridge",
    },
  },
  win32: {
    x64: {
      targetTriple: "x86_64-pc-windows-msvc",
      archiveExtension: "zip",
      binaryName: "skybridge.exe",
    },
  },
};

function getPlatformArtifact(platform = process.platform, arch = process.arch) {
  const platformMap = PLATFORM_MATRIX[platform];
  if (!platformMap || !platformMap[arch]) {
    throw new Error(`unsupported platform/arch: ${platform}/${arch}`);
  }
  const descriptor = platformMap[arch];
  const archiveName = `skybridge-${descriptor.targetTriple}.${descriptor.archiveExtension}`;
  return {
    ...descriptor,
    archiveName,
  };
}

module.exports = {
  getPlatformArtifact,
};
