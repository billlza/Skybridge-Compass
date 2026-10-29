#!/usr/bin/env python3
"""Build pinned Apple libFLAC slices; stage replacements without overwriting existing artifacts."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import signal
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "Config/native-dependencies.lock.json"
FAMILY = "libflac"
INPUT_KEYS = {"architectures", "macos_deployment_target", "ios_deployment_target", "ios_sdk", "ios_simulator_sdk",
              "build_type", "linkage", "ogg", "cxx", "programs",
              "examples", "docs", "testing", "fortify_source", "stack_protector", "werror", "test_patch",
              "license_sha256", "official_release_archive_sha256"}


class BuildFailure(RuntimeError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-checkout", type=Path, required=True, help="Clean checkout at the locked commit; read only")
    parser.add_argument("--build-dir", type=Path, required=True, help="New directory whose parent already exists")
    parser.add_argument("--release-archive", type=Path, help="Optional cached official release tar.xz; checksum required")
    parser.add_argument("--stage-only", action="store_true",
                        help="Verify a candidate repository inside the build directory; leave installed artifacts intact")
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location("native_vendor_provenance", ROOT / "Scripts/native_vendor_provenance.py")
    if spec is None or spec.loader is None:
        raise BuildFailure("Cannot load native provenance verifier")
    provenance = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(provenance)
    family, _ = provenance.load_locked_family(LOCK, ROOT, FAMILY)
    if set(family["build_inputs"]) != INPUT_KEYS or len(family["sources"]) != 1:
        raise BuildFailure("libFLAC lock differs from the recipe contract")
    inputs = family["build_inputs"]
    expected = {"architectures":"macos-arm64,ios-arm64,ios-simulator-arm64,ios-simulator-x86_64",
                "macos_deployment_target":"14.0", "ios_deployment_target":"17.0", "build_type":"Release",
                "linkage":"static", "ogg":"false", "cxx":"false", "programs":"false", "examples":"false",
                "docs":"false", "testing":"true", "fortify_source":"2", "stack_protector":"strong", "werror":"true"}
    if any(inputs[key] != value for key, value in expected.items()):
        raise BuildFailure("Unsupported libFLAC build configuration")
    if provenance.toolchain_record() != family["toolchain"]:
        raise BuildFailure("Selected toolchain differs from the pinned libFLAC toolchain")
    for sdk, key in [("iphoneos", "ios_sdk"), ("iphonesimulator", "ios_simulator_sdk")]:
        if provenance.run("xcrun", "--sdk", sdk, "--show-sdk-version") != inputs[key]:
            raise BuildFailure(f"Selected {sdk} SDK differs from the pinned libFLAC build input")
    source = family["sources"][0]
    checkout = args.source_checkout.resolve(strict=True)
    source_spec = "|".join([source[key] for key in ["name", "version", "ref", "commit", "repository"]] + [str(checkout)])
    if provenance.parse_source(source_spec) != source:
        raise BuildFailure("Source checkout differs from the lock")
    targets = {
        "xcframework": provenance.safe_repository_path("Sources/Vendor/libflac.xcframework", ROOT, "artifact"),
        "license": provenance.safe_repository_path("Sources/Vendor/NativeLicenses/libflac", ROOT, "license"),
        "provenance": provenance.safe_repository_path("Sources/Vendor/libflac.provenance.json", ROOT, "provenance"),
    }
    if not args.stage_only and any(path.exists() or path.is_symlink() for path in targets.values()):
        raise BuildFailure("Existing libFLAC artifacts must be reviewed and preserved before a replacement build")
    build_dir = args.build_dir.absolute()
    if build_dir.exists() or build_dir.is_symlink() or not build_dir.parent.is_dir():
        raise BuildFailure("Build directory must be new and its parent must already exist")
    patch_name, separator, patch_digest = inputs["test_patch"].partition("@")
    patch = provenance.safe_repository_path(patch_name, ROOT, "test patch")
    if not separator or not patch.is_file() or patch.is_symlink() or digest(patch.read_bytes()) != patch_digest:
        raise BuildFailure("CRC test patch differs from the lock")
    license_bytes = (checkout / "COPYING.Xiph").read_bytes()
    if digest(license_bytes) != inputs["license_sha256"]:
        raise BuildFailure("Library license differs from the lock")
    contract_paths = [LOCK, Path(__file__).resolve(), ROOT / "Scripts/native_vendor_provenance.py", patch]
    contract_hashes = {path: digest(path.read_bytes()) for path in contract_paths}
    build_dir.mkdir()
    logs = build_dir / "logs"
    logs.mkdir()
    receipts: list[dict] = []
    build_env = os.environ.copy()
    for name in ["CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS"]:
        build_env[name] = "" # Only this child build; all effective flags are explicit and checked below.

    def run(label: str, argv: list[str], cwd: Path = build_dir, timeout: int = 600) -> None:
        print(label, flush=True)
        receipt = {"label":label, "argv":argv, "cwd":str(cwd)}
        with (logs / (label + ".log")).open("wb") as log:
            process = subprocess.Popen(argv, cwd=cwd, env=build_env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                receipt["timed_out"] = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                code = process.returncode
        receipt["exit"] = code
        receipts.append(receipt)
        (build_dir / "commands.json").write_text(json.dumps(receipts, indent=2) + "\n")
        if code != 0 or receipt.get("timed_out"):
            raise BuildFailure(f"{label} failed; preserved log: {logs / (label + '.log')}")

    archive = subprocess.run(["git", "-C", str(checkout), "archive", "--format=tar", "HEAD"],
                             check=True, capture_output=True).stdout
    if digest(archive) != source["source_archive_sha256"]:
        raise BuildFailure("Git archive differs from the locked source")
    work_source = build_dir / "source"
    work_source.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
        contents.extractall(work_source, filter="data")
    if args.release_archive:
        release = args.release_archive.resolve(strict=True).read_bytes()
    else:
        url = f"https://downloads.xiph.org/releases/flac/flac-{source['version']}.tar.xz"
        with urllib.request.urlopen(url, timeout=30) as response:
            release = response.read(32 * 1024 * 1024 + 1)
    if len(release) > 32 * 1024 * 1024 or digest(release) != inputs["official_release_archive_sha256"]:
        raise BuildFailure("Official release archive differs from the lock")
    compared = 0
    with tarfile.open(fileobj=io.BytesIO(release)) as contents:
        for path in sorted(work_source.rglob("*")):
            relative = path.relative_to(work_source).as_posix()
            if not path.is_file() or path.suffix not in {".c", ".h"} or not relative.startswith(
                ("src/libFLAC/", "include/FLAC/", "include/share/", "src/share/")):
                continue
            member = contents.extractfile(f"flac-{source['version']}/{relative}")
            if member is None or path.read_bytes() != member.read():
                raise BuildFailure(f"Pinned production source differs from the official release: {relative}")
            compared += 1
    if compared != 107:
        raise BuildFailure("Production source inventory differs from the reviewed libFLAC version")
    before = {p.relative_to(work_source).as_posix():digest(p.read_bytes()) for p in work_source.rglob("*") if p.is_file()}
    git_apply = ["git", "--git-dir=" + str(checkout / ".git"), "--work-tree=" + str(work_source), "apply", "--whitespace=error-all"]
    run("test-patch-check", git_apply + ["--check", str(patch)], work_source)
    run("test-patch", git_apply + [str(patch)], work_source)
    after = {p.relative_to(work_source).as_posix():digest(p.read_bytes()) for p in work_source.rglob("*") if p.is_file()}
    if before.keys() != after.keys() or [name for name in before if before[name] != after[name]] != ["src/test_libFLAC/crc.c"]:
        raise BuildFailure("Patch changed files outside the reviewed CRC test fixture")
    (build_dir / "source-comparison.json").write_text(json.dumps({"official_production_files":compared,
        "patched_files":["src/test_libFLAC/crc.c"], "production_codec_changed":False}, indent=2) + "\n")
    compiler = provenance.run("xcrun", "--find", "clang")
    # Each SDK/architecture gets its own configuration and feature checks. In particular, do not
    # reuse a macOS configuration or combine device and simulator arm64 objects into one archive.
    variants = [
        ("macos-arm64", "macosx", "arm64", "macos", "14.0", "-mmacosx-version-min=14.0"),
        ("ios-arm64", "iphoneos", "arm64", "ios", "17.0", "-miphoneos-version-min=17.0"),
        ("ios-simulator-arm64", "iphonesimulator", "arm64", "ios-simulator", "17.0", "-mios-simulator-version-min=17.0"),
        ("ios-simulator-x86_64", "iphonesimulator", "x86_64", "ios-simulator", "17.0", "-mios-simulator-version-min=17.0"),
    ]
    libraries: dict[str, Path] = {}
    for name, sdk_name, arch, platform, minimum, minimum_flag in variants:
        sdk = provenance.run("xcrun", "--sdk", sdk_name, "--show-sdk-path")
        cmake_build = build_dir / name
        configure = ["cmake", "-S", str(work_source), "-B", str(cmake_build), "-G", "Ninja",
            "-DCMAKE_C_COMPILER=" + compiler, "-DCMAKE_OSX_SYSROOT=" + sdk, "-DCMAKE_OSX_ARCHITECTURES=" + arch,
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=" + minimum, "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_C_FLAGS=",
            "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "-DENABLE_WERROR=ON", "-DWITH_FORTIFY_SOURCE=ON",
            "-DWITH_STACK_PROTECTOR=ON", "-DBUILD_CXXLIBS=OFF", "-DBUILD_PROGRAMS=OFF", "-DBUILD_EXAMPLES=OFF",
            "-DBUILD_DOCS=OFF", "-DBUILD_TESTING=ON", "-DBUILD_SHARED_LIBS=OFF", "-DWITH_OGG=OFF"]
        if platform != "macos":
            configure += ["-DCMAKE_SYSTEM_NAME=iOS"]
        run(name + "-configure", configure)
        build_targets = ["FLAC", "test_libFLAC"] if platform == "macos" else ["FLAC"]
        run(name + "-build", ["cmake", "--build", str(cmake_build), "--target", *build_targets, "-j", "1"])
        commands = json.loads((cmake_build / "compile_commands.json").read_text())
        codec_commands = [item for item in commands if "/src/libFLAC/" in item["file"] and "/FLAC.dir/" in item["command"]]
        if not codec_commands:
            raise BuildFailure(f"{name}: no production codec compile commands were recorded")
        for item in codec_commands:
            flags = shlex.split(item["command"])
            if any(flag not in flags for flag in ["-Werror", "-D_FORTIFY_SOURCE=2", "-fstack-protector-strong", minimum_flag]):
                raise BuildFailure(f"{name}: a codec compile omitted a required hardening/deployment flag")
            if any("sanitize" in flag for flag in flags):
                raise BuildFailure("A diagnostic artifact cannot become the product dependency")
        if platform == "macos":
            unit = build_dir / "unit"
            unit.mkdir()
            run("upstream-unit", [str(cmake_build / "src/test_libFLAC/test_libFLAC")], unit)
        library = cmake_build / "src/libFLAC/libFLAC.a"
        if provenance.run("lipo", "-archs", str(library)).split() != [arch] or \
           provenance.mach_o_minos(library) != [minimum] or provenance.mach_o_platforms(library) != [platform]:
            raise BuildFailure(f"{name}: unexpected archive architecture/platform/deployment target")
        libraries[name] = library
    stage = build_dir / "stage"
    stage.mkdir()
    headers = stage / "headers"
    headers.mkdir()
    shutil.copytree(work_source / "include/FLAC", headers / "FLAC", ignore=shutil.ignore_patterns("*.am", "*.in"))
    # The normal CSkyBridgeFLAC C target owns the Swift-facing module. A module map in this
    # binary dependency would compete with other binary headers in Xcode's shared include path.
    simulator = stage / "libFLAC.a"
    run("simulator-universal", ["lipo", "-create", str(libraries["ios-simulator-arm64"]),
        str(libraries["ios-simulator-x86_64"]), "-output", str(simulator)])
    if set(provenance.run("lipo", "-archs", str(simulator)).split()) != {"arm64", "x86_64"} or \
       provenance.mach_o_minos(simulator) != ["17.0"] or provenance.mach_o_platforms(simulator) != ["ios-simulator"]:
        raise BuildFailure("Unexpected universal simulator archive")
    framework = stage / "libflac.xcframework"
    command = ["xcodebuild", "-create-xcframework"]
    for library in [libraries["macos-arm64"], libraries["ios-arm64"], simulator]:
        command += ["-library", str(library), "-headers", str(headers)]
    run("xcframework", command + ["-output", str(framework)])
    with (framework / "Info.plist").open("rb") as file:
        slices = plistlib.load(file)["AvailableLibraries"]
    inventory = {(s["SupportedPlatform"], s.get("SupportedPlatformVariant", ""),
                  tuple(sorted(s["SupportedArchitectures"]))) for s in slices}
    if len(slices) != 3 or inventory != {("macos", "", ("arm64",)), ("ios", "", ("arm64",)),
                                       ("ios", "simulator", ("arm64", "x86_64"))}:
        raise BuildFailure("Unexpected XCFramework slice inventory")
    if any(framework.rglob("module.modulemap")):
        raise BuildFailure("The raw binary dependency must not install a competing Clang module map")
    license_dir = stage / "license"
    license_dir.mkdir()
    (license_dir / "COPYING.Xiph").write_bytes(license_bytes)
    record_path = stage / "libflac.provenance.json"
    if any(digest(path.read_bytes()) != value for path, value in contract_hashes.items()):
        raise BuildFailure("Build contract changed during the build; candidate was not admitted")
    argv = ["python3", str(ROOT / "Scripts/native_vendor_provenance.py"), "create", "--family", FAMILY,
            "--lock", str(LOCK), "--repository-root", str(ROOT), "--recipe", str(Path(__file__).resolve()),
            "--output", str(record_path), "--source", source_spec,
            "--artifact-root", f"xcframework|{framework}|Sources/Vendor/libflac.xcframework",
            "--artifact-root", f"license|{license_dir}|Sources/Vendor/NativeLicenses/libflac"]
    for key, value in sorted(inputs.items()):
        argv += ["--build-input", key + "=" + value]
    run("provenance", argv)
    if provenance.parse_source(source_spec) != source:
        raise BuildFailure("Source checkout changed during the build")
    if args.stage_only:
        candidate = build_dir / "candidate"
        candidate.mkdir()
        for path in contract_paths:
            destination = candidate / path.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
        for name, staged in [("xcframework", framework), ("license", license_dir), ("provenance", record_path)]:
            destination = candidate / targets[name].relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            staged.rename(destination)
        run("verify-candidate", ["python3", str(candidate / "Scripts/native_vendor_provenance.py"), "verify",
            "--lock", str(candidate / "Config/native-dependencies.lock.json"), "--repository-root", str(candidate),
            "--provenance", str(candidate / "Sources/Vendor/libflac.provenance.json")])
        print(f"Verified staged Apple libFLAC candidate: {candidate}; device/runtime qualification is still required", flush=True)
        return
    moved: list[tuple[Path, Path]] = []
    try:
        for name, staged in [("xcframework", framework), ("license", license_dir), ("provenance", record_path)]:
            target = targets[name]
            if target.exists() or target.is_symlink():
                raise BuildFailure(f"An artifact appeared during the build: {target}")
            target.parent.mkdir(parents=True, exist_ok=True)
            staged.rename(target)
            moved.append((target, staged))
        run("verify", ["python3", str(ROOT / "Scripts/native_vendor_provenance.py"), "verify", "--lock", str(LOCK),
                       "--repository-root", str(ROOT), "--provenance", str(targets["provenance"])])
    except BaseException:
        for target, staged in reversed(moved):
            target.rename(staged) # Recover this run's new artifacts; never delete or replace existing user files.
        raise
    print("Verified libFLAC artifact and license admitted to Sources/Vendor", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (BuildFailure, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"libFLAC build failed: {error}") from error
