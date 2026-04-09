# CMakeLists.txt for SkyBridge PQC Native Library
#
# This builds the JNI bridge for liboqs post-quantum cryptography.
# Supports ML-KEM-768 and ML-DSA-65 algorithms.

cmake_minimum_required(VERSION 3.22.1)

project("skybridge_pqc" VERSION 1.0.0 LANGUAGES C)

# Set C standard
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# liboqs configuration
# The liboqs library should be pre-built for Android and placed in the libs directory
# or fetched via a dependency management system

# Path to pre-built liboqs (adjust based on your setup)
set(LIBOQS_ROOT "${CMAKE_SOURCE_DIR}/../../../libs/liboqs")
set(LIBOQS_INCLUDE_DIR "${LIBOQS_ROOT}/include")
set(LIBOQS_LIB_DIR "${LIBOQS_ROOT}/lib/${ANDROID_ABI}")

# Check if liboqs is available
if(EXISTS "${LIBOQS_INCLUDE_DIR}/oqs/oqs.h")
    message(STATUS "Found liboqs at ${LIBOQS_ROOT}")
    set(LIBOQS_FOUND TRUE)
else()
    message(WARNING "liboqs not found at ${LIBOQS_ROOT}")
    message(WARNING "PQC support will be disabled. To enable:")
    message(WARNING "  1. Build liboqs for Android (arm64-v8a, x86_64)")
    message(WARNING "  2. Place headers in ${LIBOQS_INCLUDE_DIR}")
    message(WARNING "  3. Place libraries in ${LIBOQS_LIB_DIR}")
    set(LIBOQS_FOUND FALSE)
endif()

# Create the shared library
add_library(${PROJECT_NAME} SHARED
    skybridge_pqc.c
)

# Include directories
target_include_directories(${PROJECT_NAME} PRIVATE
    ${CMAKE_SOURCE_DIR}
)

if(LIBOQS_FOUND)
    target_include_directories(${PROJECT_NAME} PRIVATE
        ${LIBOQS_INCLUDE_DIR}
    )
    
    # Link against liboqs
    add_library(oqs STATIC IMPORTED)
    set_target_properties(oqs PROPERTIES
        IMPORTED_LOCATION "${LIBOQS_LIB_DIR}/liboqs.a"
    )
    
    target_link_libraries(${PROJECT_NAME}
        oqs
        log
    )
    
    # Define that liboqs is available
    target_compile_definitions(${PROJECT_NAME} PRIVATE
        LIBOQS_AVAILABLE=1
    )
else()
    # Link only Android log library
    target_link_libraries(${PROJECT_NAME}
        log
    )
    
    # Define that liboqs is not available
    target_compile_definitions(${PROJECT_NAME} PRIVATE
        LIBOQS_AVAILABLE=0
    )
endif()

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
