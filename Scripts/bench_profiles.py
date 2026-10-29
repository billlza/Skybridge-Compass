#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json

CLASSIC_CONFIG = "Classic (X25519 + Ed25519)"
LIBOQS_PQC_CONFIG = "liboqs PQC (ML-KEM-768 + ML-DSA-65)"
LIBOQS_PQC_V2FS_CONFIG = "liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)"
APPLE_PQC_CONFIG = "CryptoKit PQC (ML-KEM-768 + ML-DSA-65)"
APPLE_XWING_CONFIG = "CryptoKit Hybrid (X-Wing + ML-DSA-65)"

CORE_GATE_CONFIGS = [
    CLASSIC_CONFIG,
    LIBOQS_PQC_CONFIG,
    LIBOQS_PQC_V2FS_CONFIG,
]

CONTRAST_CONFIGS = [
    APPLE_PQC_CONFIG,
    APPLE_XWING_CONFIG,
]

STABILITY_TRACKED_CONFIGS = CORE_GATE_CONFIGS + [APPLE_PQC_CONFIG]
V2_COMPARE_CONFIGS = [LIBOQS_PQC_CONFIG, LIBOQS_PQC_V2FS_CONFIG]

PROFILES = {
    "core": CORE_GATE_CONFIGS,
    "contrast": CONTRAST_CONFIGS,
    "full": CORE_GATE_CONFIGS + CONTRAST_CONFIGS,
}

OUTPUT_SETS = {
    "core": CORE_GATE_CONFIGS,
    "contrast": CONTRAST_CONFIGS,
}


def gate_configs(require_apple: bool) -> list[str]:
    if require_apple:
        return STABILITY_TRACKED_CONFIGS
    return CORE_GATE_CONFIGS


def profile_configs(profile: str) -> list[str]:
    return PROFILES[profile]


def output_set_configs(output_set: str) -> list[str]:
    return OUTPUT_SETS[output_set]


def _emit(values: list[str], output_format: str) -> str:
    if output_format == "json":
        return json.dumps(values, ensure_ascii=True)
    if output_format == "csv":
        return ",".join(values)
    return "\n".join(values)


def main() -> None:
    parser = argparse.ArgumentParser(description="SkyBridge benchmark profile constants")
    parser.add_argument(
        "--mode",
        choices=[
            "core",
            "contrast",
            "full",
            "stability-tracked",
            "gate",
            "v2-compare",
        ],
        required=True,
    )
    parser.add_argument("--require-apple", choices=["0", "1"], default="0")
    parser.add_argument("--format", choices=["lines", "csv", "json"], default="lines")
    args = parser.parse_args()

    if args.mode == "core":
        values = CORE_GATE_CONFIGS
    elif args.mode == "contrast":
        values = CONTRAST_CONFIGS
    elif args.mode == "full":
        values = PROFILES["full"]
    elif args.mode == "stability-tracked":
        values = STABILITY_TRACKED_CONFIGS
    elif args.mode == "gate":
        values = gate_configs(require_apple=args.require_apple == "1")
    elif args.mode == "v2-compare":
        values = V2_COMPARE_CONFIGS
    else:
        raise SystemExit(f"unsupported mode: {args.mode}")

    print(_emit(values, output_format=args.format))


if __name__ == "__main__":
    main()
