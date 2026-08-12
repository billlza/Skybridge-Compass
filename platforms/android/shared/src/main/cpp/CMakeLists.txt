# CMakeLists.txt for SkyBridge PQC Native Library
#
# This builds the JNI bridge for liboqs post-quantum cryptography.
# Supports ML-KEM-768 and ML-DSA-65 algorithms.

cmake_minimum_required(VERSION 3.22.1)

project("skybridge_pqc" VERSION 1.0.0 LANGUAGES C)

# Set C standard
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Build the reviewed liboqs source snapshot as part of the same Android
# externalNativeBuild transaction.  The previous imported archive lived below
# an ignored `libs/` directory, so a local build could silently depend on bytes
# that did not exist in a clean checkout.
set(LIBOQS_SOURCE_DIR "${CMAKE_SOURCE_DIR}/../../../scripts/build_liboqs/liboqs")
if(NOT EXISTS "${LIBOQS_SOURCE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "Tracked liboqs source snapshot is missing: ${LIBOQS_SOURCE_DIR}")
endif()

set(BUILD_SHARED_LIBS OFF CACHE BOOL "Build liboqs as a static dependency" FORCE)
set(OQS_BUILD_ONLY_LIB ON CACHE BOOL "Build only the liboqs library" FORCE)
set(OQS_USE_OPENSSL OFF CACHE BOOL "Use liboqs portable primitives" FORCE)
set(OQS_DIST_BUILD OFF CACHE BOOL "Use the portable Android build" FORCE)
set(
    OQS_MINIMAL_BUILD
    "KEM_ml_kem_768;SIG_ml_dsa_65"
    CACHE STRING
    "Only algorithms required by the Android product protocol"
    FORCE
)
add_subdirectory("${LIBOQS_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/liboqs")
set(LIBOQS_GENERATED_INCLUDE_DIR "${CMAKE_BINARY_DIR}/liboqs/include")
target_compile_options(
    xkcp_low_keccakp_1600_plain64
    PRIVATE
    -Werror=implicit-int-conversion
)

# Create the shared library
add_library(${PROJECT_NAME} SHARED
    skybridge_pqc.c
)

# Include directories
target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_SOURCE_DIR}
    ${LIBOQS_GENERATED_INCLUDE_DIR}
)

target_link_libraries(${PROJECT_NAME}
    oqs
    log
)

target_compile_definitions(${PROJECT_NAME} PRIVATE
    LIBOQS_AVAILABLE=1
)

# Compiler flags
target_compile_options(${PROJECT_NAME} PRIVATE
    -Wall
    -Wextra
    -Werror=return-type
    -fvisibility=hidden
)

# Strip debug symbols in release builds
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    target_compile_options(${PROJECT_NAME} PRIVATE -O3)
    set_target_properties(${PROJECT_NAME} PROPERTIES
        LINK_FLAGS "-s"
    )
endif()

# Export only JNI functions
set_target_properties(${PROJECT_NAME} PROPERTIES
    C_VISIBILITY_PRESET hidden
)
