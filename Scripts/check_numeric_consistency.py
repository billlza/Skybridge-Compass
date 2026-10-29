#!/usr/bin/env python3
import json
import os
import re
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
EXPECTED_ARTIFACT_DATE = "2026-01-23"

MAIN_TEX = ROOT_DIR / "Docs" / "TDSC-2026-01-0318_IEEE_Paper_SkyBridge_Compass_patched.tex"
SUPP_TEX = ROOT_DIR / "Docs" / "TDSC-2026-01-0318_supplementary.tex"
CLAIMS_JSON = ROOT_DIR / "Artifacts" / f"claims_{EXPECTED_ARTIFACT_DATE}.json"
CLAIMS_MACROS = ROOT_DIR / "Docs" / "generated" / "claims_macros.tex"


def fmt(value: float, digits: int = 3) -> str:
    return f"{value:.{digits}f}"


def parse_macros(path: Path) -> dict[str, str]:
    text = path.read_text(encoding="utf-8")
    pattern = re.compile(r"\\newcommand\{\\([A-Za-z0-9]+)\}\{([^}]*)\}")
    return {m.group(1): m.group(2).strip() for m in pattern.finditer(text)}


def main() -> None:
    artifact_date = (os.environ.get("ARTIFACT_DATE") or "").strip()
    if artifact_date and artifact_date != EXPECTED_ARTIFACT_DATE:
        raise SystemExit(
            f"ARTIFACT_DATE must be {EXPECTED_ARTIFACT_DATE}, got {artifact_date}"
        )

    for path in (MAIN_TEX, SUPP_TEX, CLAIMS_JSON, CLAIMS_MACROS):
        if not path.exists():
            raise SystemExit(f"missing required file: {path}")

    claims = json.loads(CLAIMS_JSON.read_text(encoding="utf-8"))
    macros = parse_macros(CLAIMS_MACROS)

    latency = claims["latency"]
    v2 = claims["v2_vs_v1"]
    wire = claims["wire_size_bytes"]
    contrast = claims.get("contrast", {})
    apple_latency = contrast.get("latency", {}).get("CryptoKit PQC (ML-KEM-768 + ML-DSA-65)")

    expected_macros = {
        "claimArtifactDate": claims["artifact_date"],
        "claimClassicPNineNineMs": fmt(latency["Classic (X25519 + Ed25519)"]["p99"]),
        "claimLiboqsPNineNineMs": fmt(latency["liboqs PQC (ML-KEM-768 + ML-DSA-65)"]["p99"]),
        "claimLiboqsVTwoPNineNineMs": fmt(latency["liboqs PQC v2 FS (ML-KEM-768-FS + ML-DSA-65)"]["p99"]),
        "claimClassicPayloadBytes": str(wire["classic_payload_handshake"]),
        "claimLiboqsPayloadBytes": str(wire["liboqs_payload_handshake"]),
        "claimVTwoDeltaPayloadBytes": str(v2["delta_payload_handshake_bytes"]),
        "claimVTwoDeltaMessageABytes": str(v2["delta_message_a_bytes"]),
        "claimVTwoDeltaMessageBBytes": str(v2["delta_message_b_bytes"]),
        "claimVTwoPNineFiveDeltaMs": fmt(v2["delta_p95_latency_ms"]),
    }
    if apple_latency is not None and "claimCryptoKitPNineNineMs" in macros:
        expected_macros["claimCryptoKitPNineNineMs"] = fmt(float(apple_latency["p99"]))

    for macro, expected in expected_macros.items():
        actual = macros.get(macro)
        if actual != expected:
            raise SystemExit(
                f"macro mismatch: {macro} expected '{expected}' got '{actual}'"
            )

    main_text = MAIN_TEX.read_text(encoding="utf-8")
    supp_text = SUPP_TEX.read_text(encoding="utf-8")

    required_refs = [
        "\\claimVTwoDeltaPayloadBytes",
        "\\claimVTwoDeltaMessageABytes",
        "\\claimVTwoDeltaMessageBBytes",
        "\\claimClassicPayloadBytes",
        "\\claimLiboqsPayloadBytes",
        "\\claimLiboqsVTwoPNineNineMs",
    ]
    for token in required_refs:
        if token not in main_text and token not in supp_text:
            raise SystemExit(f"missing macro reference in paper text: {token}")

    stale_patterns = [
        (r"\+1160\s*B", "stale v2 payload-byte delta literal (+1160 B)"),
        (r"6\.7~ms", "stale CryptoKit p99 literal (6.7 ms)"),
        (
            r"Classic \(687~B\) to PQC \(12\.0~kB\)",
            "stale wire-size literal in main text",
        ),
    ]
    for pattern, label in stale_patterns:
        if re.search(pattern, main_text):
            raise SystemExit(f"found stale literal in main tex: {label}")

    print("Numeric consistency check passed.")
    print(f"artifact_date={claims['artifact_date']}")
    print(f"claims={CLAIMS_JSON}")
    print(f"macros={CLAIMS_MACROS}")


if __name__ == "__main__":
    main()
