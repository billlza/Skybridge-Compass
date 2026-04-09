# Install script for directory: /Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/usr/local")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "0")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "TRUE")
endif()

# Set default install directory permissions.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/Users/bill/Library/Android/sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-objdump")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/common/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/kem/ntruprime/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/kem/ntru/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/kem/classic_mceliece/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/kem/kyber/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/kem/ml_kem/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/sig/ml_dsa/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/sig/mayo/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/sig/cross/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/sig/uov/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/sig/snova/cmake_install.cmake")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for the subdirectory.
  include("/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/sig/slh_dsa/cmake_install.cmake")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs" TYPE FILE FILES
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/liboqsConfig.cmake"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/liboqsConfigVersion.cmake"
    )
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig" TYPE FILE FILES "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/liboqs.pc")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/lib/liboqs.a")
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs/liboqsTargets.cmake")
    file(DIFFERENT EXPORT_FILE_CHANGED FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs/liboqsTargets.cmake"
         "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/CMakeFiles/Export/lib/cmake/liboqs/liboqsTargets.cmake")
    if(EXPORT_FILE_CHANGED)
      file(GLOB OLD_CONFIG_FILES "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs/liboqsTargets-*.cmake")
      if(OLD_CONFIG_FILES)
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs/liboqsTargets.cmake\" will be replaced.  Removing files [${OLD_CONFIG_FILES}].")
        file(REMOVE ${OLD_CONFIG_FILES})
      endif()
    endif()
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs" TYPE FILE FILES "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/CMakeFiles/Export/lib/cmake/liboqs/liboqsTargets.cmake")
  if("${CMAKE_INSTALL_CONFIG_NAME}" MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/liboqs" TYPE FILE FILES "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/src/CMakeFiles/Export/lib/cmake/liboqs/liboqsTargets-release.cmake")
  endif()
endif()

if("x${CMAKE_INSTALL_COMPONENT}x" STREQUAL "xUnspecifiedx" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/oqs" TYPE FILE FILES
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/oqs.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/common/aes/aes_ops.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/common/common.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/common/rand/rand.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/common/sha2/sha2_ops.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/common/sha3/sha3_ops.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/common/sha3/sha3x4_ops.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/kem/kem.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/sig.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig_stfl/sig_stfl.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/kem/ntruprime/kem_ntruprime.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/kem/ntru/kem_ntru.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/kem/classic_mceliece/kem_classic_mceliece.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/kem/kyber/kem_kyber.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/kem/ml_kem/kem_ml_kem.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/ml_dsa/sig_ml_dsa.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/mayo/sig_mayo.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/cross/sig_cross.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/uov/sig_uov.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/snova/sig_snova.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/liboqs/src/sig/slh_dsa/sig_slh_dsa.h"
    "/Users/bill/Desktop/SkyBridge Compass - Android/shared/scripts/build_liboqs/build-x86_64/include/oqs/oqsconfig.h"
    )
endif()

