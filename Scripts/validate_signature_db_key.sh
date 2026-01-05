#!/bin/zsh
#
# validate_signature_db_key.sh
# SkyBridge Compass - Security Hardening
#
# CI build script to validate that Release builds do not contain development keys.
# This script should be run as part of the CI/CD pipeline before releasing.
#
# Requirements: 7.6 - CI/Release build script detects development key in bundle
#
# Usage:
#   ./Scripts/validate_signature_db_key.sh [--app-path <path>] [--release]
#
# Exit codes:
#   0 - Validation passed
#   1 - Development key detected in Release build (CRITICAL)
#   2 - Invalid arguments or missing files
#   3 - Key not configured (warning in Debug, error in Release)

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Known development key (base64 encoded)
# This is the well-known test key that MUST NOT appear in Release builds
DEV_KEY_BASE64="ZGV2ZWxvcG1lbnQta2V5LW5vdC1mb3ItcHJvZHVjdGlvbg=="
DEV_KEY_HEX="6465766c6f706d656e742d6b65792d6e6f742d666f722d70726f64756374696f6e"

# Default values
APP_PATH=""
IS_RELEASE=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --app-path)
            APP_PATH="$2"
            shift 2
            ;;
        --release)
            IS_RELEASE=true
            shift
            ;;
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--app-path <path>] [--release] [--verbose]"
            echo ""
            echo "Options:"
            echo "  --app-path <path>  Path to the .app bundle to validate"
            echo "  --release          Treat as Release build (stricter validation)"
            echo "  --verbose, -v      Enable verbose output"
            echo "  --help, -h         Show this help message"
            exit 0
            ;;
        *)
            echo "${RED}Error: Unknown option $1${NC}"
            exit 2
            ;;
    esac
done

# Function to log messages
log_info() {
    echo "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo "${RED}[ERROR]${NC} $1"
}

log_debug() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[DEBUG] $1"
    fi
}

# Function to check if a string contains the development key
contains_dev_key() {
    local content="$1"
    
    # Check for base64 encoded dev key
    if echo "$content" | grep -q "$DEV_KEY_BASE64"; then
        return 0
    fi
    
    # Check for hex encoded dev key
    if echo "$content" | grep -qi "$DEV_KEY_HEX"; then
        return 0
    fi
    
    # Check for the decoded string pattern
    if echo "$content" | grep -q "development-key-not-for-production"; then
        return 0
    fi
    
    return 1
}

# Function to validate Info.plist
validate_info_plist() {
    local plist_path="$1"
    
    if [[ ! -f "$plist_path" ]]; then
        log_warn "Info.plist not found at: $plist_path"
        return 1
    fi
    
    log_debug "Checking Info.plist: $plist_path"
    
    # Extract SIGNATURE_DB_PUBLIC_KEY if present
    local key_value=""
    key_value=$(/usr/libexec/PlistBuddy -c "Print :SIGNATURE_DB_PUBLIC_KEY" "$plist_path" 2>/dev/null || echo "")
    
    if [[ -z "$key_value" ]]; then
        # Try base64 variant
        key_value=$(/usr/libexec/PlistBuddy -c "Print :SIGNATURE_DB_PUBLIC_KEY_BASE64" "$plist_path" 2>/dev/null || echo "")
    fi
    
    if [[ -z "$key_value" ]]; then
        if [[ "$IS_RELEASE" == true ]]; then
            log_error "SIGNATURE_DB_PUBLIC_KEY not configured in Release build!"
            return 3
        else
            log_warn "SIGNATURE_DB_PUBLIC_KEY not configured (acceptable in Debug)"
            return 0
        fi
    fi
    
    log_debug "Found key value: $key_value"
    
    # Check if it's the development key
    if contains_dev_key "$key_value"; then
        if [[ "$IS_RELEASE" == true ]]; then
            log_error "CRITICAL: Development key detected in Release build!"
            log_error "Key value: $key_value"
            return 1
        else
            log_warn "Development key detected (acceptable in Debug build)"
            return 0
        fi
    fi
    
    log_info "Production key configured correctly"
    return 0
}

# Function to scan binary for embedded dev key
scan_binary_for_dev_key() {
    local binary_path="$1"
    
    if [[ ! -f "$binary_path" ]]; then
        log_warn "Binary not found at: $binary_path"
        return 0
    fi
    
    log_debug "Scanning binary: $binary_path"
    
    # Use strings to extract readable strings from binary
    if strings "$binary_path" | grep -q "$DEV_KEY_BASE64"; then
        if [[ "$IS_RELEASE" == true ]]; then
            log_error "CRITICAL: Development key found embedded in binary!"
            return 1
        else
            log_warn "Development key found in binary (acceptable in Debug)"
        fi
    fi
    
    if strings "$binary_path" | grep -q "development-key-not-for-production"; then
        if [[ "$IS_RELEASE" == true ]]; then
            log_error "CRITICAL: Development key string found in binary!"
            return 1
        else
            log_warn "Development key string found in binary (acceptable in Debug)"
        fi
    fi
    
    return 0
}

# Main validation logic
main() {
    log_info "Starting signature database key validation..."
    log_info "Mode: $(if [[ "$IS_RELEASE" == true ]]; then echo 'RELEASE'; else echo 'DEBUG'; fi)"
    
    local exit_code=0
    
    # If app path provided, validate the bundle
    if [[ -n "$APP_PATH" ]]; then
        if [[ ! -d "$APP_PATH" ]]; then
            log_error "App bundle not found at: $APP_PATH"
            exit 2
        fi
        
        log_info "Validating app bundle: $APP_PATH"
        
        # Find Info.plist
        local info_plist="$APP_PATH/Contents/Info.plist"
        if [[ -f "$info_plist" ]]; then
            validate_info_plist "$info_plist" || exit_code=$?
        fi
        
        # Find and scan main binary
        local app_name=$(basename "$APP_PATH" .app)
        local binary_path="$APP_PATH/Contents/MacOS/$app_name"
        if [[ -f "$binary_path" ]]; then
            scan_binary_for_dev_key "$binary_path" || exit_code=$?
        fi
    else
        # Validate source files and build configuration
        log_info "Validating source configuration..."
        
        # Check for xcconfig files
        local xcconfig_files=$(find . -name "*.xcconfig" -type f 2>/dev/null || true)
        for config_file in $xcconfig_files; do
            log_debug "Checking xcconfig: $config_file"
            if contains_dev_key "$(cat "$config_file")"; then
                if [[ "$IS_RELEASE" == true ]]; then
                    log_error "CRITICAL: Development key found in $config_file"
                    exit_code=1
                else
                    log_warn "Development key found in $config_file (acceptable in Debug)"
                fi
            fi
        done
        
        # Check SignatureDBKeyManager.swift for hardcoded production key issues
        local key_manager="Sources/SkyBridgeCore/Security/SignatureDBKeyManager.swift"
        if [[ -f "$key_manager" ]]; then
            log_debug "Checking SignatureDBKeyManager.swift"
            # Verify the development key constant is properly marked
            if grep -q "developmentPublicKeyBase64.*=.*\"$DEV_KEY_BASE64\"" "$key_manager"; then
                log_info "Development key constant properly defined in SignatureDBKeyManager"
            fi
        fi
    fi
    
    # Final result
    if [[ $exit_code -eq 0 ]]; then
        log_info "✅ Signature database key validation PASSED"
    elif [[ $exit_code -eq 1 ]]; then
        log_error "❌ Signature database key validation FAILED - Development key detected!"
    elif [[ $exit_code -eq 3 ]]; then
        log_error "❌ Signature database key validation FAILED - Key not configured!"
    fi
    
    exit $exit_code
}

# Run main
main
