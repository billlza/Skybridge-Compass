#!/usr/bin/env sh

skybridge_detect_apple_pqc_sdk() {
    SKYBRIDGE_PQC_HOST_OS_VER="$(sw_vers -productVersion 2>/dev/null || echo "")"
    SKYBRIDGE_PQC_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || echo "")"
    SKYBRIDGE_PQC_SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "")"
    SKYBRIDGE_PQC_PROBE_MODE="symbol_probe"
    SKYBRIDGE_PQC_PROBE_ERROR=""
    SKYBRIDGE_PQC_SDK_AVAILABLE=0

    probe_src="$(mktemp "${TMPDIR:-/tmp}/skybridge-pqc-probe.XXXXXX.swift")"
    probe_err="$(mktemp "${TMPDIR:-/tmp}/skybridge-pqc-probe.XXXXXX.err")"

    cat >"$probe_src" <<'EOF'
import CryptoKit

func probe() {
    if #available(macOS 26.0, *) {
        _ = MLKEM768.PrivateKey.self
        _ = MLDSA65.PrivateKey.self
        _ = XWingMLKEM768X25519.PrivateKey.self
    }
}
EOF

    if [ -n "$SKYBRIDGE_PQC_SDK_PATH" ] && xcrun --sdk macosx swiftc -sdk "$SKYBRIDGE_PQC_SDK_PATH" -typecheck "$probe_src" >/dev/null 2>"$probe_err"; then
        SKYBRIDGE_PQC_SDK_AVAILABLE=1
    else
        SKYBRIDGE_PQC_PROBE_ERROR="$(tr '\n' ' ' <"$probe_err" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
        SKYBRIDGE_PQC_PROBE_MODE="version_fallback"
        sdk_major="$(printf '%s' "$SKYBRIDGE_PQC_SDK_VER" | awk -F. 'NF { print $1 }')"
        case "$sdk_major" in
            ''|*[!0-9]*)
                SKYBRIDGE_PQC_SDK_AVAILABLE=0
                ;;
            *)
                if [ "$sdk_major" -ge 26 ]; then
                    SKYBRIDGE_PQC_SDK_AVAILABLE=1
                else
                    SKYBRIDGE_PQC_SDK_AVAILABLE=0
                fi
                ;;
        esac
    fi

    rm -f "$probe_src" "$probe_err"
}
