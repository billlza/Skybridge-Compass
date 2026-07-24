#!/usr/bin/env sh

skybridge_sanitize_pqc_probe_log_value() {
    _skybridge_pqc_log_value="$1"
    _skybridge_pqc_log_value="$(printf '%s\n' "$_skybridge_pqc_log_value" | tr '\n' ' ')"
    _skybridge_pqc_log_value="$(printf '%s\n' "$_skybridge_pqc_log_value" | sed -E 's#/var/folders/[^[:space:]]+#<tmp>#g; s#/tmp/[^[:space:]]+#<tmp>#g; s#<tmp>/[^[:space:]]+#<tmp>#g')"
    _skybridge_pqc_log_value="$(printf '%s\n' "$_skybridge_pqc_log_value" | sed -E 's#/Applications/([^/[:space:]]+\.app)/Contents/Developer#<applications>/\1/Contents/Developer#g; s#/Applications/([^/[:space:]]+\.app)#<applications>/\1#g')"
    if [ -n "${HOME:-}" ]; then
        _skybridge_pqc_log_value="$(printf '%s\n' "$_skybridge_pqc_log_value" | sed "s#${HOME}#<home>#g")"
    fi
    if [ -n "${TMPDIR:-}" ]; then
        _skybridge_pqc_log_value="$(printf '%s\n' "$_skybridge_pqc_log_value" | sed "s#${TMPDIR}#<tmp>#g")"
    fi
    printf '%s\n' "$_skybridge_pqc_log_value" | sed -E 's#<tmp>/[^[:space:]]+#<tmp>#g; s/^ //; s/ $//'
}

skybridge_apple_pqc_sdk_probe_succeeded() {
    [ "${SKYBRIDGE_PQC_SDK_AVAILABLE:-0}" = "1" ] && [ "${SKYBRIDGE_PQC_PROBE_MODE:-}" = "symbol_probe" ]
}

skybridge_require_apple_pqc_sdk_symbol_probe() {
    _skybridge_pqc_required_sdk_name="${1:-macosx}"

    skybridge_detect_apple_pqc_sdk "${_skybridge_pqc_required_sdk_name}"
    skybridge_apple_pqc_sdk_probe_succeeded
}

skybridge_configure_optional_apple_pqc_sdk_compile_gate() {
    _skybridge_pqc_optional_sdk_name="${1:-macosx}"

    skybridge_detect_apple_pqc_sdk "${_skybridge_pqc_optional_sdk_name}"
    if skybridge_apple_pqc_sdk_probe_succeeded; then
        export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=1
    else
        export SKYBRIDGE_ENABLE_APPLE_PQC_SDK=0
    fi
    return 0
}

skybridge_network_tls_pqc_sdk_probe_succeeded() {
    [ "${SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE:-0}" = "1" ] && [ "${SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE:-}" = "symbol_probe" ]
}

skybridge_detect_network_tls_pqc_sdk() {
    sdk_name="${1:-macosx}"

    export SKYBRIDGE_NETWORK_TLS_PQC_SDK_NAME="$sdk_name"
    export SKYBRIDGE_NETWORK_TLS_PQC_SDK_PATH=""
    export SKYBRIDGE_NETWORK_TLS_PQC_SDK_VER=""
    export SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET=""
    export SKYBRIDGE_NETWORK_TLS_PQC_SYMBOL_SET="network-tls-pqc-v1"
    export SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE="symbol_probe"
    export SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR=""
    export SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE=0

    case "$sdk_name" in
        macosx)
            SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET="${SKYBRIDGE_NETWORK_TLS_PQC_MACOS_TARGET:-$(uname -m)-apple-macosx27.0}"
            ;;
        iphoneos)
            SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET="${SKYBRIDGE_NETWORK_TLS_PQC_IPHONEOS_TARGET:-arm64-apple-ios27.0}"
            ;;
        iphonesimulator)
            SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET="${SKYBRIDGE_NETWORK_TLS_PQC_IPHONESIMULATOR_TARGET:-$(uname -m)-apple-ios27.0-simulator}"
            ;;
        *)
            SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE="unsupported_sdk"
            SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR="unsupported Network TLS PQC SDK probe target: $sdk_name"
            return 0
            ;;
    esac

    SKYBRIDGE_NETWORK_TLS_PQC_SDK_PATH="$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null || echo "")"
    SKYBRIDGE_NETWORK_TLS_PQC_SDK_VER="$(xcrun --sdk "$sdk_name" --show-sdk-version 2>/dev/null || echo "")"

    if [ -z "$SKYBRIDGE_NETWORK_TLS_PQC_SDK_PATH" ]; then
        SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE="sdk_lookup_failed"
        SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR="sdk=$sdk_name target=$SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET: xcrun --show-sdk-path returned no SDK path"
        return 0
    fi

    if ! probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-network-tls-pqc-probe.XXXXXX")"; then
        SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE="probe_workspace_failed"
        SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR="sdk=$sdk_name target=$SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET: unable to create temporary probe workspace"
        return 0
    fi
    probe_src="$probe_dir/probe.swift"
    probe_err="$probe_dir/probe.err"

cat >"$probe_src" <<'EOF'
import Network

func probeNetworkTLSHybridKEXPublicAPI() {
    if #available(macOS 27.0, iOS 27.0, *) {
        var tlsOptions = SwiftTLSOptions()
        tlsOptions.keyExchangeGroup = .x25519MLKEM768
        _ = tlsOptions.keyExchangeGroup
    }
}
EOF

    if xcrun --sdk "$sdk_name" swiftc \
        -sdk "$SKYBRIDGE_NETWORK_TLS_PQC_SDK_PATH" \
        -target "$SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET" \
        -typecheck "$probe_src" >/dev/null 2>"$probe_err"; then
        SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE=1
    else
        probe_message="$(tr '\n' ' ' <"$probe_err" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//' | cut -c 1-1200)"
        SKYBRIDGE_NETWORK_TLS_PQC_PROBE_MODE="symbol_probe_failed"
        SKYBRIDGE_NETWORK_TLS_PQC_PROBE_ERROR="sdk=$sdk_name target=$SKYBRIDGE_NETWORK_TLS_PQC_SWIFT_TARGET version=${SKYBRIDGE_NETWORK_TLS_PQC_SDK_VER:-unknown}: $probe_message"
        SKYBRIDGE_NETWORK_TLS_PQC_SDK_AVAILABLE=0
    fi

    rm -rf "$probe_dir"
    return 0
}

skybridge_detect_apple_pqc_sdk() {
    sdk_name="${1:-macosx}"
    include_secure_enclave=0

    export SKYBRIDGE_PQC_HOST_OS_VER
    SKYBRIDGE_PQC_HOST_OS_VER="$(sw_vers -productVersion 2>/dev/null || echo "")"
    export SKYBRIDGE_PQC_SDK_NAME="$sdk_name"
    export SKYBRIDGE_PQC_SDK_PATH=""
    export SKYBRIDGE_PQC_SDK_VER=""
    export SKYBRIDGE_PQC_SWIFT_TARGET=""
    export SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE=0
    export SKYBRIDGE_PQC_PROBE_MODE="symbol_probe"
    export SKYBRIDGE_PQC_PROBE_ERROR=""
    export SKYBRIDGE_PQC_SDK_AVAILABLE=0

    case "$sdk_name" in
        macosx)
            SKYBRIDGE_PQC_SWIFT_TARGET="${SKYBRIDGE_PQC_MACOS_TARGET:-$(uname -m)-apple-macosx26.0}"
            include_secure_enclave=1
            ;;
        iphoneos)
            SKYBRIDGE_PQC_SWIFT_TARGET="${SKYBRIDGE_PQC_IPHONEOS_TARGET:-arm64-apple-ios26.0}"
            include_secure_enclave=1
            ;;
        iphonesimulator)
            SKYBRIDGE_PQC_SWIFT_TARGET="${SKYBRIDGE_PQC_IPHONESIMULATOR_TARGET:-$(uname -m)-apple-ios26.0-simulator}"
            ;;
        *)
            SKYBRIDGE_PQC_PROBE_MODE="unsupported_sdk"
            SKYBRIDGE_PQC_PROBE_ERROR="unsupported Apple PQC SDK probe target: $sdk_name"
            return 0
            ;;
    esac

    SKYBRIDGE_PQC_INCLUDED_SECURE_ENCLAVE="$include_secure_enclave"
    SKYBRIDGE_PQC_SDK_PATH="$(xcrun --sdk "$sdk_name" --show-sdk-path 2>/dev/null || echo "")"
    SKYBRIDGE_PQC_SDK_VER="$(xcrun --sdk "$sdk_name" --show-sdk-version 2>/dev/null || echo "")"

    if [ -z "$SKYBRIDGE_PQC_SDK_PATH" ]; then
        SKYBRIDGE_PQC_PROBE_MODE="sdk_lookup_failed"
        SKYBRIDGE_PQC_PROBE_ERROR="sdk=$sdk_name target=$SKYBRIDGE_PQC_SWIFT_TARGET: xcrun --show-sdk-path returned no SDK path"
        return 0
    fi

    if ! probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-pqc-probe.XXXXXX")"; then
        SKYBRIDGE_PQC_PROBE_MODE="probe_workspace_failed"
        SKYBRIDGE_PQC_PROBE_ERROR="sdk=$sdk_name target=$SKYBRIDGE_PQC_SWIFT_TARGET: unable to create temporary probe workspace"
        return 0
    fi
    probe_src="$probe_dir/probe.swift"
    probe_err="$probe_dir/probe.err"

cat >"$probe_src" <<'EOF'
import CryptoKit
import Foundation

func probe() throws {
    if #available(macOS 26.0, iOS 26.0, *) {
        _ = MLKEM1024.PrivateKey.self
        _ = MLDSA87.PrivateKey.self

        let mlkemPrivateKey = try MLKEM768.PrivateKey()
        let mlkemPublicKey = mlkemPrivateKey.publicKey
        _ = try MLKEM768.PrivateKey(integrityCheckedRepresentation: mlkemPrivateKey.integrityCheckedRepresentation)
        _ = try MLKEM768.PublicKey(rawRepresentation: mlkemPublicKey.rawRepresentation)
        let mlkemEncapsulation = try mlkemPublicKey.encapsulate()
        _ = mlkemEncapsulation.sharedSecret
        _ = try mlkemPrivateKey.decapsulate(mlkemEncapsulation.encapsulated)

        let mldsaPrivateKey = try MLDSA65.PrivateKey()
        let mldsaPublicKey = mldsaPrivateKey.publicKey
        _ = try MLDSA65.PrivateKey(integrityCheckedRepresentation: mldsaPrivateKey.integrityCheckedRepresentation)
        _ = try MLDSA65.PublicKey(rawRepresentation: mldsaPublicKey.rawRepresentation)
        let message = Data("skybridge-pqc-symbol-probe".utf8)
        let signature = try mldsaPrivateKey.signature(for: message)
        _ = mldsaPublicKey.isValidSignature(signature, for: message)

        let info = Data("skybridge-pqc-hpke-info".utf8)
        let metadata = Data("skybridge-pqc-hpke-metadata".utf8)
        let payload = Data("skybridge-pqc-hpke-payload".utf8)
        let ciphersuite = HPKE.Ciphersuite.XWingMLKEM768X25519_SHA256_AES_GCM_256
        let xwingPrivateKey = try XWingMLKEM768X25519.PrivateKey.generate()
        let xwingPublicKey = xwingPrivateKey.publicKey
        _ = try XWingMLKEM768X25519.PrivateKey(integrityCheckedRepresentation: xwingPrivateKey.integrityCheckedRepresentation)
        _ = try XWingMLKEM768X25519.PublicKey(rawRepresentation: xwingPublicKey.rawRepresentation)
        var sender = try HPKE.Sender(recipientKey: xwingPublicKey, ciphersuite: ciphersuite, info: info)
        var recipient = try HPKE.Recipient(
            privateKey: xwingPrivateKey,
            ciphersuite: ciphersuite,
            info: info,
            encapsulatedKey: sender.encapsulatedKey
        )
        let ciphertext = try sender.seal(payload, authenticating: metadata)
        _ = try recipient.open(ciphertext, authenticating: metadata)
    }
}

func probeSecureEnclavePQCSymbols() {
    #if SKYBRIDGE_PQC_PROBE_SECURE_ENCLAVE
    if #available(macOS 26.0, iOS 26.0, *) {
        _ = SecureEnclave.MLKEM768.PrivateKey.self
        _ = SecureEnclave.MLKEM1024.PrivateKey.self
        _ = SecureEnclave.MLDSA65.PrivateKey.self
        _ = SecureEnclave.MLDSA87.PrivateKey.self
    }
    #endif
}
EOF

    if [ "$include_secure_enclave" = "1" ]; then
        if xcrun --sdk "$sdk_name" swiftc \
            -sdk "$SKYBRIDGE_PQC_SDK_PATH" \
            -target "$SKYBRIDGE_PQC_SWIFT_TARGET" \
            -D SKYBRIDGE_PQC_PROBE_SECURE_ENCLAVE \
            -typecheck "$probe_src" >/dev/null 2>"$probe_err"; then
            probe_status=0
        else
            probe_status=$?
        fi
    else
        if xcrun --sdk "$sdk_name" swiftc \
            -sdk "$SKYBRIDGE_PQC_SDK_PATH" \
            -target "$SKYBRIDGE_PQC_SWIFT_TARGET" \
            -typecheck "$probe_src" >/dev/null 2>"$probe_err"; then
            probe_status=0
        else
            probe_status=$?
        fi
    fi

    if [ "$probe_status" -eq 0 ]; then
        SKYBRIDGE_PQC_SDK_AVAILABLE=1
    else
        probe_message="$(tr '\n' ' ' <"$probe_err" | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//' | cut -c 1-1200)"
        SKYBRIDGE_PQC_PROBE_MODE="symbol_probe_failed"
        SKYBRIDGE_PQC_PROBE_ERROR="sdk=$sdk_name target=$SKYBRIDGE_PQC_SWIFT_TARGET version=${SKYBRIDGE_PQC_SDK_VER:-unknown}: $probe_message"
        SKYBRIDGE_PQC_SDK_AVAILABLE=0
    fi

    rm -rf "$probe_dir"
    return 0
}
