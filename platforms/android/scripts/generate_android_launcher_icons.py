#!/usr/bin/env python3
"""Generate Android launcher icons from the SkyBridge canonical SVG design source."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


DENSITIES: dict[str, int] = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}
FOREGROUND_ART_DP = 94
MONOCHROME_ART_DP = 86
ADAPTIVE_ICON_DP = 108

PROJECT_ROOT = Path(__file__).resolve().parents[1]
MAC_RELEASE_ROOT = PROJECT_ROOT.parents[1]
GENERATOR_PATH = Path(__file__).resolve()
GENERATION_MANIFEST = PROJECT_ROOT / "app" / "launcher-icon-generation.json"
GENERATION_MANIFEST_SCHEMA_VERSION = 1
GENERATION_MANIFEST_PURPOSE = "detect-accidental-launcher-asset-drift"
if not (MAC_RELEASE_ROOT / "project.yml").is_file():
    raise RuntimeError(
        "Android launcher icon verification requires the canonical monorepo layout "
        "with project.yml two levels above platforms/android"
    )
MAC_RESOURCE_DIR = MAC_RELEASE_ROOT / "Sources" / "SkyBridgeCompassApp" / "Resources"
MAC_RESOURCE_DESIGN_ICON = MAC_RESOURCE_DIR / "AppIconMaster.svg"
DEFAULT_CANONICAL_ICON = MAC_RESOURCE_DESIGN_ICON
RES_DIR = PROJECT_ROOT / "app" / "src" / "main" / "res"
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate SkyBridge Android adaptive launcher assets from the canonical SVG design source."
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_CANONICAL_ICON,
        help=f"Canonical SkyBridge icon source. Defaults to the managed macOS SVG design source: {DEFAULT_CANONICAL_ICON}",
    )
    parser.add_argument(
        "--allow-svg",
        action="store_true",
        help="Permit an explicit noncanonical SVG source.",
    )
    parser.add_argument(
        "--allow-experimental-source",
        action="store_true",
        help="Permit --source to point outside the canonical macOS AppIconMaster.png pipeline.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Regenerate into a temporary directory and fail if checked-in Android icon resources drift.",
    )
    parser.add_argument(
        "--write-preview",
        action="store_true",
        help="Also update build/verification/icon-preview while running --check.",
    )
    return parser.parse_args()


def render_svg_source(path: Path) -> Image.Image:
    converter = shutil.which("rsvg-convert")
    if converter is None:
        raise RuntimeError("rsvg-convert is required to render SVG launcher icons")

    try:
        completed = subprocess.run(
            [converter, "-w", "1024", "-h", "1024", str(path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )
    except subprocess.CalledProcessError as error:
        stderr = error.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"rsvg-convert failed for {path}: {stderr}") from error
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"rsvg-convert timed out for {path}") from error
    with Image.open(io.BytesIO(completed.stdout)) as image:
        return image.convert("RGBA")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_output_paths(res_dir: Path) -> list[Path]:
    return [
        res_dir / f"drawable-{density}" / name
        for density in DENSITIES
        for name in ("ic_launcher_foreground.png", "ic_launcher_monochrome.png")
    ]


def asset_set_sha256(res_dir: Path, paths: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError(f"launcher icon asset must be a regular file: {path}")
        relative = path.relative_to(res_dir).as_posix().encode("utf-8")
        digest.update(relative)
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def expected_generation_manifest(source_path: Path, res_dir: Path) -> dict[str, object]:
    outputs = expected_output_paths(res_dir)
    return {
        "schemaVersion": GENERATION_MANIFEST_SCHEMA_VERSION,
        "purpose": GENERATION_MANIFEST_PURPOSE,
        "source": source_path.relative_to(MAC_RELEASE_ROOT).as_posix(),
        "sourceSha256": sha256(source_path),
        "generator": GENERATOR_PATH.relative_to(MAC_RELEASE_ROOT).as_posix(),
        "generatorSha256": sha256(GENERATOR_PATH),
        "assetSetSha256": asset_set_sha256(res_dir, outputs),
    }


def validate_generation_manifest_payload(
    actual: object,
    expected: dict[str, object],
) -> None:
    if not isinstance(actual, dict):
        raise RuntimeError("launcher icon generation manifest must be a JSON object")
    if set(actual) != set(expected):
        raise RuntimeError("launcher icon generation manifest has an unexpected field set")
    drifted = [key for key, value in expected.items() if actual.get(key) != value]
    if drifted:
        raise RuntimeError(
            "launcher icon generation binding drifted: " + ", ".join(sorted(drifted))
        )


def verify_generation_manifest(source_path: Path, res_dir: Path) -> None:
    if GENERATION_MANIFEST.is_symlink() or not GENERATION_MANIFEST.is_file():
        raise RuntimeError(
            f"missing regular launcher icon generation manifest: {GENERATION_MANIFEST}"
        )
    if GENERATION_MANIFEST.stat().st_size > 16 * 1024:
        raise RuntimeError("launcher icon generation manifest exceeds 16 KiB")
    try:
        actual = json.loads(GENERATION_MANIFEST.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RuntimeError("launcher icon generation manifest is invalid JSON") from error
    validate_generation_manifest_payload(
        actual,
        expected_generation_manifest(source_path, res_dir),
    )


def write_generation_manifest(source_path: Path, res_dir: Path) -> None:
    payload = expected_generation_manifest(source_path, res_dir)
    content = (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
    GENERATION_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=GENERATION_MANIFEST.parent,
            prefix=f".{GENERATION_MANIFEST.name}.",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        temporary_path.chmod(0o644)
        temporary_path.replace(GENERATION_MANIFEST)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def verify_source_path_policy(path: Path, allow_experimental_source: bool) -> None:
    expected = DEFAULT_CANONICAL_ICON.resolve(strict=True)
    if path == expected:
        return
    if allow_experimental_source:
        return
    raise ValueError(
        f"noncanonical --source requires --allow-experimental-source; expected canonical source {expected}"
    )


def load_source(path: Path, allow_svg: bool) -> Image.Image:
    if not path.is_file():
        raise FileNotFoundError(f"missing source icon: {path}")
    suffix = path.suffix.lower()
    if suffix == ".svg":
        if path != DEFAULT_CANONICAL_ICON.resolve() and not allow_svg:
            raise ValueError(f"noncanonical SVG source requires --allow-svg: {path}")
        image = render_svg_source(path)
    elif suffix == ".png":
        with Image.open(path) as source_icon:
            image = source_icon.convert("RGBA")
    else:
        raise ValueError(f"source icon must be a PNG unless --allow-svg is used; got {path}")
    image.load()
    if image.size != (1024, 1024):
        raise ValueError(f"source icon must be 1024x1024; got {image.size} from {path}")
    if image.getchannel("A").getbbox() is None:
        raise ValueError(f"source icon has no visible alpha content: {path}")
    return image


def keep_largest_component(mask: Image.Image) -> Image.Image:
    width, height = mask.size
    binary = mask.point(lambda alpha: 255 if alpha > 24 else 0)
    binary_pixels = binary.load()
    source_pixels = mask.load()
    visited = bytearray(width * height)
    largest: list[tuple[int, int]] = []

    for y in range(height):
        for x in range(width):
            index = y * width + x
            if visited[index] or binary_pixels[x, y] == 0:
                continue

            stack = [(x, y)]
            visited[index] = 1
            component: list[tuple[int, int]] = []
            while stack:
                point_x, point_y = stack.pop()
                component.append((point_x, point_y))
                for next_x, next_y in (
                    (point_x + 1, point_y),
                    (point_x - 1, point_y),
                    (point_x, point_y + 1),
                    (point_x, point_y - 1),
                ):
                    if not (0 <= next_x < width and 0 <= next_y < height):
                        continue
                    next_index = next_y * width + next_x
                    if visited[next_index] or binary_pixels[next_x, next_y] == 0:
                        continue
                    visited[next_index] = 1
                    stack.append((next_x, next_y))

            if len(component) > len(largest):
                largest = component

    if not largest:
        raise RuntimeError("monochrome icon mask has no connected subject")

    output = Image.new("L", mask.size, 0)
    output_pixels = output.load()
    for x, y in largest:
        output_pixels[x, y] = source_pixels[x, y]
    return output


def make_subject_mask(source: Image.Image) -> Image.Image:
    """Build the Android 13 themed icon mask from the same brand artwork.

    Android adaptive icons own the outer mask. The foreground therefore keeps
    the compass/cloud/bridge subject, while the rounded glass card is represented
    by the adaptive background instead of being baked into foreground pixels.
    """
    width, height = source.size
    source_pixels = source.load()
    mask = Image.new("L", source.size, 0)
    mask_pixels = mask.load()

    for y in range(height):
        for x in range(width):
            red, green, blue, alpha = source_pixels[x, y]
            if alpha <= 24:
                continue

            # Strip the full-bleed macOS rounded glass card and border while
            # keeping the cloud, compass, and bridge handles.
            if y < 70 or y > 910:
                continue
            if x < 54 or x > 970:
                continue

            max_channel = max(red, green, blue)
            min_channel = min(red, green, blue)
            saturation = max_channel - min_channel

            is_light_glass = (
                max_channel >= 205
                and red >= 115
                and green >= 150
                and blue >= 175
                and blue >= green - 20
            )
            is_near_white = min_channel >= 210 and saturation <= 50
            keep_subject_pixel = not (is_light_glass or is_near_white)
            if keep_subject_pixel:
                mask_pixels[x, y] = alpha

    subject = keep_largest_component(mask)
    return (
        subject.filter(ImageFilter.MaxFilter(5))
        .filter(ImageFilter.MinFilter(3))
        .filter(ImageFilter.GaussianBlur(0.45))
    )


def make_foreground_art(source: Image.Image, subject_mask: Image.Image) -> Image.Image:
    foreground = source.copy()
    foreground.putalpha(subject_mask)
    return foreground


def write_density_assets(
    res_dir: Path,
    foreground_art: Image.Image,
    subject_mask: Image.Image,
) -> list[Path]:
    written: list[Path] = []
    for density, size in DENSITIES.items():
        output_dir = res_dir / f"drawable-{density}"
        output_dir.mkdir(parents=True, exist_ok=True)

        foreground_art_size = round(size * FOREGROUND_ART_DP / ADAPTIVE_ICON_DP)
        foreground_offset = (
            (size - foreground_art_size) // 2,
            (size - foreground_art_size) // 2,
        )

        foreground = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        foreground.alpha_composite(
            foreground_art.resize((foreground_art_size, foreground_art_size), Image.Resampling.LANCZOS),
            foreground_offset,
        )
        foreground_path = output_dir / "ic_launcher_foreground.png"
        foreground.save(foreground_path, optimize=True)
        written.append(foreground_path)

        monochrome_art_size = round(size * MONOCHROME_ART_DP / ADAPTIVE_ICON_DP)
        monochrome_offset = (
            (size - monochrome_art_size) // 2,
            (size - monochrome_art_size) // 2,
        )
        mono_alpha = Image.new("L", (size, size), 0)
        mono_alpha.paste(
            subject_mask.resize((monochrome_art_size, monochrome_art_size), Image.Resampling.LANCZOS),
            monochrome_offset,
        )
        monochrome = Image.new("RGBA", (size, size), (255, 255, 255, 0))
        monochrome.putalpha(mono_alpha)
        monochrome_path = output_dir / "ic_launcher_monochrome.png"
        monochrome.save(monochrome_path, optimize=True)
        written.append(monochrome_path)

    return written


def write_preview(res_dir: Path) -> Path:
    size = DENSITIES["xxxhdpi"]
    background = Image.new("RGBA", (size, size), (249, 253, 254, 255))
    draw = ImageDraw.Draw(background)
    draw.polygon(
        [
            (0, 0),
            (size, 0),
            (size, round(size * 0.34)),
            (round(size * 0.80), round(size * 0.27)),
            (round(size * 0.50), round(size * 0.25)),
            (round(size * 0.20), round(size * 0.27)),
            (0, round(size * 0.34)),
        ],
        fill=(255, 255, 255, 220),
    )
    draw.rectangle([0, round(size * 0.60), size, size], fill=(232, 247, 253, 235))

    with Image.open(res_dir / "drawable-xxxhdpi" / "ic_launcher_foreground.png") as foreground_icon:
        foreground = foreground_icon.convert("RGBA")
    with Image.open(res_dir / "drawable-xxxhdpi" / "ic_launcher_monochrome.png") as monochrome_icon:
        monochrome = monochrome_icon.convert("RGBA")
    composed = Image.alpha_composite(background, foreground)

    preview = Image.new("RGBA", (size * 4 + 24 * 3, size), (236, 243, 246, 255))
    for index, kind in enumerate(("roundrect", "circle", "themed", "unmasked")):
        if kind == "themed":
            tile = Image.new("RGBA", (size, size), (36, 103, 141, 255))
            tile = Image.alpha_composite(tile, monochrome)
            mask = Image.new("L", (size, size), 0)
            ImageDraw.Draw(mask).rounded_rectangle([0, 0, size - 1, size - 1], radius=120, fill=255)
            tile.putalpha(mask)
        else:
            tile = composed.copy()
            if kind != "unmasked":
                mask = Image.new("L", (size, size), 0)
                draw = ImageDraw.Draw(mask)
                if kind == "circle":
                    draw.ellipse([0, 0, size - 1, size - 1], fill=255)
                else:
                    draw.rounded_rectangle([0, 0, size - 1, size - 1], radius=88, fill=255)
                tile.putalpha(mask)
        preview.alpha_composite(tile, ((size + 24) * index, 0))

    preview_path = PROJECT_ROOT / "build" / "verification" / "icon-preview" / "skybridge-adaptive-icon-preview.png"
    preview_path.parent.mkdir(parents=True, exist_ok=True)
    preview.save(preview_path, optimize=True)
    return preview_path


def verify_outputs(res_dir: Path, paths: list[Path]) -> None:
    expected = set(expected_output_paths(res_dir))
    actual = set(paths)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise RuntimeError(f"unexpected output set; missing={missing}; extra={extra}")
    for path in sorted(paths):
        if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
            raise RuntimeError(f"invalid generated icon: {path}")
        density = path.parent.name.removeprefix("drawable-")
        expected_size = DENSITIES[density]
        with Image.open(path) as generated_icon:
            image = generated_icon.convert("RGBA")
        if image.size != (expected_size, expected_size):
            raise RuntimeError(f"{path} must be {expected_size}x{expected_size}; got {image.size}")
        if path.name == "ic_launcher_monochrome.png":
            alpha = image.getchannel("A")
            bbox = alpha.getbbox()
            if bbox is None:
                raise RuntimeError(f"{path} has an empty monochrome alpha mask")
            alpha_pixels = sum(alpha.histogram()[1:])
            coverage = alpha_pixels / (expected_size * expected_size)
            if not 0.08 <= coverage <= 0.55:
                raise RuntimeError(f"{path} monochrome alpha coverage is out of bounds: {coverage:.3f}")
        elif path.name == "ic_launcher_foreground.png":
            alpha = image.getchannel("A")
            bbox = alpha.getbbox()
            if bbox is None:
                raise RuntimeError(f"{path} has an empty foreground alpha mask")
            alpha_pixels = sum(alpha.histogram()[1:])
            coverage = alpha_pixels / (expected_size * expected_size)
            min_x, min_y, max_x, max_y = bbox
            edge_margin = max(2, round(expected_size * 0.03))
            if coverage >= 0.75:
                raise RuntimeError(f"{path} foreground alpha coverage is too large for adaptive icon art: {coverage:.3f}")
            if min_x < edge_margin or min_y < edge_margin or max_x > expected_size - edge_margin or max_y > expected_size - edge_margin:
                raise RuntimeError(f"{path} foreground art touches adaptive icon edges: bbox={bbox}")


def verify_resource_contract(res_dir: Path) -> None:
    expected_resource_paths = {
        Path("drawable") / "ic_launcher_background.xml",
        Path("mipmap-anydpi") / "ic_launcher.xml",
        Path("mipmap-anydpi") / "ic_launcher_round.xml",
    }
    expected_resource_paths.update(
        Path(f"drawable-{density}") / name
        for density in DENSITIES
        for name in ("ic_launcher_foreground.png", "ic_launcher_monochrome.png")
    )
    actual_resource_paths = {
        path.relative_to(res_dir)
        for path in res_dir.rglob("ic_launcher*")
        if path.is_file()
    }
    if actual_resource_paths != expected_resource_paths:
        missing = sorted(expected_resource_paths - actual_resource_paths)
        extra = sorted(actual_resource_paths - expected_resource_paths)
        raise RuntimeError(f"unexpected launcher icon resource set; missing={missing}; extra={extra}")

    expected_layers = {
        "background": "@drawable/ic_launcher_background",
        "foreground": "@drawable/ic_launcher_foreground",
        "monochrome": "@drawable/ic_launcher_monochrome",
    }
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        path = res_dir / "mipmap-anydpi" / name
        if not path.is_file():
            raise FileNotFoundError(f"missing adaptive icon XML: {path}")
        root = ET.parse(path).getroot()
        if root.tag != "adaptive-icon":
            raise RuntimeError(f"{path} root must be adaptive-icon; got {root.tag}")
        layers = {child.tag: child.attrib.get(ANDROID_NS + "drawable") for child in root}
        if layers != expected_layers:
            raise RuntimeError(f"{path} has unexpected adaptive icon layers: {layers}")

    background = res_dir / "drawable" / "ic_launcher_background.xml"
    if not background.is_file():
        raise FileNotFoundError(f"missing launcher background XML: {background}")

    legacy_launcher_pngs = sorted(res_dir.glob("mipmap-*/ic_launcher*.png"))
    if legacy_launcher_pngs:
        raise RuntimeError(f"unexpected legacy launcher PNG resources create a second icon pipeline: {legacy_launcher_pngs}")


def copy_generated_outputs(staged_res_dir: Path, target_res_dir: Path) -> list[Path]:
    copied: list[Path] = []
    for density in DENSITIES:
        for name in ("ic_launcher_foreground.png", "ic_launcher_monochrome.png"):
            relative = Path(f"drawable-{density}") / name
            source_path = staged_res_dir / relative
            target_path = target_res_dir / relative
            target_path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_path, target_path)
            copied.append(target_path)
    return copied


def main() -> int:
    args = parse_args()
    source_path = args.source.resolve(strict=True)
    verify_source_path_policy(source_path, args.allow_experimental_source)
    is_canonical_source = source_path == DEFAULT_CANONICAL_ICON.resolve(strict=True)
    source_hash = sha256(source_path)
    verify_resource_contract(RES_DIR)

    if args.check:
        outputs = expected_output_paths(RES_DIR)
        verify_outputs(RES_DIR, outputs)
        verify_generation_manifest(source_path, RES_DIR)
        preview = write_preview(RES_DIR) if args.write_preview else None
    else:
        source = load_source(source_path, args.allow_svg)
        subject_mask = make_subject_mask(source)
        foreground_art = make_foreground_art(source, subject_mask)
        with tempfile.TemporaryDirectory(prefix="skybridge-android-launcher-icons-") as temp_dir:
            staged_res_dir = Path(temp_dir) / "res"
            outputs = write_density_assets(staged_res_dir, foreground_art, subject_mask)
            verify_outputs(staged_res_dir, outputs)
            copied = copy_generated_outputs(staged_res_dir, RES_DIR)
            verify_outputs(RES_DIR, copied)
        if is_canonical_source:
            write_generation_manifest(source_path, RES_DIR)
            verify_generation_manifest(source_path, RES_DIR)
        preview = write_preview(RES_DIR)

    print(f"source={source_path}")
    print(f"source_sha256={source_hash}")
    print(f"generated={len(outputs)} assets")
    if args.check:
        print("check=passed")
    elif not is_canonical_source:
        print("generation_binding=not-updated-experimental-source")
    if preview is None:
        print("preview=skipped")
    else:
        print(f"preview={preview}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"generate_android_launcher_icons.py: {error}", file=sys.stderr)
        raise SystemExit(1)
