#!/bin/bash
#
# Build liboqs for Android (arm64-v8a and x86_64)
# 
# Prerequisites:
#   - Android NDK installed (set ANDROID_NDK_HOME or use default location)
#   - CMake 3.22+
#   - Git
#
# Usage:
#   ./build_liboqs_android.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBOQS_VERSION="0.15.0-rc2"
BUILD_DIR="$SCRIPT_DIR/build_liboqs"
OUTPUT_DIR="$PROJECT_ROOT/libs/liboqs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Building liboqs for Android ===${NC}"
echo "Version: $LIBOQS_VERSION"
echo "Output: $OUTPUT_DIR"

# Find Android NDK
if [ -z "$ANDROID_NDK_HOME" ]; then
    if [ -d "$HOME/Library/Android/sdk/ndk" ]; then
        ANDROID_NDK_HOME=$(ls -d "$HOME/Library/Android/sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)
        ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
    elif [ -d "$HOME/Android/Sdk/ndk" ]; then
        ANDROID_NDK_HOME=$(ls -d "$HOME/Android/Sdk/ndk"/*/ 2>/dev/null | sort -V | tail -1)
        ANDROID_NDK_HOME="${ANDROID_NDK_HOME%/}"
    fi
fi

if [ -z "$ANDROID_NDK_HOME" ] || [ ! -d "$ANDROID_NDK_HOME" ]; then
    echo -e "${RED}Error: Android NDK not found${NC}"
    echo "Please set ANDROID_NDK_HOME environment variable"
    exit 1
fi

echo -e "${GREEN}Using Android NDK: $ANDROID_NDK_HOME${NC}"

# Find CMake from Android SDK
CMAKE_BIN="$HOME/Library/Android/sdk/cmake/3.22.1/bin/cmake"
if [ ! -f "$CMAKE_BIN" ]; then
    CMAKE_BIN=$(which cmake 2>/dev/null || echo "")
fi
if [ -z "$CMAKE_BIN" ] || [ ! -f "$CMAKE_BIN" ]; then
    echo -e "${RED}Error: CMake not found${NC}"
    echo "Install CMake via Android Studio SDK Manager or brew install cmake"
    exit 1
fi
echo -e "${GREEN}Using CMake: $CMAKE_BIN${NC}"

# Create build directory
mkdir -p "$BUILD_DIR"

# Clone liboqs if not exists
if [ ! -d "$BUILD_DIR/liboqs" ]; then
    echo -e "${YELLOW}Cloning liboqs...${NC}"
    git clone --depth 1 --branch "$LIBOQS_VERSION" https://github.com/open-quantum-safe/liboqs.git "$BUILD_DIR/liboqs"
fi

# Create output directories
mkdir -p "$OUTPUT_DIR/include/oqs"
mkdir -p "$OUTPUT_DIR/lib/arm64-v8a"
mkdir -p "$OUTPUT_DIR/lib/x86_64"

# Function to build for a specific ABI
build_for_abi() {
    local ABI=$1
    local API_LEVEL=24
    
    echo -e "${GREEN}Building for $ABI...${NC}"
    
    local BUILD_ABI_DIR="$BUILD_DIR/build-$ABI"
    rm -rf "$BUILD_ABI_DIR"
    mkdir -p "$BUILD_ABI_DIR"
    
    # CMake configuration for Android
    "$CMAKE_BIN" -S "$BUILD_DIR/liboqs" -B "$BUILD_ABI_DIR" \
        -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-$API_LEVEL" \
        -DANDROID_STL=c++_shared \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DOQS_BUILD_ONLY_LIB=ON \
        -DOQS_USE_OPENSSL=OFF \
        -DOQS_DIST_BUILD=OFF \
        -DOQS_ENABLE_KEM_BIKE=OFF \
        -DOQS_ENABLE_KEM_FRODOKEM=OFF \
        -DOQS_ENABLE_KEM_HQC=OFF \
        -DOQS_ENABLE_SIG_SPHINCS=OFF \
        -DOQS_ENABLE_SIG_FALCON=OFF \
        -G "Unix Makefiles"
    
    # Build
    "$CMAKE_BIN" --build "$BUILD_ABI_DIR" --parallel $(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    
    # Copy library
    if [ -f "$BUILD_ABI_DIR/lib/liboqs.a" ]; then
        cp "$BUILD_ABI_DIR/lib/liboqs.a" "$OUTPUT_DIR/lib/$ABI/"
        echo -e "${GREEN}✓ Built liboqs.a for $ABI${NC}"
    else
        echo -e "${RED}✗ Failed to build for $ABI${NC}"
        exit 1
    fi
    
    # Copy generated headers from first build (CMake generates all needed headers)
    if [ "$ABI" = "arm64-v8a" ]; then
        echo -e "${YELLOW}Copying headers...${NC}"
        
        # Copy all generated headers from the build directory
        cp "$BUILD_ABI_DIR/include/oqs/"*.h "$OUTPUT_DIR/include/oqs/"
        
        echo -e "${GREEN}✓ Headers copied${NC}"
    fi
}

# Build for both ABIs
build_for_abi "arm64-v8a"
build_for_abi "x86_64"

# Verify output
echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo "Headers: $OUTPUT_DIR/include/oqs/"
ls -la "$OUTPUT_DIR/include/oqs/"
echo ""
echo "Libraries:"
ls -la "$OUTPUT_DIR/lib/arm64-v8a/"
ls -la "$OUTPUT_DIR/lib/x86_64/"

echo ""
echo -e "${GREEN}liboqs is ready for Android!${NC}"
